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
    /// Cheap enough to run on the main actor for typical sizes (≤ a few
    /// MB), but the caller is free to dispatch via Task.detached.
    static func load(
        sessionId: String,
        projectCwd: String,
        maxEvents: Int = 40
    ) -> Preload? {
        let url = jsonlURL(sessionId: sessionId, projectCwd: projectCwd)
        guard FileManager.default.fileExists(atPath: url.path) else {
            logger.notice("history file missing: \(url.path, privacy: .public)")
            return nil
        }
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            logger.warning("history file unreadable: \(url.path, privacy: .public)")
            return nil
        }

        let decoder = JSONDecoder()
        var renderable: [StreamEvent] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8) else { continue }
            guard let event = try? decoder.decode(StreamEvent.self, from: data) else {
                continue
            }
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
        // the transcript can surface "↑ N earlier messages" hint.
        var omittedUserTurns = 0
        var trimmed = renderable
        if renderable.count > maxEvents {
            let dropCount = renderable.count - maxEvents
            for i in 0..<dropCount {
                if case .user = renderable[i] { omittedUserTurns += 1 }
            }
            trimmed = Array(renderable.suffix(maxEvents))
        }

        logger.info("history preload: \(trimmed.count, privacy: .public) events for session \(sessionId, privacy: .public)")
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
        let home = FileManager.default.homeDirectoryForCurrentUser
        let projectsRoot = home.appendingPathComponent(".claude").appendingPathComponent("projects")
        let guessed = projectsRoot
            .appendingPathComponent(projectCwd.replacingOccurrences(of: "/", with: "-"))
            .appendingPathComponent(sessionId + ".jsonl")
        if FileManager.default.fileExists(atPath: guessed.path) { return guessed }

        let fm = FileManager.default
        if let dirs = try? fm.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil) {
            for dir in dirs {
                let candidate = dir.appendingPathComponent(sessionId + ".jsonl")
                if fm.fileExists(atPath: candidate.path) {
                    logger.notice("history: guessed path missed, found via scan: \(candidate.path, privacy: .public)")
                    return candidate
                }
            }
        }
        return guessed   // let the caller's fileExists check log+fail as before
    }
}
