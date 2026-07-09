// Background task registry (#68) — tracks shell commands Claude runs with
// run_in_background: true. Grounded in the REAL wire text, captured from
// this app's own production sessions (not guessed):
//
//   spawn ack (a tool_result on the originating Bash tool_use):
//     "Command running in background with ID: <id>. Output is being
//      written to: <path>. You will be notified when it completes. ..."
//
//   completion (delivered as injected context ahead of the model's next
//   turn — the Messages-API-consistent hypothesis: a synthetic `user`
//   text block; the parser is written to degrade harmlessly if that
//   hypothesis needs correcting once this is observed against a live GUI
//   session):
//     <task-notification>
//     <task-id>bsxyox84l</task-id>
//     ...
//     <status>completed</status>
//     <summary>Background command "..." completed (exit code 0)</summary>
//     </task-notification>
//
// The exact same <task-notification> shape also carries SUBAGENT
// completions (<summary>Agent "..." finished</summary>) — deliberately
// out of scope here (that's #38, the agents epic's delegation cards); the
// summary-prefix check is what tells them apart.

import Foundation

struct V2BackgroundTask: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed(exitCode: Int?)
        case failed(exitCode: Int?)
        /// The session that spawned this task ended (stop/termination/crash)
        /// before a completion notification arrived — the OS process may
        /// still be running, but Atelier has no more channel to hear about
        /// it. Shown distinctly so "still running" never lies.
        case orphaned
    }

    let id: String                 // the task id from "running in background with ID: <id>"
    let command: String            // the originating Bash tool_use's input.command, when known
    let outputPath: String?
    let startedAt: Date
    var state: State = .running
    var finishedAt: Date?
}

enum V2BackgroundTaskParser {
    // The path terminator is "\.(?=\s|$)" (a period followed by whitespace),
    // NOT a bare "\.": output paths end in ".output", and a plain non-greedy
    // \S+?\. stops at THAT period (the first one it finds), silently
    // truncating the extension off every parsed path. Caught by testing
    // against the real captured wire text before trusting this, not by
    // inspection — the bug was invisible reading the regex alone.
    private static let spawnRegex = try! NSRegularExpression(
        pattern: #"running in background with ID:\s*(\S+)\.\s*Output is being written to:\s*(\S+?)\.(?=\s|$)"#
    )
    private static let notificationRegex = try! NSRegularExpression(
        pattern: #"<task-notification>.*?<task-id>(.*?)</task-id>.*?<status>(.*?)</status>.*?<summary>(.*?)</summary>.*?</task-notification>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let exitCodeRegex = try! NSRegularExpression(pattern: #"exit code (\d+)"#)

    /// Parsed from a tool_result's text — nil if this result isn't a
    /// background-spawn acknowledgment (the overwhelming majority of tool
    /// results, which is fine: a miss here just means an ordinary tool call,
    /// never an error).
    static func parseSpawn(from text: String) -> (id: String, outputPath: String)? {
        let ns = text as NSString
        guard let m = spawnRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 3
        else { return nil }
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    /// Parsed from any text block that might carry an injected
    /// <task-notification>. Returns nil for a subagent notification
    /// (summary doesn't start with "Background command") — that's #38's
    /// concern, not this registry's.
    static func parseCompletion(from text: String) -> (id: String, isError: Bool, exitCode: Int?)? {
        guard text.contains("<task-notification>") else { return nil }   // cheap bail before regex
        let ns = text as NSString
        guard let m = notificationRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 4
        else { return nil }
        let id = ns.substring(with: m.range(at: 1))
        let status = ns.substring(with: m.range(at: 2))
        let summary = ns.substring(with: m.range(at: 3))
        guard summary.hasPrefix("Background command ") else { return nil }   // subagent notification — not ours

        var exitCode: Int?
        let summaryNS = summary as NSString
        if let em = exitCodeRegex.firstMatch(in: summary, range: NSRange(location: 0, length: summaryNS.length)),
           em.numberOfRanges == 2 {
            exitCode = Int(summaryNS.substring(with: em.range(at: 1)))
        }
        let isError = status.lowercased() != "completed" || (exitCode.map { $0 != 0 } ?? false)
        return (id, isError, exitCode)
    }
}
