// Reads `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` so a resumed
// session lands the user back in context instead of an empty transcript.
//
// Each .jsonl line is the same JSON envelope claude writes on stdout during
// a live session, just with extra metadata (parentUuid, timestamp, cwd, …).
// Our existing StreamEvent decoder already tolerates unknown keys, so we
// reuse it verbatim and only filter to the event types we actually want to
// render: user turns + assistant snapshots. Everything else (system,
// stream_event deltas, results, attachments, command_permissions, …) is
// skipped — the deltas are duplicates of the snapshot, and `system/init`
// would conflict with the live one we get from claude on resume.

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.munyamakosa.work", category: "history")

enum SessionHistoryLoader {

    struct Preload {
        /// Events to feed through StreamSession.handle(event:) in order.
        let events: [StreamEvent]
        /// How many user-turn events were dropped from the head (we cap the
        /// preload at the latest N to avoid burying the user in scrollback).
        let omittedUserTurns: Int
    }

    /// Read the session's .jsonl from disk and return the events worth
    /// pre-rendering. Returns nil if the file is missing/unreadable.
    /// Reads only a bounded tail chunk (M7, bug-hunt 2026-07-10) — this used
    /// to read + decode the ENTIRE file just to keep the last `maxEvents`,
    /// so an MB-scale history file was fully loaded into memory for nothing.
    /// Same bounded-tail discipline as V2BackgroundTaskTail/V2SubagentTail in
    /// this directory, adapted for structured JSONL: read from the end, drop
    /// a possibly-fragmentary first line, then decode only what's left.
    /// Cheap enough to run on the main actor, but the caller is free to
    /// dispatch via Task.detached.
    static func load(
        sessionId: String,
        projectCwd: String,
        maxEvents: Int = 40,
        tailBytes: Int = 1 * 1024 * 1024
    ) -> Preload? {
        let url = jsonlURL(sessionId: sessionId, projectCwd: projectCwd)
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.notice("History file missing")
            return nil
        }
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            logger.warning("History file unreadable")
            return nil
        }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        let startedMidFile = fileSize > UInt64(tailBytes)
        let start = startedMidFile ? fileSize - UInt64(tailBytes) : 0
        try? fh.seek(toOffset: start)
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        guard !data.isEmpty else {
            logger.warning("History file unreadable")
            return nil
        }

        var lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        // A mid-file start means the first line is very likely a truncated
        // fragment of whatever line straddled our read boundary — drop it
        // (same guard V2SubagentTail.activity uses) unless we actually read
        // from byte 0 of the real file.
        if startedMidFile, !lines.isEmpty { lines.removeFirst() }

        let decoder = JSONDecoder()
        var renderable: [StreamEvent] = []
        for lineData in lines {
            guard let event = try? decoder.decode(StreamEvent.self, from: lineData) else { continue }
            switch event {
            case .user, .assistant:
                renderable.append(event)
            default:
                // system, stream_event, result, controlRequest/Response,
                // unknown — none of these belong in a preload.
                break
            }
        }

        // Trim to the most recent `maxEvents`. Count the user turns dropped so
        // the transcript can surface "↑ N earlier messages" hint. Note this
        // count is only accurate WITHIN the tail window we read — if the
        // file is bigger than `tailBytes`, turns before the window aren't
        // counted at all. That's an acceptable trade for not reading the
        // whole file just to keep an omitted-count exact.
        var omittedUserTurns = 0
        var trimmed = renderable
        if renderable.count > maxEvents {
            let dropCount = renderable.count - maxEvents
            for i in 0..<dropCount {
                if case .user = renderable[i] { omittedUserTurns += 1 }
            }
            trimmed = Array(renderable.suffix(maxEvents))
        }

        logger.info("History preload completed with \(trimmed.count, privacy: .public) events")
        return Preload(events: trimmed, omittedUserTurns: omittedUserTurns)
    }

    /// Claude's on-disk directory encoding replaces EVERY non-alphanumeric
    /// character with "-" (space, `.`, `(`, `)`, `/`, …), one-for-one — e.g.
    /// "web assesment" → "web-assesment". Naively handling only "/" pointed
    /// at a directory that doesn't exist for any cwd containing a space or
    /// other punctuation, so resuming a session in such a project silently
    /// preloaded an EMPTY transcript (this file simply didn't exist at the
    /// guessed path) — the "I chat with it but it doesn't show" bug.
    ///
    /// Rather than re-deriving Claude's exact encoding rule (risk: a
    /// character we haven't observed gets guessed wrong again), fall back to
    /// a sessionId-keyed search: the id is a UUID, globally unique, so
    /// whichever project directory contains "<sessionId>.jsonl" IS the right
    /// one — no cwd decoding needed at all. Bounded to this machine's actual
    /// project count (dozens), only runs on the rare guess-miss.
    static func jsonlURL(sessionId: String, projectCwd: String) -> URL {
        let projectsRoot = projectsRoot()
        let guessed = projectsRoot
            .appendingPathComponent(projectDirName(for: projectCwd))
            .appendingPathComponent(sessionId + ".jsonl")
        if FileManager.default.fileExists(atPath: guessed.path) { return guessed }

        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let candidate = dir.appendingPathComponent(sessionId + ".jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    logger.notice("History path was found by scan")
                    return candidate
                }
            }
        }
        return guessed   // let the caller's fileExists check log+fail as before
    }

    /// `~/.claude/projects`, honouring CLAUDE_CONFIG_DIR — the documented
    /// knob for relocating session storage (people point it at an external
    /// or synced volume). Reading the fixed `~/.claude` ignored that and
    /// found no history at all for anyone who had set it.
    static func projectsRoot() -> URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
        }
        return base.appendingPathComponent("projects")
    }

    /// Claude's project-directory name for a working directory: EVERY
    /// non-alphanumeric character becomes "-". Not just "/" — that older
    /// guess missed any path containing a space, dot, underscore or
    /// parenthesis, which the scan fallback below then quietly rescued.
    ///
    /// Verified against a real directory on disk rather than inferred:
    ///   /Users/…/Downloads/Mbira Tension Stems (1)
    ///   → -Users-…-Downloads-Mbira-Tension-Stems--1-
    /// which pins the space, both parens, and the absence of any
    /// dash-collapsing or trailing trim.
    ///
    /// Load-bearing for import: a bundle written for a machine that has no
    /// such session yet has no file to scan for, so the name has to be
    /// right the first time.
    /// ASCII-only on purpose: Character.isLetter is Unicode-aware and would
    /// keep "é" or "日", but the rule is [a-zA-Z0-9] — everything else,
    /// accented letters included, becomes "-".
    static func projectDirName(for projectCwd: String) -> String {
        String(projectCwd.map { ch in
            let isASCIIAlphanumeric = ch.isASCII && (ch.isLetter || ch.isNumber)
            return isASCIIAlphanumeric ? ch : "-"
        })
    }
}
