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

    static func jsonlURL(sessionId: String, projectCwd: String) -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let encoded = projectCwd.replacingOccurrences(of: "/", with: "-")
        return home
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")
            .appendingPathComponent(encoded)
            .appendingPathComponent(sessionId + ".jsonl")
    }
}
