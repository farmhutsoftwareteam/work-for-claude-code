// Live registry for the Monitor tool (#95-ish) — background watchers that
// stream events from a long-running script or websocket. Grounded in REAL
// wire data, captured from a live `claude -p --output-format stream-json`
// call (not guessed): Monitor's tool_use is followed by a `system` event
// triad tied together by `task_id`/`tool_use_id` — none of it text-parsed
// like the older V2BackgroundTask mechanism:
//
//   system/task_started      {task_id, tool_use_id, description, task_type}
//   system/task_updated      {task_id, patch: {status, end_time, ...}}
//   system/task_notification {task_id, tool_use_id, status, output_file, summary}
//
// This is a genuinely different, cleaner protocol than the regex-parsed
// "<task-notification>" text V2BackgroundTask reads — structured system
// events, not embedded strings. Scoped to Monitor only here: task_started's
// task_type was "local_bash" in the live capture (same value a plain
// run_in_background Bash task would report), so a task is only tracked as a
// Monitor watch when its tool_use_id matches an actual Monitor tool_use seen
// on the stream — see StreamSession's pendingMonitorCommands.

import Foundation

struct V2MonitorTask: Identifiable, Equatable {
    enum State: Equatable {
        case watching
        case completed
        case failed
        /// The session ended before a terminal task_notification arrived.
        case orphaned
    }

    let id: String              // task_id
    let toolUseId: String
    let description: String
    let command: String?        // Monitor's input.command, when known (nil for a ws-sourced watch)
    let startedAt: Date
    var state: State = .watching
    var finishedAt: Date?
    /// Latest task_notification summary, if any arrived while watching.
    var lastEvent: String?
    var outputFile: String?
}
