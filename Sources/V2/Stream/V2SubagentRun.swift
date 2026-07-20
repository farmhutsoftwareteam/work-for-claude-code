// Subagent run registry (#38) — tracks agents Claude delegates to via the
// Task/Agent tool. Grounded in REAL wire text captured from actual sessions
// (not guessed):
//
//   spawn (an assistant tool_use; the CLI names the tool "Task", newer
//   SDK harnesses "Agent" — handle both):
//     { "name": "Agent", "input": { "description": "Write CoTermRing XCTest
//       suite", "subagent_type": "general-purpose", "run_in_background":
//       true, "prompt": "..." } }
//
//   background spawn ack (the tool_result on that tool_use):
//     "Async agent launched successfully. ... agentId: a8e263f947f9b7ef6
//      (internal ID - do not mention to user. ..."
//
//   synchronous completion: simply the tool_result on the spawn's
//   tool_use id, carrying the agent's final report as text.
//
//   background completion (injected context, same <task-notification>
//   channel as background shell tasks — V2BackgroundTaskParser rejects
//   these by summary prefix; this parser accepts ONLY these):
//     <task-notification>
//     <task-id>a48d8ba34676cef50</task-id>
//     <tool-use-id>toolu_01FNJgNcRW7fXKZ6v5AdAauh</tool-use-id>
//     <status>completed</status>
//     <summary>Agent "Extract current main-screen pixel values" finished</summary>
//     ...
//     <result>## the agent's final report ...</result>
//     </task-notification>
//
//   the agent's own live transcript (for #39's peek):
//     ~/.claude/projects/<encoded-cwd>/<session-id>/subagents/
//         agent-<agentId>.jsonl
//         agent-<agentId>.meta.json   ← {"toolUseId": "...", "agentType":
//                                        "...", "description": "..."} —
//                                        the spawn↔file correlation key.

import Foundation

struct V2SubagentRun: Identifiable, Equatable {
    enum State: Equatable {
        case running
        case completed
        case failed
        /// The session ended (hibernate/stop/termination) before this run
        /// reported back — there's no channel left to hear about it, so
        /// "still running" must never be claimed.
        case orphaned
    }

    /// The spawn tool_use id — the correlation key everything else keys off:
    /// sync completions (tool_result), background completions
    /// (<tool-use-id>), and the on-disk meta.json all carry it.
    let toolUseId: String
    /// `var` because Codex identifies an agent only when it reports in:
    /// a spawn can land before the subAgentActivity that names it, so both
    /// are backfilled (see CodexSession.applySubagentEvent). Claude sets
    /// them once at spawn and never rewrites them.
    var description: String
    var agentType: String
    let isBackground: Bool
    let startedAt: Date
    var state: State = .running
    var finishedAt: Date?
    /// From the background ack, when this run is background — lets the peek
    /// resolve agent-<id>.jsonl directly without scanning meta files.
    var agentId: String?
    /// The agent's final report — sync tool_result text, or the
    /// notification's <result> payload.
    var resultText: String?
    /// Codex only: the sub-agent's own THREAD id. Codex sub-agents aren't
    /// files on disk like Claude's agent-*.jsonl — each is a real thread
    /// with its own history, readable through the app-server. Non-nil is
    /// what routes the peek to the Codex reader instead of the file tail.
    var threadId: String?

    var id: String { toolUseId }
}

enum V2SubagentParser {
    private static let agentIdRegex = try! NSRegularExpression(
        pattern: #"agentId:\s*([a-z0-9]+)"#
    )
    // Same notification envelope as V2BackgroundTaskParser but capturing
    // <tool-use-id> (the run correlation key) and <result> (the report).
    // <result> is optional-by-shape: kept in a separate pass so a
    // notification without one still parses.
    private static let notificationRegex = try! NSRegularExpression(
        pattern: #"<task-notification>.*?<tool-use-id>(.*?)</tool-use-id>.*?<status>(.*?)</status>.*?<summary>(.*?)</summary>"#,
        options: [.dotMatchesLineSeparators]
    )
    private static let resultRegex = try! NSRegularExpression(
        pattern: #"<result>(.*)</result>"#,
        options: [.dotMatchesLineSeparators]
    )

    /// True when a tool_use is an agent spawn — the CLI's "Task" and the
    /// SDK's "Agent" are the same tool across harness versions.
    /// "collab.spawnAgent" is Codex's equivalent (see CodexSession's
    /// toolUseItem), so both providers render the same delegation card.
    static func isAgentSpawn(toolName: String) -> Bool {
        toolName == "Task" || toolName == "Agent" || toolName == "collab.spawnAgent"
    }

    /// The agentId out of a background spawn ack, nil for any other text
    /// (including sync agents' final reports, which have no ack).
    static func agentId(fromSpawnAck text: String) -> String? {
        guard text.contains("agent launched") else { return nil }
        let ns = text as NSString
        guard let m = agentIdRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges == 2
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Parsed from any text block that might carry an injected
    /// <task-notification>. Returns nil unless the summary marks a SUBAGENT
    /// (`Agent "..." finished`) — background shell commands are
    /// V2BackgroundTaskParser's concern, split by the same prefix check
    /// from the other side.
    static func parseCompletion(from text: String) -> (toolUseId: String, isError: Bool, result: String?)? {
        guard text.contains("<task-notification>"), text.contains("<tool-use-id>") else { return nil }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard let m = notificationRegex.firstMatch(in: text, range: full),
              m.numberOfRanges == 4
        else { return nil }
        let toolUseId = ns.substring(with: m.range(at: 1))
        let status = ns.substring(with: m.range(at: 2))
        let summary = ns.substring(with: m.range(at: 3))
        guard summary.hasPrefix("Agent \"") else { return nil }   // a shell task's notification — not ours

        var result: String?
        if let rm = resultRegex.firstMatch(in: text, range: full), rm.numberOfRanges == 2 {
            result = ns.substring(with: rm.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let isError = status.lowercased() == "failed"
        return (toolUseId, isError, result)
    }
}
