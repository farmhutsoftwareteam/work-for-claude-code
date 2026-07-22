// StreamSession — one per pane.
//
// Owns: subprocess (Foundation.Process), three pipes (stdin/stdout/stderr),
// the resolved session_id, model, cwd, lifecycle state machine. Builds a
// public transcript of `TranscriptItem`s as events arrive — the SwiftUI
// transcript view subscribes to this directly.
//
// Backed by:
//   - NDJSONLineReader for stdout decoding
//   - StreamInputWriter for stdin envelopes
//
// What it does NOT do:
//   - The UI rendering (V2TranscriptView). It only feeds the transcript model.
//   - Per-session persistence (resume state, project tracking). Lives in
//     TerminalsController for now; Phase 4 wires them.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "session")

/// Pipe callbacks run off the main actor. Keep only bounded counters here so
/// diagnostics never retain, parse, or publish raw provider output.
private final class StreamIOCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var stderrBytes = 0
    private var stderrLines = 0
    private var decodeFailures = 0

    func addStderr(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        stderrBytes += data.count
        stderrLines += data.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    }

    func addDecodeFailure() { lock.lock(); decodeFailures += 1; lock.unlock() }

    func snapshot() -> (stderrBytes: Int, stderrLines: Int, decodeFailures: Int) {
        lock.lock(); defer { lock.unlock() }
        return (stderrBytes, stderrLines, decodeFailures)
    }
}

/// One row of the session task checklist, accumulated from TaskCreate /
/// TaskUpdate calls — see StreamSession.taskItems. `status` matches the
/// tool's own vocabulary: "pending" | "in_progress" | "completed" (and
/// "deleted", which removes the item rather than being stored as a status).
struct V2TaskItem: Identifiable, Equatable {
    let id: String
    var subject: String
    var status: String
}

@MainActor
final class StreamSession: ObservableObject, V2TranscriptSource {

    // MARK: - Public state

    enum LifecycleState: Equatable, Sendable {
        /// Session has never been started — show the "Start session" CTA.
        case idle
        case spawning
        case initializing
        /// Actively processing a user turn (assistant streaming).
        case working
        case awaitingPermission
        /// Between turns — session alive and ready for the next message.
        /// Composer should be visible, Send button (not Stop).
        case ready
        /// Subprocess terminated to reclaim its ~0.5GB while the tab idles —
        /// transcript and UI stay intact; send() respawns via --resume
        /// transparently. Entered only from .ready by the hibernation scanner.
        case hibernated
        case closing
        case terminated(reason: String)
    }

    @Published private(set) var state: LifecycleState = .idle {
        didSet { lastActivityAt = Date() }
    }

    /// Last lifecycle change — read by the hibernation scanner. Deliberately
    /// NOT @Published: it updates alongside streaming state flips and must
    /// not add fan-out (PERFORMANCE.md rule 2).
    private(set) var lastActivityAt = Date()

    /// Everything needed to respawn this session transparently after
    /// hibernation, captured on every start().
    private var wakeCwd: URL?
    private var wakeClaudeURL: URL?
    private var wakeModel: String?
    private var wakePermissionMode: String?
    private var wakeEffort: String?
    /// Message typed into a hibernated tab — buffered through the respawn and
    /// flushed the moment the new subprocess's stdin writer exists.
    private var pendingWakeText: String?

    /// Stable per-instance identity for VIEW-LAYER change detection. Views
    /// must key "did the session under me change?" on THIS, never on
    /// ObjectIdentifier(session): ObjectIdentifier is the object's memory
    /// address, and malloc freely reuses a deallocated session's address for
    /// a later one — same identifier, so an .onChange/.task(id:) keyed on it
    /// silently never fires for the new session. That was the intermittent
    /// "switched to a tab and the chat is empty" bug: the transcript's
    /// render-window reset was keyed on object identity, address reuse ate
    /// the change signal, and the stale window rendered zero rows forever.
    /// (`sessionId` can't serve this role — it's nil until init reports it.)
    nonisolated let instanceId = UUID()

    @Published private(set) var sessionId: String?
    @Published private(set) var model: String = "claude-sonnet"
    @Published private(set) var permissionMode: String = "default"
    /// `--effort` passed at launch. "" means the flag was omitted — the CLI's
    /// own default applies. Unlike model/permission mode, there is no live
    /// `set_effort`-style control request (verified against the real binary:
    /// every plausible subtype name comes back "Unsupported control request
    /// subtype") and `system/init` never reports an effort catalog either —
    /// so this can only change via a restart, never mid-session.
    @Published private(set) var effort: String = ""

    /// Unsent composer text, persisted on the (per-tab) session so a draft
    /// survives switching tabs and back — the composer view's @State is torn
    /// down when its tab goes off-screen, so the draft has to live here.
    /// Draft persistence for tab switches. Deliberately NOT @Published: the
    /// composer writes this on EVERY keystroke, and a publish here fans out
    /// to everything observing the session — the entire transcript re-rendered
    /// per character typed (worst with a long paste + long chat: the "app
    /// glitches when I paste" bug). Nothing observes it; it's only read back
    /// when the composer for this session reappears. (PERFORMANCE.md rule 2.)
    var composerDraft: String = ""
    private var pendingProviderHandoffContext: String?

    /// MCP servers reported by the binary on `system/init`. Populated once the
    /// session is initialized; empty before then. Drives the right-dock MCP
    /// panel (#34).
    @Published private(set) var mcpServers: [MCPServerInfo] = []

    /// Tools available on this session (from `system/init.tools`). Drives
    /// the dock's tool inventory and the composer's slash-command autocomplete.
    @Published private(set) var tools: [String] = []

    /// Project cwd reported by `system/init`. Useful for UI breadcrumbs.
    @Published private(set) var cwd: String?
    /// V2TranscriptSource conformance — trivial passthrough; `cwd` itself
    /// stays the real property name everywhere else in this file.
    var baseDir: String? { cwd }
    /// V2TranscriptSource conformance — Claude's MCP protocol doesn't
    /// surface progress messages into Atelier the way Codex's does, so this
    /// is always empty for a Claude session.
    var toolLiveStatus: [String: String] { [:] }
    var provider: V2AgentProvider { .claude }

    /// This session's real slash-command list, straight off `system/init` —
    /// skills, project commands, everything the binary itself supports.
    /// Feeds the composer's palette on top of Atelier's own hand-implemented
    /// 10 (see V2SlashCatalog.merged); does NOT require the ACP migration.
    @Published private(set) var reportedSlashCommands: [String] = []

    /// Ordered, append-only transcript. Each item is a separate UI row.
    @Published private(set) var transcript: [TranscriptItem] = []

    /// Monotonic counter bumped on every streaming flush. A cheap O(1) signal
    /// the transcript watches to auto-scroll while a reply grows in place (the
    /// last block mutates without changing `transcript.count`).
    @Published private(set) var streamTick: UInt = 0

    /// tool_use_id → isError, recorded when a tool result arrives. Lets a
    /// tool-call row show its ✓ / ✗ valence (and a spinner while absent).
    @Published private(set) var toolOutcomes: [String: Bool] = [:]
    /// tool_use_id → when the call was appended (≈ execution start: the
    /// assistant snapshot carrying a tool_use arrives before the tool runs).
    /// Lets an in-flight row show elapsed time — a 5-minute test run and a
    /// hung command otherwise render identically to a 5-second one (just a
    /// spinner). Not @Published: every write coincides with a transcript
    /// append, which already republishes.
    private(set) var toolStartTimes: [String: Date] = [:]
    /// Background shell tasks (run_in_background: true) — see
    /// V2BackgroundTask.swift for the wire format this parses.
    @Published private(set) var backgroundTasks: [V2BackgroundTask] = []
    /// Subagents delegated via the Task/Agent tool (#38) — see
    /// V2SubagentRun.swift for the wire format this parses.
    @Published private(set) var subagentRuns: [V2SubagentRun] = []
    var subagentRunsPublisher: Published<[V2SubagentRun]>.Publisher { $subagentRuns }
    /// toolUseId → command, populated when a Bash tool_use is seen, so the
    /// spawn-ack (which only carries a task id + output path) can be matched
    /// back to the real command it started. Small and short-lived — an
    /// entry is consumed the moment its matching tool_result arrives.
    private var pendingBashCommands: [String: String] = [:]
    /// Monitor watchers (#95-ish) — background event streams started by the
    /// Monitor tool. See V2MonitorTask.swift for the (structured, NOT
    /// text-parsed) wire format this reads.
    @Published private(set) var monitorTasks: [V2MonitorTask] = []
    /// toolUseId → (description, command), populated when a Monitor tool_use
    /// is seen. `task_started`'s task_type doesn't distinguish Monitor from a
    /// plain background Bash task (both report "local_bash" — confirmed live)
    /// — this map is what scopes monitorTasks to real Monitor calls only.
    private var pendingMonitorCommands: [String: (description: String, command: String?)] = [:]

    /// Session task checklist — TaskCreate/TaskUpdate replaced TodoWrite as
    /// Claude Code's default task tool as of v2.1.142. Unlike TodoWrite
    /// (which resent the WHOLE list every call, so a single call was always
    /// self-sufficient to render), Task* is incremental: TaskCreate adds one
    /// task, TaskUpdate mutates one by id — so this has to accumulate across
    /// calls rather than being read straight off one call's input.
    @Published private(set) var taskItems: [V2TaskItem] = []
    /// toolUseId → subject, for a TaskCreate whose assigned numeric id
    /// hasn't arrived yet — TaskCreate's INPUT has no id, only its RESULT
    /// text does ("Task #23 created successfully: ..."), so the item can't
    /// be appended until that result lands. Consumed the moment it does.
    private var pendingTaskCreates: [String: String] = [:]

    /// The models THIS binary supports, reported in the `initialize` reply.
    /// This is the authoritative, always-current list (it's how new models
    /// like Sonnet 5 appear the day the CLI ships them) — the picker prefers
    /// it over the history-scan fallback, which could only ever show models
    /// the user had already used somewhere.
    @Published private(set) var availableModels: [V2AvailableModel] = []

    // Streaming coalescer. Deltas accumulate into `streamBuffer` (amortized O(1)
    // append) and are committed to the open transcript block on a throttled
    // flush (~30fps) instead of per token — the old path did `existing + text`
    // every delta (O(n²) over the reply) and re-published, re-chunked, and
    // re-parsed the whole message on every token. `streamingIndex` is the open
    // block's position; nil when no block is open.
    private var streamBuffer = ""
    private var streamingIndex: Int?
    private var flushPending = false
    private let streamFlushInterval: TimeInterval = 0.033

    /// Accumulates `thinking_delta` chunks (verified against real captured
    /// wire text: the final assistant snapshot's `.thinking` block always
    /// has `thinking: ""` — the full text ONLY ever arrives via these
    /// deltas, same as text_delta does for the reply). The comment this
    /// replaces assumed thinking blocks "fully arrive" in the snapshot;
    /// that assumption was never checked against a real session and was
    /// wrong — every extended-thinking block rendered as an expandable row
    /// with nothing inside once opened. Consumed (and cleared) the moment a
    /// `.thinking` block is appended below, so back-to-back thinking blocks
    /// within one turn each pick up only what accumulated since the last one.
    private var thinkingBuffer = ""

    /// Number of older user turns that exist on disk but weren't rendered
    /// into the transcript (we cap the preload at the latest N events).
    /// Drives the "↑ N earlier messages" affordance at the top of the
    /// transcript view; zero when nothing was trimmed.
    @Published private(set) var preloadOmittedTurns: Int = 0

    /// The permission request currently shown in the inline card. When claude
    /// fires multiple tool calls in one turn (e.g. two parallel read-only
    /// calls), it can send several `can_use_tool` requests before the user
    /// has answered the first — those queue in `permissionQueue` rather than
    /// overwriting this, which used to silently orphan the earlier request
    /// (Atelier forgot its requestId, so claude sat blocked forever waiting
    /// on a control_response that would never come).
    @Published private(set) var pendingPermission: PendingPermission?
    private var permissionQueue: [PendingPermission] = []

    /// Requests queued behind the one currently shown. Always mutated in the
    /// same call as pendingPermission, so views observing that via
    /// @ObservedObject see this update in lockstep without its own @Published.
    var queuedPermissionCount: Int { permissionQueue.count }

    /// File paths the user has implicitly authorised by attaching them to a
    /// composer message. When claude asks `can_use_tool` for `Read` against
    /// one of these, we auto-allow so the user doesn't get a permission
    /// prompt for a file they JUST picked. Composer registers a path right
    /// before send().
    private var preApprovedReadPaths: Set<String> = []

    /// Latest result event totals (for the result footer).
    @Published private(set) var latestResult: ResultEvent?

    /// Total tokens used this session, summed from result.usage.
    @Published private(set) var tokensUsed: Int = 0

    /// Tokens currently occupying the context window (prompt size of the last
    /// completed turn). This is measured from the agent's own usage data — the
    /// numerator of the context meter. The window (denominator) is sourced
    /// separately from the provider via V2AppState.contextWindow(for:), not
    /// hardcoded here. Zero until the first turn completes; reset by
    /// resetTranscript().
    @Published private(set) var contextTokens: Int = 0

    /// When the current user turn was sent. Drives the composer's elapsed
    /// "Working… Ns" counter so a slow first token reads as "alive", not
    /// "stuck". Set in send(); only meaningful while state == .working.
    @Published private(set) var turnStartedAt: Date?

    /// Last time ANY stream token (text or thinking delta) arrived —
    /// updated in handleStreamEvent, on every delta. Deliberately NOT
    /// @Published: once streaming starts this would fire ~30x/sec, and
    /// nothing needs to reactively observe it — V2LiveTranscript's stall
    /// indicator polls it via TimelineView instead (PERFORMANCE.md rule 2).
    /// Powers the "still working… Ns since last update" cue for a reply
    /// that's mid-stream but has gone quiet (rate limiting, a slow
    /// embedded tool call, network hiccup) — before this, the indicator
    /// collapsed to a bare dot the instant the FIRST token landed and gave
    /// no signal at all if generation then stalled.
    private(set) var lastStreamActivityAt = Date()

    /// True while a resumed session is reading its history off disk (before
    /// the process spawns). Drives a "Loading conversation…" indicator so the
    /// click registers and the UI never looks frozen.
    @Published private(set) var isResuming = false

    /// Human-facing reason the session couldn't open / ended badly (e.g. the
    /// conversation's history was deleted). Shown to the user with a "start
    /// fresh" option instead of a cryptic "stream closed". nil = no error.
    @Published private(set) var endError: String?

    /// Set true while an `api_retry` is in flight.
    @Published private(set) var isRetrying: Bool = false

    /// Detail of the most recent api_retry event (cleared on the next
    /// non-retry event). Drives the inline retry indicator copy.
    @Published private(set) var lastRetry: RetryInfo?

    struct RetryInfo: Equatable, Sendable {
        let attempt: Int
        let maxRetries: Int
        let retryDelayMs: Int?
        let errorStatus: String?
    }

    /// Most recent rate_limit_event — a standalone top-level event (not a
    /// `system` subtype), previously undecoded entirely (fell to `.unknown`
    /// and was dropped). Doubles as the refresh trigger for `usageLimits`.
    @Published private(set) var rateLimitInfo: RateLimitInfo?

    /// Typed plan-usage meters (5h/weekly utilization %, reset times, plan)
    /// from the zero-cost get_usage control request — refreshed on init,
    /// after each turn's result, and on every rate_limit_event push. Drives
    /// the composer's compact meter + the session-config LIMITS section.
    @Published private(set) var usageLimits: V2UsageLimits?

    // MARK: - Internals

    private var process: Process?
    private var inputWriter: StreamInputWriter?

    /// Co-driven terminal bridge (#55): the atelier-terminal MCP server for
    /// THIS session, plus the --mcp-config file that points claude at it.
    /// Created lazily on first spawn; survives restarts (same socket).
    private(set) var terminalBridge: TerminalBridge?
    private var terminalMCPConfigURL: URL?

    deinit {
        terminalBridge?.closeBridge()
        if let url = terminalMCPConfigURL { try? FileManager.default.removeItem(at: url) }
    }

    // Resume liveness tracking: if a resumed spawn dies before producing any
    // substantive event (session already running, or its transcript was
    // cleaned up), handleStreamEnd surfaces a friendly endError instead of a
    // blank "stream closed".
    private var resumeFallbackArmed = false
    private var sawLiveEvent = false
    /// Strong references to the pipe FileHandles so the OS keeps firing
    /// our readabilityHandlers. Without these, ARC has been observed to
    /// release the handles mid-session and the handler stops firing.
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    private var diagnosticsOperationID: String?
    private var processStartedAt: Date?

    // MARK: - Lifecycle

    /// Replay a session's prior `~/.claude/projects/<…>/<id>.jsonl` into the
    /// transcript so a resumed tab opens with context instead of a blank
    /// canvas. Call this BEFORE `start(…, resumeId:)` — once claude is live
    /// new events append to the same transcript.
    ///
    /// Historical assistant events keep their text blocks (we don't have
    /// matching stream_event deltas at preload time, so the snapshot is the
    /// only source of the message body). Tool uses, tool results, and
    /// thinking blocks render via the same `.assistantBlock` row used live.
    func preloadHistory(_ preload: SessionHistoryLoader.Preload) {
        preloadOmittedTurns = preload.omittedUserTurns
        for event in preload.events {
            switch event {
            case .user(let m):
                // Sidechain guard, same as the live path (handle(event:)) —
                // a subagent's own tool_result/text lives in its dedicated
                // transcript file (V2SubagentTail), not the parent's.
                guard m.parentToolUseId == nil else { continue }
                for block in m.message.content {
                    switch block {
                    case .text(let s):
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Injected context (task-notifications) is registry
                        // signal, not a user bubble — parse, don't render.
                        if trimmed.contains("<task-notification>") {
                            applyNotificationText(s)
                        } else if !trimmed.isEmpty {
                            transcript.append(.userText(trimmed))
                        }
                    case .toolResult(let toolUseId, let content, let isError):
                        // Record the outcome exactly like the live path does
                        // — without this, every tool row in a RESTORED
                        // transcript kept its "still running" spinner
                        // forever (outcome nil = spinner), making an old
                        // conversation read as full of hung tools.
                        toolOutcomes[toolUseId] = (isError ?? false)
                        recordTaskResult(toolUseId: toolUseId, content: content)
                        // Registry rebuild (#74): spawn acks and agent
                        // results in history repopulate the bg-task and
                        // subagent registries so a restored or OBSERVED
                        // session opens with its strip/cards correct, not
                        // empty. Mirrors the live .toolResult handling.
                        if let runIdx = subagentRuns.firstIndex(where: { $0.toolUseId == toolUseId }) {
                            let text = content.asString ?? ""
                            if subagentRuns[runIdx].isBackground,
                               let agentId = V2SubagentParser.agentId(fromSpawnAck: text) {
                                subagentRuns[runIdx].agentId = agentId
                            } else {
                                subagentRuns[runIdx].state = (isError ?? false) ? .failed : .completed
                                subagentRuns[runIdx].finishedAt = Date()
                                subagentRuns[runIdx].resultText = text.isEmpty ? nil : text
                            }
                            continue   // card renders it; raw ack row is noise
                        }
                        transcript.append(.assistantBlock(block))
                        if let spawn = V2BackgroundTaskParser.parseSpawn(from: content.asString) {
                            let command = pendingBashCommands.removeValue(forKey: toolUseId) ?? ""
                            backgroundTasks.append(V2BackgroundTask(
                                id: spawn.id, command: command, outputPath: spawn.outputPath, startedAt: Date()
                            ))
                        }
                    default:
                        break
                    }
                }
            case .assistant(let m):
                guard m.parentToolUseId == nil else { continue }
                for block in m.message.content {
                    // Unlike live handling we KEEP text blocks here — the
                    // streaming deltas that would normally populate the
                    // transcript aren't replayed on resume.
                    switch block {
                    case .text(let s):
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            transcript.append(.assistantBlock(.text(trimmed)))
                        }
                    case .toolUse(let id, let name, let input):
                        if name == "Bash" {
                            pendingBashCommands[id] = input.dig("command")?.asString ?? ""
                        }
                        recordTaskToolUse(id: id, name: name, input: input)
                        if V2SubagentParser.isAgentSpawn(toolName: name),
                           !subagentRuns.contains(where: { $0.toolUseId == id }) {
                            subagentRuns.append(V2SubagentRun(
                                toolUseId: id,
                                description: input.dig("description")?.asString ?? "agent",
                                agentType: input.dig("subagent_type")?.asString ?? "general-purpose",
                                isBackground: input.dig("run_in_background")?.asBool ?? false,
                                startedAt: Date()
                            ))
                        }
                        transcript.append(.assistantBlock(block))
                    case .fallback(let from, let to):
                        // Same treatment as the live path — see handle(event:).
                        transcript.append(Self.fallbackNote(from: from, to: to))
                    case .toolResult, .thinking, .image, .unknown:
                        transcript.append(.assistantBlock(block))
                    }
                }
            default:
                break
            }
        }
        // History gave us no completion for these. For a RESTORE the channel
        // is gone — mark orphaned so "running" never lies. For an OBSERVER
        // the owner is alive elsewhere and may still finish them — keep
        // .running; the strip's hung-detection stays honest via output mtime.
        if !isObserving {
            orphanRunningBackgroundTasks()
        }
    }

    /// Task-notification text (bg-task + subagent completions) → registry
    /// updates. Shared by the live .user text branch and history preload.
    private func applyNotificationText(_ text: String) {
        if let done = V2BackgroundTaskParser.parseCompletion(from: text),
           let idx = backgroundTasks.firstIndex(where: { $0.id == done.id }) {
            backgroundTasks[idx].state = done.isError ? .failed(exitCode: done.exitCode) : .completed(exitCode: done.exitCode)
            backgroundTasks[idx].finishedAt = Date()
        }
        if let done = V2SubagentParser.parseCompletion(from: text),
           let idx = subagentRuns.firstIndex(where: { $0.toolUseId == done.toolUseId }) {
            subagentRuns[idx].state = done.isError ? .failed : .completed
            subagentRuns[idx].finishedAt = Date()
            if let result = done.result { subagentRuns[idx].resultText = result }
        }
    }

    // MARK: - Task checklist (TaskCreate / TaskUpdate)

    /// Called from BOTH the live and history-preload .toolUse handling for
    /// TaskCreate/TaskUpdate — same split as everywhere else in this file:
    /// TaskCreate can't be recorded yet (its id isn't known until the
    /// result), TaskUpdate applies immediately since it already carries a
    /// known taskId.
    private func recordTaskToolUse(id: String, name: String, input: JSONValue) {
        if name == "TaskCreate" {
            pendingTaskCreates[id] = input.dig("subject")?.asString ?? "task"
        } else if name == "TaskUpdate" {
            applyTaskUpdate(input)
        }
    }

    private func applyTaskUpdate(_ input: JSONValue) {
        guard let taskId = input.dig("taskId")?.asString else { return }
        // "deleted" removes the task from the checklist entirely rather
        // than showing a fourth status state nobody asked to see.
        if input.dig("status")?.asString == "deleted" {
            taskItems.removeAll { $0.id == taskId }
            return
        }
        guard let idx = taskItems.firstIndex(where: { $0.id == taskId }) else {
            // Unknown id (e.g. a TaskCreate whose result we failed to
            // correlate) — nothing to update. Fails closed: never
            // fabricates a row with no real subject.
            return
        }
        if let status = input.dig("status")?.asString { taskItems[idx].status = status }
        if let subject = input.dig("subject")?.asString { taskItems[idx].subject = subject }
    }

    /// Called from BOTH the live and history-preload .toolResult handling —
    /// resolves a pending TaskCreate now that its assigned id has arrived.
    /// The id is prose ("Task #23 created successfully: ..."), not a
    /// structured field, so this degrades gracefully: if the wording ever
    /// changes and the id can't be parsed, the task just never appears
    /// rather than guessing an id that could collide with a real one.
    private func recordTaskResult(toolUseId: String, content: ToolResultContent) {
        guard let subject = pendingTaskCreates.removeValue(forKey: toolUseId) else { return }
        let text = content.asString
        guard let range = text.range(of: #"Task #(\d+)"#, options: .regularExpression) else { return }
        let taskId = String(text[range].drop(while: { $0 != "#" }).dropFirst())
        guard !taskItems.contains(where: { $0.id == taskId }) else { return }
        taskItems.append(V2TaskItem(id: taskId, subject: subject, status: "pending"))
    }

    /// Resume a session from history without freezing the UI. Reads + decodes
    /// the (possibly large) .jsonl OFF the main thread, then preloads it and
    /// starts the process. `isResuming` is true for the read window so the UI
    /// shows a loading indicator instead of looking stuck.
    func resume(cwd: URL, claudeURL: URL, sessionId: String, model: String? = nil, permissionMode: String? = nil, effort: String? = nil) {
        // Re-entrancy guard: a double-click must not schedule two preloads
        // (which would append the history twice before start() no-ops).
        guard !isResuming else { return }
        switch state { case .idle, .terminated: break; default: return }
        isResuming = true
        resumeFallbackArmed = true   // if the resume spawn dies silently, start fresh
        let cwdPath = cwd.path
        Task { [weak self] in
            let preload = await Task.detached(priority: .userInitiated) {
                SessionHistoryLoader.load(sessionId: sessionId, projectCwd: cwdPath)
            }.value
            guard let self else { return }
            if let preload { self.preloadHistory(preload) }
            self.isResuming = false
            self.start(cwd: cwd, claudeURL: claudeURL, resumeId: sessionId,
                       model: model, permissionMode: permissionMode, effort: effort)
        }
    }

    /// Restore a previous conversation WITHOUT spawning its claude process —
    /// the launch-restore path. Preloads the transcript off-main exactly
    /// like resume(), but lands in .hibernated instead of spawning: the tab
    /// reads as a "Resting" conversation (transcript on screen, composer
    /// live) and the first message wakes it via --resume — the same
    /// machinery idle tabs already use. Restoring N tabs at launch is
    /// therefore N bounded file reads and ZERO subprocesses (each live
    /// claude process costs 0.4-0.6GB; this is what makes restore free).
    func restoreHibernated(cwd: URL, claudeURL: URL, sessionId: String, model: String? = nil, permissionMode: String? = nil, effort: String? = nil) {
        guard !isResuming else { return }
        guard case .idle = state else { return }
        isResuming = true
        // The wake recipe send() needs: wake(thenSend:) respawns with these
        // plus resumeId — which reads self.sessionId, so set it now (on a
        // real resume the init reply reports the same id back anyway).
        wakeCwd = cwd
        wakeClaudeURL = claudeURL
        wakeModel = model
        wakePermissionMode = permissionMode
        wakeEffort = effort
        self.sessionId = sessionId
        let cwdPath = cwd.path
        Task { [weak self] in
            let preload = await Task.detached(priority: .userInitiated) {
                SessionHistoryLoader.load(sessionId: sessionId, projectCwd: cwdPath)
            }.value
            guard let self else { return }
            if let preload { self.preloadHistory(preload) }
            self.isResuming = false
            self.state = .hibernated
        }
    }

    // MARK: - Observer mode (#74)

    /// True while this session is a read-only live view of a transcript some
    /// OTHER process owns (CLI, VS Code, another window). Gates every write
    /// path: no spawn, no send, no workspace persistence, no reconnect
    /// sweeps — observing must never become writing (a message sent into a
    /// session another harness owns forks its conversation state).
    @Published private(set) var isObserving = false
    /// When the observed file last grew — drives the "observing" vs
    /// "went quiet Xm ago" header language.
    @Published private(set) var observedFileLastGrewAt: Date?
    private var observerTask: Task<Void, Never>?

    /// Watch a session live off its growing on-disk transcript: bounded
    /// preload (same loader restore uses), then a 1Hz poll that stats the
    /// file and reads ONLY the new bytes since the last offset, frames them
    /// with LineBuffer, and dispatches each complete line through the same
    /// event path a live session's stdout uses. Every existing surface —
    /// transcript, bg-task strip, delegation cards, tool timers — works
    /// unchanged because the events are indistinguishable from live ones.
    func startObserving(cwd: URL, sessionId: String) {
        guard case .idle = state, !isObserving, !isResuming else { return }
        isObserving = true
        isResuming = true
        self.sessionId = sessionId
        self.cwd = cwd.path
        let cwdPath = cwd.path
        let url = SessionHistoryLoader.jsonlURL(sessionId: sessionId, projectCwd: cwdPath)

        observerTask = Task { [weak self] in
            // Offset snapshot BEFORE the preload read: anything written
            // between this stat and the preload can be double-delivered (the
            // preload may already include it, then the incremental read
            // re-delivers) — a ~millisecond window, cosmetic at worst, and
            // the alternative (snapshot after) can DROP lines instead. Never
            // drop.
            let initialOffset = (try? FileManager.default
                .attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

            let preload = await Task.detached(priority: .userInitiated) {
                SessionHistoryLoader.load(sessionId: sessionId, projectCwd: cwdPath)
            }.value
            guard let self else { return }
            if let preload { self.preloadHistory(preload) }
            self.isResuming = false
            self.observedFileLastGrewAt = Date()

            var offset = initialOffset
            let buffer = LineBuffer()
            let decoder = JSONDecoder()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break }
                // Stat first — no read, no allocation when nothing changed
                // (the common tick for a session that's thinking).
                let size = (try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
                guard size > offset else { continue }

                let readFrom = offset
                let chunk = await Task.detached(priority: .utility) { () -> Data? in
                    guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
                    defer { try? fh.close() }
                    try? fh.seek(toOffset: readFrom)
                    return try? fh.readToEnd()
                }.value
                guard let chunk, !chunk.isEmpty else { continue }
                offset = readFrom + UInt64(chunk.count)
                observedFileLastGrewAt = Date()

                buffer.append(chunk)
                for line in buffer.drainLines() {
                    guard let event = try? decoder.decode(StreamEvent.self, from: line) else { continue }
                    observeDispatch(event)
                }
            }
        }
    }

    func stopObserving() {
        observerTask?.cancel()
        observerTask = nil
        isObserving = false
    }

    /// The observer's event dispatch: identical to the live path, PLUS
    /// appending the user's own text turns — on the live path send() appends
    /// those locally before the wire echoes them back, so handle(event:)'s
    /// .user case deliberately doesn't; here there is no local send.
    private func observeDispatch(_ event: StreamEvent) {
        if case .user(let m) = event {
            for block in m.message.content {
                if case .text(let s) = block {
                    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Injected context (task notifications etc.) is parsed by
                    // handle() below, never rendered as a user bubble.
                    if !trimmed.isEmpty, !trimmed.contains("<task-notification>") {
                        transcript.append(.userText(trimmed))
                    }
                }
            }
        }
        handle(event: event)
    }

    /// Launch `claude -p` in the project's cwd. No-op if not idle. Pass a
    /// `resumeId` (an existing Claude session UUID under `~/.claude/projects`)
    /// to replay that session's history before the new turn — claude will
    /// stream its prior messages out of stdout in addition to handling new
    /// user turns.
    func start(cwd: URL, claudeURL: URL, resumeId: String? = nil, model: String? = nil, permissionMode: String? = nil, effort: String? = nil) {
        // Allow (re)start from a finished session too, not just a fresh one.
        // stop() leaves state at .terminated, so the previous `== .idle`
        // guard silently no-op'd every restart — the "Restart session" button
        // and any restart-to-apply-permission path did nothing.
        // (.terminated carries an associated reason, so it can't be compared
        // with ==; pattern-match instead.)
        switch state {
        case .idle, .terminated, .hibernated: break
        default: return
        }
        // Capture the wake recipe — hibernation respawns with exactly these.
        wakeCwd = cwd
        wakeClaudeURL = claudeURL
        wakeModel = model
        wakePermissionMode = permissionMode
        wakeEffort = effort
        // Clear transient per-run state so a restart doesn't inherit a stale
        // retry banner or permission card. Transcript is intentionally kept
        // so the conversation stays on screen across the restart.
        isRetrying = false
        lastRetry = nil
        pendingPermission = nil
        permissionQueue.removeAll()
        state = .spawning
        // Reset the "saw a live event" tracker + any prior error for this spawn.
        sawLiveEvent = false
        endError = nil
        // No streaming block is open on a fresh spawn (the transcript is kept,
        // but the next reply starts a new block).
        flushPending = false
        streamingIndex = nil
        streamBuffer = ""
        thinkingBuffer = ""

        // Resolve the permission mode for this spawn: explicit arg →
        // persisted default → "acceptEdits". Persisting it here (and in
        // setPermissionMode / cyclePermissionMode) is what makes the choice
        // STICK across new tabs, restarts, and resumes — previously every
        // spawn reset to claude's "default" because we never passed
        // --permission-mode and never persisted the user's pick.
        let resolvedPermission = permissionMode
            ?? UserDefaults.standard.string(forKey: Self.defaultPermissionKey)
            ?? "acceptEdits"

        let diagnosticsOperationID = UUID().uuidString
        self.diagnosticsOperationID = diagnosticsOperationID
        self.processStartedAt = Date()
        log.info("Stream session starting")
        Diagnostics.record(
            subsystem: .claude, operation: .streamStart, outcome: .started,
            provider: .claude, operationID: diagnosticsOperationID
        )

        let process = Process()
        process.executableURL = claudeURL
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]

        // Co-driven terminal (#55): host the atelier-terminal MCP server for
        // this session and point claude at it via --mcp-config. Degrades
        // silently — a bridge failure must never block a session.
        if terminalBridge == nil {
            terminalBridge = try? TerminalBridge(scope: ObjectIdentifier(self), defaultCwd: cwd.path)
        }
        if let bridge = terminalBridge {
            if terminalMCPConfigURL == nil {
                let cfg: [String: Any] = ["mcpServers": ["atelier-terminal": [
                    "command": "/usr/bin/nc",
                    "args": ["-U", bridge.socketPath],
                ]]]
                let url = URL(fileURLWithPath: NSTemporaryDirectory() + "at-mcp-\(UUID().uuidString.prefix(8)).json")
                if let data = try? JSONSerialization.data(withJSONObject: cfg),
                   (try? data.write(to: url)) != nil {
                    terminalMCPConfigURL = url
                }
            }
            if let cfgURL = terminalMCPConfigURL {
                args += ["--mcp-config", cfgURL.path]
            }
        }
        if let resumeId, !resumeId.isEmpty {
            args.append("--resume")
            args.append(resumeId)
            self.sessionId = resumeId
        }
        if let model, !model.isEmpty {
            args.append("--model")
            args.append(model)
            // Reflect optimistically so the chip + footer pill don't read
            // "claude" for the first few frames before system/init lands.
            self.model = model
        }
        // --permission-mode makes the spawn honour the chosen mode from the
        // first turn instead of defaulting to per-call prompts.
        args.append("--permission-mode")
        args.append(resolvedPermission)
        self.permissionMode = resolvedPermission
        if let effort, !effort.isEmpty {
            args.append("--effort")
            args.append(effort)
            self.effort = effort
        } else {
            self.effort = ""
        }
        // GUARDRAIL — do not remove without reading this: `--fallback-model`
        // is what ENABLES claude's automatic model reroute on overload/rate-
        // limit (confirmed against `claude --help`: "Enable automatic
        // fallback to specified model(s)..."). Omitting it — which every
        // spawn path in this file does — means the CLI never silently
        // switches models on its own; a request just fails instead. That's
        // the actual guardrail a user asked for after noticing an
        // externally-run session (a GitHub-integrated Claude session, not
        // one Atelier spawned) auto-rerouting to Fable mid-conversation
        // (2026-07-21) — Fable/experimental-tier turns can draw down a
        // plan's usage limits faster, so an invisible auto-switch onto it
        // is a real cost, not a cosmetic one. If a future feature wants
        // opt-in fallback, it must pass an explicit allow-list that
        // excludes any "fable"-family id — never bare `--fallback-model`
        // with no list, and never one sourced from something Anthropic
        // could change server-side. assertNeverAutoFallback() below is the
        // enforced half of this comment, not just documentation.
        Self.assertNeverAutoFallback(&args)
        process.arguments = args
        process.currentDirectoryURL = cwd
        // Critical: GUI-launched apps inherit launchd's stripped PATH which
        // doesn't include ~/.local/bin, Homebrew, node managers, etc. The v1
        // TerminalsController solves this with enrichedEnvironment(); we
        // mirror that logic here without the SwiftTerm dependency. Without
        // this, claude either can't find its own node runtime or fails to
        // initialize silently — and the session sits on .initializing
        // forever because no system/init is ever emitted.
        process.environment = Self.enrichedEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Avoid SIGPIPE killing the host if the child closes early.
        signal(SIGPIPE, SIG_IGN)

        do {
            try process.run()
        } catch {
            log.error("Stream session spawn failed")
            Diagnostics.record(
                severity: .error, subsystem: .claude, operation: .streamStart, outcome: .failed,
                provider: .claude, operationID: diagnosticsOperationID, code: "spawn-failed"
            )
            state = .terminated(reason: "spawn failed: \(error.localizedDescription)")
            return
        }
        log.info("Stream session spawned")

        self.process = process
        let writer = StreamInputWriter(fileHandle: stdinPipe.fileHandleForWriting)
        self.inputWriter = writer
        self.state = .initializing

        // CRITICAL: claude with --input-format stream-json sits idle until
        // it receives the SDK's `initialize` control_request handshake on
        // stdin. Without this, system/init is never emitted and the session
        // is stuck on .initializing forever. (#36)
        //
        // Wake-from-hibernation: the message that triggered the respawn must
        // go out AFTER that handshake — claude has to see `initialize`
        // first. Sending it via a second, independent Task raced the
        // handshake with no ordering guarantee between the two; chain them
        // explicitly in one Task instead.
        let queuedWakeText = pendingWakeText
        pendingWakeText = nil
        Task { [weak self] in
            do {
                try await writer.initialize()
                log.info("Stream session handshake sent")
                Diagnostics.record(
                    subsystem: .claude, operation: .streamHandshake, outcome: .succeeded,
                    provider: .claude, operationID: diagnosticsOperationID
                )
            } catch {
                log.error("Stream session handshake failed")
                Diagnostics.record(
                    severity: .error, subsystem: .claude, operation: .streamHandshake, outcome: .failed,
                    provider: .claude, operationID: diagnosticsOperationID, code: "write-failed"
                )
            }
            if let queuedWakeText {
                self?.send(text: queuedWakeText)
            }
        }

        // Drain stdout via readabilityHandler — the exact pattern AtelierSpike
        // uses and that we know works against the live binary. We previously
        // tried FileHandle.bytes.lines (buffers on pipes) and an AsyncStream
        // wrapper around readabilityHandler (events never reached the
        // consumer) — both left the session stuck on .initializing because
        // system/init was never observed. (#36)
        let buffer = LineBuffer()
        let decoder = JSONDecoder()
        let ioCounters = StreamIOCounters()
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF — claude closed its stdout. A trailing line that never
                // got its terminating \n (process crashed mid-write, or
                // exited right after its last write — e.g. a final `result`
                // event) would otherwise be silently dropped: try one last
                // decode of whatever's left in the buffer first.
                handle.readabilityHandler = nil
                let remainder = buffer.drainRemainder()
                let trailingEvent: StreamEvent? = remainder.isEmpty ? nil : {
                    do {
                        return try decoder.decode(StreamEvent.self, from: remainder)
                    } catch {
                        ioCounters.addDecodeFailure()
                        log.warning("Stream event decode failed at end of stream")
                        return nil
                    }
                }()
                Task { @MainActor [weak self] in
                    if let trailingEvent { self?.handle(event: trailingEvent) }
                    let counts = ioCounters.snapshot()
                    if counts.decodeFailures > 0 {
                        Diagnostics.record(
                            severity: .warning, subsystem: .claude, operation: .streamDecode, outcome: .observed,
                            provider: .claude, operationID: self?.diagnosticsOperationID,
                            code: "decode-failed", measurements: ["count": counts.decodeFailures]
                        )
                    }
                    self?.handleStreamEnd()
                }
                return
            }
            buffer.append(chunk)
            for lineData in buffer.drainLines() {
                guard !lineData.isEmpty else { continue }
                do {
                    let event = try decoder.decode(StreamEvent.self, from: lineData)
                    Task { @MainActor [weak self] in
                        self?.handle(event: event)
                    }
                } catch {
                    ioCounters.addDecodeFailure()
                }
            }
        }

        // Drain stderr so a chatty child cannot block. Keep bounded counts,
        // never raw text: provider output can contain paths, credentials, or
        // a user's prompt echoed by a tool.
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                let counts = ioCounters.snapshot()
                if counts.stderrBytes > 0 {
                    Diagnostics.record(
                        severity: .warning, subsystem: .claude, operation: .streamStderr, outcome: .observed,
                        provider: .claude, operationID: diagnosticsOperationID,
                        code: "stderr-received", measurements: ["bytes": counts.stderrBytes, "lines": counts.stderrLines]
                    )
                }
                return
            }
            ioCounters.addStderr(chunk)
        }

        // Keep these handles strongly held so the OS keeps firing
        // readabilityHandler. Without these references, ARC could release
        // the FileHandles and the handlers silently stop.
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrHandle
    }

    private func handleStreamEnd() {
        log.info("Stream session stream ended")
        let elapsed = processStartedAt.map { Int(Date().timeIntervalSince($0) * 1_000) }
        Diagnostics.record(
            subsystem: .claude, operation: .streamEnd, outcome: .observed,
            provider: .claude, operationID: diagnosticsOperationID,
            code: "stream-closed", durationMilliseconds: elapsed
        )
        // Cover every non-terminal state, not just .working / .initializing.
        // If claude crashed in .ready or .awaitingPermission, the UI would
        // previously leave the composer enabled and the permission card up
        // while the process was actually dead.
        switch state {
        case .terminated, .closing, .idle, .hibernated:
            // .hibernated: WE killed the process — the EOF is expected and the
            // state must survive it (send() wakes via --resume).
            break
        case .spawning, .initializing, .ready, .working, .awaitingPermission:
            // A resume that died before any event at all (e.g. the session is
            // running elsewhere) — give the user a reason, not a blank "stream
            // closed". (The error-result path sets endError itself.)
            if resumeFallbackArmed, !sawLiveEvent, endError == nil {
                endError = "Couldn't open this conversation — it may be running in another window."
            }
            resumeFallbackArmed = false
            isResuming = false
            // Don't leave a retry banner or permission card hovering over a
            // dead session.
            isRetrying = false
            lastRetry = nil
            pendingPermission = nil
            permissionQueue.removeAll()
            orphanRunningBackgroundTasks()
            state = .terminated(reason: "stream closed")
        }
    }

    // MARK: - Auto-fallback guardrail

    /// The transcript note for a server-side model reroute. Atelier's own
    /// spawns can't trigger this (see assertNeverAutoFallback below), but
    /// the wire shape exists and swapping it silently would be worse than
    /// this being unreachable in practice, so it stays real rather than
    /// removed. Escalated to a visible warning — not just an info aside —
    /// when the landing model is fable-family: that tier draws down a
    /// plan's usage limits faster (user-reported, 2026-07-21; no public
    /// Anthropic API exposes a documented multiplier to verify against, so
    /// this deliberately doesn't claim a specific number), and an invisible
    /// swap onto it is a real cost, not a cosmetic one.
    static func fallbackNote(from: String?, to: String?) -> TranscriptItem {
        // .info, not .error, on purpose even for the fable case: nothing
        // failed here — the turn succeeded, just on a costlier model — and
        // .error's red triangle (SystemNoteKind.error is documented as
        // "non-retryable errors") would misrepresent that. The emphasis
        // belongs in the wording, not a borrowed failure color.
        let landedOnFable = to.map { V2DiscoveredModel.familyKey($0) == "fable" } ?? false
        let base = "model fallback: \(from ?? "?") was unavailable — this turn ran on \(to ?? "another model")"
        return .systemNote(
            kind: .info,
            text: landedOnFable ? base + " ⚠️ fable \(V2DiscoveredModel.usageWarning)" : base
        )
    }

    /// The enforced half of the guardrail comment at the `start()` call
    /// site: `--fallback-model` is what ENABLES claude's automatic model
    /// reroute on overload/rate-limit (`claude --help`: "Enable automatic
    /// fallback..."), so omitting it is what guarantees a spawn never
    /// silently switches models — a request fails instead. This function
    /// makes that a real invariant instead of just an intention: it strips
    /// the flag (and its value) if present, so a RELEASE build fails safe
    /// even if some future edit reintroduces it, and asserts in DEBUG so
    /// that edit is caught immediately rather than silently neutralized
    /// forever. `inout` and side-effecting on purpose — this is meant to be
    /// unconditionally load-bearing, not a check someone can skip calling.
    static func assertNeverAutoFallback(_ args: inout [String]) {
        guard let idx = args.firstIndex(of: "--fallback-model") else { return }
        assertionFailure("--fallback-model must never be passed when spawning claude — see the guardrail comment above this call site in start().")
        let hasValue = idx + 1 < args.count
        args.removeSubrange(idx..<(idx + (hasValue ? 2 : 1)))
    }

    // MARK: - Enriched environment

    /// PATH-enriched environment for the spawned `claude` process. GUI-
    /// launched apps inherit launchd's stripped PATH which doesn't include
    /// the usual dev-tool install locations. Adding them is what makes
    /// `~/.local/bin/claude` actually find its dependencies. Mirrors v1's
    /// TerminalsController.enrichedEnvironment but without the SwiftTerm
    /// dependency (we read ProcessInfo directly).
    private static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin",          // Anthropic native claude install
            "\(home)/.claude/local",       // alt native install location
            "\(home)/.cargo/bin",          // uv / uvx
            "\(home)/.volta/bin",          // volta node manager
            "\(home)/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]
        let fm = FileManager.default
        let basePath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = Set(basePath.split(separator: ":").map(String.init))
        let additions = candidates.filter { fm.fileExists(atPath: $0) && !existing.contains($0) }
        if !additions.isEmpty {
            env["PATH"] = additions.joined(separator: ":") + ":" + basePath
        }
        // Sane defaults for HOME + USER if they're missing — happens in
        // launchd contexts.
        if env["HOME"] == nil { env["HOME"] = home }
        if env["USER"] == nil { env["USER"] = NSUserName() }
        // TERM helps tools that check stdout-is-a-tty heuristics.
        env["TERM"] = "xterm-256color"
        return env
    }

    // MARK: - Public model control

    /// Tell claude to use a different model for subsequent turns. Goes
    /// through the control protocol on stdin — see StreamInputWriter.
    func setModel(_ model: String) {
        Task {
            do {
                try await inputWriter?.setModel(model)
                self.model = model
            } catch {
                log.error("Stream session model update failed")
            }
        }
    }

    /// Re-poll live MCP server status (the mcp_status control request).
    /// `mcpServers` otherwise only ever holds the snapshot system/init took
    /// at spawn — a server that was still connecting then read "starting"
    /// in the UI forever, even long after it connected or failed. The MCP
    /// panel calls this on appear + on a short cadence while visible.
    func refreshMCPStatus() {
        guard !isObserving else { return }
        switch state { case .working, .ready, .awaitingPermission: break; default: return }
        Task {
            do { try await inputWriter?.requestMCPStatus() }
            catch { log.error("Stream session MCP-status request failed") }
        }
    }

    /// Ask for fresh plan-usage meters (the get_usage control request).
    /// Cheap and local — the binary answers from its own account state, no
    /// model turn — but only serviced post-init, hence the state gate.
    func refreshUsage() {
        guard !isObserving else { return }
        switch state { case .working, .ready, .awaitingPermission: break; default: return }
        Task {
            do { try await inputWriter?.requestUsage() }
            catch { log.error("Stream session usage request failed") }
        }
    }

    /// Marks a turn as started the moment the STREAM itself proves one is
    /// underway, for turns Atelier never called send() for — a
    /// ScheduleWakeup (or any other self-queued continuation) resuming the
    /// process on its own. `send()` below flips .ready → .working
    /// optimistically for turns WE start; nothing did the equivalent for
    /// one the binary starts by itself, so .state sat at .ready — read by
    /// `V2AppState.tabStatus` as idle — for the whole autonomous turn, and
    /// the transcript kept showing the PREVIOUS turn's result footer
    /// underneath live-streaming content (user-reported, 2026-07-21;
    /// confirmed against this session's own transcript: a ScheduleWakeup's
    /// `queue-operation` dequeue is immediately followed by a top-level
    /// `user` event and then `assistant` events, with no send() in
    /// between). No-op once a turn is already tracked — this only fires the
    /// FIRST observed event of an otherwise-untracked turn.
    private func beginTurnIfObservedFromStream() {
        guard state == .ready else { return }
        latestResult = nil
        turnStartedAt = Date()
        state = .working
    }

    /// Send a user turn. Triggers a new assistant cycle from the binary.
    func send(text: String) {
        // The hard observer rule: watching must never become writing. A
        // message sent into a session another process owns (via --resume)
        // forks its conversation state under that harness. The composer is
        // gated in the UI too — this is the defense-in-depth backstop.
        guard !isObserving else { return }
        // Typing into a hibernated tab IS the wake gesture — respawn with
        // --resume and deliver this message once the new writer exists.
        if state == .hibernated {
            wake(thenSend: text)
            return
        }
        guard let inputWriter else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        V2Signpost.signposter.emitEvent("turn-start")
        finalizeStreamingText()   // seal any open reply before this user turn
        transcript.append(.userText(trimmed))
        // Clear the previous turn's result footer the instant a new turn
        // starts. It's only set when a turn finishes and was never reset,
        // so a follow-up message used to render under a stale "1 turn · 3s ·
        // $0.16" footer that looked "done" — making the new turn feel like
        // nothing was happening until text finally streamed in below it.
        latestResult = nil
        // Optimistic state flip — if the write fails we roll back below.
        // Previously the success path was the only one that set .working,
        // so a failed send left the transcript showing the user turn with
        // the session stuck in .ready and no visible error.
        turnStartedAt = Date()
        state = .working
        let handoffContext = pendingProviderHandoffContext
        let wireText = handoffContext.map {
            "<atelier_provider_handoff>\n\($0)\n</atelier_provider_handoff>\n\n\(trimmed)"
        } ?? trimmed
        Task { [weak self] in
            guard let self else { return }
            do {
                try await inputWriter.sendUserText(wireText)
                if self.pendingProviderHandoffContext == handoffContext {
                    self.pendingProviderHandoffContext = nil
                }
            } catch {
                log.error("Stream session user-turn send failed")
                await MainActor.run {
                    // Surface the failure: drop back to .ready so the
                    // composer re-enables, append a synthesised assistant
                    // block so the user sees something went wrong.
                    self.state = .ready
                    self.transcript.append(.assistantBlock(
                        .text("⚠ send failed: \(error.localizedDescription)")
                    ))
                }
            }
        }
    }

    func setProviderHandoffContext(_ context: String) {
        pendingProviderHandoffContext = context
    }

    /// Replace only the provider-neutral visible timeline during a runtime
    /// switch. The destination Claude process still resumes its own native
    /// session (when one exists) and receives a bounded handoff checkpoint on
    /// the next turn; this keeps the UI continuous without pretending Codex's
    /// native thread id is portable to Claude.
    func adoptProviderTimeline(_ items: [TranscriptItem], from provider: V2AgentProvider) {
        finalizeStreamingText()
        transcript = items
        transcript.append(.systemNote(kind: .info, text: "Continuing with Claude from \(provider.displayName)."))
    }

    /// Re-send the most recent user turn. Used by the Retry button so a
    /// failed / unsatisfying turn can be re-run without retyping. No-op if
    /// there's no prior user message or a turn is already in flight.
    func retryLastTurn() {
        guard state == .ready || state == .idle else { return }
        let lastUser: String? = {
            for item in transcript.reversed() {
                if case .userText(let s) = item { return s }
            }
            return nil
        }()
        guard let text = lastUser else { return }
        send(text: text)
    }

    /// Pre-authorise Read of a specific absolute path for this session.
    /// Used by the composer when the user attaches a file via paperclip /
    /// paste / drop — they've already implicitly granted permission to read
    /// it, so we silently allow without surfacing a prompt.
    func preApproveRead(path: String) {
        // Unbounded growth guard: a very long session attaching many
        // distinct files would otherwise grow this set for the session's
        // entire lifetime. A full clear on overflow is fine — worst case a
        // stale attachment re-prompts for permission once.
        if preApprovedReadPaths.count > 200 { preApprovedReadPaths.removeAll() }
        preApprovedReadPaths.insert(path)
    }

    /// Resolve a pending permission request.
    func respondToPermission(allow: Bool, message: String? = nil) {
        guard let pending = pendingPermission, let inputWriter else { return }
        // Clear the card immediately so it doesn't get stuck on screen if
        // the write throws — the user has already made their call. If the
        // write does throw, we surface it in the transcript. If another
        // request queued up behind this one (claude fired parallel tool
        // calls in one turn), promote it straight to the card instead of
        // dropping back to .working — otherwise it sits invisibly in the
        // queue and the session looks idle while still awaiting an answer.
        if permissionQueue.isEmpty {
            pendingPermission = nil
            state = .working
        } else {
            pendingPermission = permissionQueue.removeFirst()
            state = .awaitingPermission
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await inputWriter.respondToPermission(
                    requestId: pending.requestId,
                    behavior: allow ? .allow : .deny,
                    message: message
                )
            } catch {
                log.error("Stream session permission reply failed")
                await MainActor.run {
                    // Roll back the optimistic .working flip — otherwise a
                    // write failure here leaves the composer stuck on
                    // "Working…" forever. Mirrors send()'s failure path.
                    self.state = .ready
                    self.transcript.append(.assistantBlock(
                        .text("⚠ permission reply failed: \(error.localizedDescription)")
                    ))
                }
            }
        }
    }

    /// Send a `control_request` to interrupt the current turn. Also evicts
    /// any Bash tool_use entries queued for it — an interrupted turn's
    /// pending calls will never get a matching tool_result, so they'd
    /// otherwise leak in pendingBashCommands for the rest of the session.
    func interrupt() {
        pendingBashCommands.removeAll()
        Task { try? await inputWriter?.interrupt() }
    }

    /// Set the permission mode directly (used by the runningPill menu).
    /// Permission modes claude actually accepts on the CLI + set_permission_mode
    /// control request. Trimmed to the real ones — the old list included
    /// "dontAsk" / "auto" which aren't valid --permission-mode values and
    /// would make the spawn reject the flag.
    static let permissionModes = ["default", "acceptEdits", "plan", "bypassPermissions"]
    static let defaultPermissionKey = "v2.defaultPermissionMode"

    func setPermissionMode(_ mode: String) {
        permissionMode = mode
        // Persist so the choice STICKS for the next spawn / new tab / resume.
        UserDefaults.standard.set(mode, forKey: Self.defaultPermissionKey)
        // Apply live to the running session too, so it takes effect
        // mid-conversation without a restart.
        Task { try? await inputWriter?.setPermissionMode(mode) }
    }

    /// Cycle through Claude's permission modes (Shift+Tab in the composer).
    func cyclePermissionMode() {
        // Shift+Tab only cycles the runtime-switchable modes — bypass is
        // launch-only and needs a session restart (handled via the header
        // menu → V2AppState.changePermissionMode), so we don't land on it
        // from a quick keystroke.
        let modes = ["plan", "default", "acceptEdits"]
        let current = modes.firstIndex(of: permissionMode) ?? -1
        let next = modes[(current + 1) % modes.count]
        setPermissionMode(next)
    }

    // MARK: - Client slash-command support

    /// Append an inline informational note to the transcript. Used by the
    /// composer's client-handled slash commands (/cost, /help, /model,
    /// /permissions) to surface their result in-line without sending a turn
    /// to the agent.
    func appendSystemNote(_ text: String) {
        transcript.append(.systemNote(kind: .info, text: text))
    }

    /// Wipe the on-screen conversation and per-turn metrics. Does NOT touch
    /// the underlying claude process — V2AppState.clearConversation() pairs
    /// this with a fresh spawn so the agent's context resets too (the
    /// faithful `/clear`).
    func resetTranscript() {
        transcript.removeAll()
        preloadOmittedTurns = 0
        latestResult = nil
        tokensUsed = 0
        contextTokens = 0
        pendingPermission = nil
        permissionQueue.removeAll()
        // Drop any open streaming block — its index now points into a cleared
        // transcript.
        flushPending = false
        streamingIndex = nil
        streamBuffer = ""
        thinkingBuffer = ""
        toolOutcomes.removeAll()
        toolStartTimes.removeAll()
        backgroundTasks.removeAll()
        subagentRuns.removeAll()
        pendingBashCommands.removeAll()
        monitorTasks.removeAll()
        pendingMonitorCommands.removeAll()
    }

    /// Where this session's on-disk artifacts live —
    /// ~/.claude/projects/<encoded-cwd>/<session-id>/ — including the
    /// subagents/ directory the delegation peek (#39) tails. Derived from
    /// the transcript path so it inherits jsonlURL's guess-then-scan
    /// robustness against cwd-encoding drift. Read per transcript body
    /// eval (30fps while streaming), so the resolution — which stats the
    /// filesystem — is cached once it's confirmed real; before the
    /// transcript file exists (brand-new session) the guess is returned
    /// uncached so a later scan can still correct it.
    private var cachedSessionDir: (sessionId: String, url: URL)?
    var sessionDir: URL? {
        guard let sessionId, let cwd else { return nil }
        if let cached = cachedSessionDir, cached.sessionId == sessionId { return cached.url }
        let jsonl = SessionHistoryLoader.jsonlURL(sessionId: sessionId, projectCwd: cwd)
        let dir = jsonl.deletingPathExtension()
        if FileManager.default.fileExists(atPath: jsonl.path) {
            cachedSessionDir = (sessionId, dir)
        }
        return dir
    }

    /// Any task still .running when the session ends has lost its only
    /// channel for a completion signal — mark it .orphaned rather than
    /// leaving a "running" row that can never resolve (the exact
    /// indistinguishable-from-hung failure mode #70's peek exists to catch,
    /// except this is the session itself going away, not the task hanging).
    private func orphanRunningBackgroundTasks() {
        for i in backgroundTasks.indices where backgroundTasks[i].state == .running {
            backgroundTasks[i].state = .orphaned
            backgroundTasks[i].finishedAt = Date()
        }
        for i in subagentRuns.indices where subagentRuns[i].state == .running {
            subagentRuns[i].state = .orphaned
            subagentRuns[i].finishedAt = Date()
        }
        for i in monitorTasks.indices where monitorTasks[i].state == .watching {
            monitorTasks[i].state = .orphaned
            monitorTasks[i].finishedAt = Date()
        }
    }

    /// Close stdin (clean EOF) and terminate the child.
    /// Reclaim the idle subprocess's memory (~0.4–0.6GB per tab) while keeping
    /// the tab fully intact — transcript on screen, composer live. The next
    /// send() respawns via --resume and delivers the message transparently.
    /// Quiet teardown by design: no .closing/.terminated transition, so no
    /// sounds, no tab-status churn, no "session ended" chrome.
    func hibernate() {
        // An observer has no process to reclaim, and hibernating one would
        // hand it a wake-via-resume path — the exact takeover the observer
        // gates exist to prevent. (Replayed init events can move an
        // observer's state to .ready, so the state guard alone isn't enough.)
        guard !isObserving else { return }
        guard state == .ready, sessionId != nil else { return }
        log.info("Stream session hibernating")
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        let writer = inputWriter
        let proc = process
        inputWriter = nil
        process = nil
        Task {
            try? await writer?.close()
            if let proc { Self.terminateWithEscalation(proc) }
        }
        // Hibernation kills the claude process — any background task it
        // spawned loses its only notification channel exactly like a real
        // termination does, even though the session itself is "just
        // resting." Waking the tab later starts a NEW claude process that
        // never hears about the old task either way.
        orphanRunningBackgroundTasks()
        state = .hibernated
    }

    /// Respawn after hibernation, buffering `text` until the new stdin writer
    /// exists (flushed right after spawn in start()).
    private func wake(thenSend text: String) {
        guard let cwd = wakeCwd, let claude = wakeClaudeURL else {
            state = .terminated(reason: "can't wake: no spawn recipe")
            return
        }
        pendingWakeText = text
        start(cwd: cwd, claudeURL: claude, resumeId: sessionId,
              model: wakeModel, permissionMode: wakePermissionMode, effort: wakeEffort)
    }

    func stop() {
        // Observer teardown: cancel the file poll. The observed session's
        // own process (owned elsewhere) is untouched — its tasks are NOT
        // orphaned here, their owner is still alive.
        observerTask?.cancel()
        observerTask = nil
        if isObserving {
            state = .terminated(reason: "observer_closed")
            return
        }
        finalizeStreamingText()   // commit any partial reply before teardown
        state = .closing
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        Task {
            try? await inputWriter?.close()
            if let process { Self.terminateWithEscalation(process) }
            orphanRunningBackgroundTasks()
            state = .terminated(reason: "user_stop")
        }
    }

    /// Send SIGTERM, then escalate to SIGKILL if the child hasn't exited
    /// within `graceSeconds` — an ignoring/hung child would otherwise keep
    /// running with no app-visible handle. Runs the check off the calling
    /// queue so callers never block on it.
    private static func terminateWithEscalation(_ proc: Process, graceSeconds: TimeInterval = 2) {
        proc.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + graceSeconds) {
            if proc.isRunning {
                log.warning("Stream child still running after SIGTERM; sending SIGKILL")
                kill(proc.processIdentifier, SIGKILL)
            }
        }
    }

    /// Synchronous, immediate SIGTERM — for the app quit path only
    /// (TerminalsController.shutdownAll, bug-hunt H1). `stop()`'s actual
    /// process.terminate() happens inside an async Task after awaiting the
    /// input writer's close; applicationShouldTerminate returns .terminateNow
    /// without waiting, so that Task may never get a scheduler turn before
    /// the app process itself exits — which is exactly how a chat tab open
    /// at quit time orphaned its `claude` child (macOS re-parents an
    /// un-signaled process to launchd instead of killing it).
    func terminateNow() {
        process?.terminate()
    }

    // MARK: - Event dispatch

    /// Internal so XCTest can replay captured NDJSON through the dispatch
    /// without actually spawning a child process.
    func handle(event: StreamEvent) {
        // Signpost interval per event so Instruments shows which event types
        // cost time (watch handle.streamEvent during a long reply). StaticString
        // names → no allocation when Instruments isn't attached.
        let sp = V2Signpost.signposter
        let spName: StaticString
        switch event {
        case .system:          spName = "handle.system"
        case .assistant:       spName = "handle.assistant"
        case .user:            spName = "handle.user"
        case .streamEvent:     spName = "handle.streamEvent"
        case .result:          spName = "handle.result"
        case .controlRequest:  spName = "handle.controlRequest"
        case .controlResponse: spName = "handle.controlResponse"
        case .rateLimitEvent:  spName = "handle.rateLimitEvent"
        case .unknown:         spName = "handle.unknown"
        }
        let spInterval = sp.beginInterval(spName, id: sp.makeSignpostID())
        defer { sp.endInterval(spName, spInterval) }

        // A SUBSTANTIVE event proves the resume produced real session data →
        // disarm the fresh-start fallback. Don't count control responses (our
        // own `initialize` handshake reply lands first and would otherwise
        // suppress the "couldn't open — running elsewhere" message).
        switch event {
        case .system, .assistant, .user, .streamEvent, .result:
            sawLiveEvent = true
            resumeFallbackArmed = false
        case .controlRequest, .controlResponse, .rateLimitEvent, .unknown:
            break
        }
        switch event {
        case .system(let sys):
            handleSystem(sys)
        case .assistant(let m):
            // Sidechain guard: a subagent's OWN tool calls/text arrive on
            // the PARENT session's stdout tagged with parent_tool_use_id —
            // confirmed via a real capture (a Read call inside a delegated
            // agent that hit a validation error). Nothing here ever checked
            // it, so subagent activity rendered as ordinary top-level tool
            // widgets, indistinguishable from the main assistant's own
            // actions — including that error, which then looked like an
            // unattributed main-session failure instead of a subagent
            // hiccup it may have already self-corrected a moment later.
            // The delegation card + peek sheet (#38/#39) are the real
            // surface for subagent activity; skip it here entirely. Doesn't
            // affect the Task spawn call itself or its own ack — those are
            // TOP-LEVEL events with no parent_tool_use_id (the sidechain
            // doesn't start until the subagent's first internal action).
            guard m.parentToolUseId == nil else { return }
            beginTurnIfObservedFromStream()
            // With --include-partial-messages + --verbose, claude emits BOTH
            // stream_event text_deltas (live streaming) AND a final assistant
            // snapshot containing the same text. Rendering both duplicates
            // every reply. Strategy: trust stream_events for text (already
            // accumulated incrementally); tool_use blocks DO fully arrive in
            // the snapshot, but thinking blocks do NOT — verified against
            // real captured wire text, the snapshot's `.thinking` block
            // always has an empty `thinking` field, same as text would if we
            // ignored text_delta. thinkingBuffer (declared above) is what
            // actually holds the content; see its doc comment.
            finalizeStreamingText()   // seal streamed text before any tool/thinking block
            for block in m.message.content {
                switch block {
                case .text:
                    // Already in transcript via appendStreamingText.
                    break
                case .toolUse(let id, let name, let input):
                    toolStartTimes[id] = Date()
                    recordTaskToolUse(id: id, name: name, input: input)
                    // Guard against a second .assistant snapshot for the same
                    // turn re-delivering an already-seen tool_use id (seen
                    // after resume/retry) — an unguarded append would leave
                    // subagentRuns with two entries sharing one toolUseId,
                    // which crashed the transcript's Dictionary(uniqueKeys
                    // WithValues:) the next time it rendered (e.g. on tab
                    // switch, whenever this session's view next appeared).
                    if V2SubagentParser.isAgentSpawn(toolName: name),
                       !subagentRuns.contains(where: { $0.toolUseId == id }) {
                        subagentRuns.append(V2SubagentRun(
                            toolUseId: id,
                            description: input.dig("description")?.asString ?? "agent",
                            agentType: input.dig("subagent_type")?.asString ?? "general-purpose",
                            isBackground: input.dig("run_in_background")?.asBool ?? false,
                            startedAt: Date()
                        ))
                    }
                    if name == "Bash" {
                        let command = input.dig("command")?.asString ?? ""
                        pendingBashCommands[id] = command
                        // Bypass mode skips the permission gate entirely, so
                        // handleControlRequest's "Run co-driven" offer (#57)
                        // never fires — this is the only place left to catch
                        // a flagged command before it silently hangs.
                        if permissionMode == "bypassPermissions",
                           terminalBridge != nil,
                           InteractiveCommandDetector.looksInteractive(command) {
                            transcript.append(.systemNote(
                                kind: .info,
                                text: "This looked interactive — ask me to run it co-driven if it hangs: \(command)"
                            ))
                        }
                    }
                    if name == "Monitor" {
                        pendingMonitorCommands[id] = (
                            input.dig("description")?.asString ?? "watch",
                            input.dig("command")?.asString
                        )
                    }
                    transcript.append(.assistantBlock(block))
                case .thinking(let text, let signature):
                    // The snapshot's own `text` is always empty (see
                    // thinkingBuffer's doc comment) — substitute what
                    // actually accumulated from thinking_delta events.
                    // Falls back to the snapshot's text on the off chance
                    // that assumption is ever wrong for some future API
                    // shape, rather than silently preferring an empty buffer.
                    let resolved = thinkingBuffer.isEmpty ? text : thinkingBuffer
                    thinkingBuffer = ""
                    transcript.append(.assistantBlock(.thinking(text: resolved, signature: signature)))
                case .fallback(let from, let to):
                    // The API silently answered with a DIFFERENT model than
                    // the session's (rate-limit/availability fallback) —
                    // surface it; a swapped model must never be invisible.
                    transcript.append(Self.fallbackNote(from: from, to: to))
                case .toolResult, .image, .unknown:
                    transcript.append(.assistantBlock(block))
                }
            }
        case .user(let m):
            // Same sidechain guard as .assistant above — a subagent's own
            // tool_result events are tagged with parent_tool_use_id too.
            guard m.parentToolUseId == nil else { return }
            // Tool results echo back in user events — render as a result row.
            finalizeStreamingText()
            for block in m.message.content {
                if case .toolResult(let toolUseId, let content, let isError) = block {
                    // Record the outcome so the originating tool-call row can
                    // show its ✓ / ✗ valence (agent vocabulary).
                    toolOutcomes[toolUseId] = (isError ?? false)
                    recordTaskResult(toolUseId: toolUseId, content: content)
                    // A subagent spawn's tool_result is either the background
                    // launch ack (run keeps going, grab the agentId) or — for
                    // a synchronous agent — the final report itself. Either
                    // way the delegation card (#38) is the surface for it;
                    // the raw result row would just duplicate the card (and
                    // the ack literally says "internal ID - do not mention"),
                    // so it's captured on the run instead of appended.
                    if let runIdx = subagentRuns.firstIndex(where: { $0.toolUseId == toolUseId }) {
                        let text = content.asString ?? ""
                        if subagentRuns[runIdx].isBackground,
                           let agentId = V2SubagentParser.agentId(fromSpawnAck: text) {
                            subagentRuns[runIdx].agentId = agentId
                        } else {
                            subagentRuns[runIdx].state = (isError ?? false) ? .failed : .completed
                            subagentRuns[runIdx].finishedAt = Date()
                            subagentRuns[runIdx].resultText = text.isEmpty ? nil : text
                        }
                        continue
                    }
                    transcript.append(.assistantBlock(block))
                    // A backgrounded Bash call's result is the spawn
                    // acknowledgment, not the command's real output — catch
                    // it here and start tracking the task.
                    if let spawn = V2BackgroundTaskParser.parseSpawn(from: content.asString) {
                        let command = pendingBashCommands.removeValue(forKey: toolUseId) ?? ""
                        backgroundTasks.append(V2BackgroundTask(
                            id: spawn.id, command: command, outputPath: spawn.outputPath, startedAt: Date()
                        ))
                    }
                } else if case .text(let text) = block {
                    // Task-notifications arrive as injected context ahead of
                    // the model's next turn — see V2BackgroundTask.swift for
                    // why this is the primary hypothesis for the delivery
                    // channel. A miss here just means the task never
                    // resolves in the UI until the session ends (→
                    // .orphaned) — never a crash or a rendered artifact,
                    // since this branch was previously unhandled entirely.
                    // (Shared with history preload — see applyNotificationText.)
                    //
                    // Gate beginTurnIfObservedFromStream on this NOT being a
                    // notification — a pure bg-task/subagent completion is
                    // bookkeeping injected ahead of the model's OWN next
                    // turn, not a turn itself, and never gets a matching
                    // `result` event back. Calling it unconditionally here
                    // (2.11.2) meant a notification landing while idle
                    // flipped .ready -> .working and left it stuck there
                    // forever — this session alone carries hundreds of
                    // these, so it broke almost immediately: tabs stuck
                    // permanently "working" (pulsing ring, indeterminate
                    // line, elapsed timer) is exactly what read back as
                    // "scroll jumping on every chat at once" and the
                    // eventual hang (user-reported, 2026-07-22). Anything
                    // that ISN'T a recognized notification — e.g. a
                    // ScheduleWakeup's injected resumption prompt — is real
                    // new content and must still flip.
                    let isNotification = V2BackgroundTaskParser.parseCompletion(from: text) != nil
                        || V2SubagentParser.parseCompletion(from: text) != nil
                    if !isNotification { beginTurnIfObservedFromStream() }
                    applyNotificationText(text)
                }
            }
        case .streamEvent(let s):
            handleStreamEvent(s)
        case .result(let r):
            finalizeStreamingText()   // commit the reply's tail before the turn closes
            V2Signpost.signposter.emitEvent("turn-end")
            latestResult = r
            // An error result (e.g. resuming a session whose transcript was
            // deleted → "No conversation found") — capture a friendly reason
            // so the UI can explain it and offer a fresh start.
            if r.isError == true {
                let raw = r.errors?.first ?? r.result
                    ?? ("Claude returned an error" + (r.subtype.map { " (\($0))" } ?? "") + ".")
                if raw.contains("No conversation found") {
                    // Unresumable session — handled by the empty-state + fresh CTA.
                    endError = "This conversation's history is no longer available — it may have been cleared."
                } else {
                    // Any other error (e.g. "Claude Fable 5 is currently
                    // unavailable") — show it inline so it's never silent.
                    transcript.append(.systemNote(kind: .error, text: raw))
                }
            }
            tokensUsed = r.usage?.total ?? tokensUsed
            // Context occupancy = the prompt side of the last turn (system +
            // tools + full history, incl. cached). This is what fills the
            // window — output isn't counted until it becomes history next
            // turn. Held across turns (not zeroed on send) so the meter
            // doesn't flicker to 0 mid-turn.
            if let u = r.usage {
                let prompt = (u.inputTokens ?? 0) + (u.cacheReadInputTokens ?? 0) + (u.cacheCreationInputTokens ?? 0)
                if prompt > 0 { contextTokens = prompt }
            }
            isRetrying = false
            lastRetry = nil
            // Result = current turn done. Session stays alive for the next
            // message → .ready (not .idle, which would re-trigger the Start
            // CTA in the UI).
            if state == .working || state == .awaitingPermission {
                // A result arriving while a permission card is up means the
                // turn finished — clear the stale card so it can't get stuck.
                if state == .awaitingPermission {
                    pendingPermission = nil
                    permissionQueue.removeAll()
                }
                state = .ready
            }
            // Usage only moves when turns run — turn end is the natural
            // refresh point for the plan meters (no timers needed).
            refreshUsage()
        case .controlRequest(let req):
            handleControlRequest(req)
        case .controlResponse(let cr):
            // Replies to our outgoing control requests. The only one we
            // currently act on is the reply to our `initialize` handshake —
            // its arrival proves claude is alive and accepting input even
            // before system/init lands, so we can drop out of .initializing
            // immediately and unblock the composer. The full session details
            // (model, cwd, tools, mcp_servers) will follow shortly in
            // system/init.
            if cr.response.requestId.hasPrefix("init_"),
               cr.response.subtype == "success" {
                // Capture the binary's model catalog (value = what set_model
                // accepts, resolvedModel = the concrete id it maps to).
                if let arr = cr.response.response?.dig("models")?.asArray {
                    availableModels = arr.compactMap { m in
                        guard let value = m.dig("value")?.asString,
                              let display = m.dig("displayName")?.asString else { return nil }
                        return V2AvailableModel(
                            value: value,
                            resolvedModel: m.dig("resolvedModel")?.asString ?? value,
                            displayName: display,
                            description: m.dig("description")?.asString ?? ""
                        )
                    }
                }
                if state == .spawning || state == .initializing {
                    state = .ready
                }
                // First usage snapshot — get_usage is only serviced once
                // the session is initialized, which this reply proves.
                refreshUsage()
            }
            // Reply to refreshMCPStatus() — swap in the LIVE per-server
            // statuses (init's snapshot goes stale the moment a "pending"
            // server finishes connecting).
            if cr.response.requestId.hasPrefix("mcp_status"),
               cr.response.subtype == "success",
               let arr = cr.response.response?.dig("mcpServers")?.asArray {
                mcpServers = arr.compactMap { m in
                    guard let name = m.dig("name")?.asString else { return nil }
                    return MCPServerInfo(name: name, status: m.dig("status")?.asString)
                }
            }
            // Reply to refreshUsage() — the typed plan-usage meters. A nil
            // parse (API-key auth reports rate_limits_available: false)
            // leaves the previous value; the meter simply doesn't render
            // when there's never been one.
            if cr.response.requestId.hasPrefix("usage"),
               cr.response.subtype == "success",
               let parsed = V2UsageLimits.fromClaude(cr.response.response) {
                // Design 1h: a crossing prints once into the transcript,
                // not a toast — computed against the PREVIOUS snapshot
                // before it's overwritten below.
                for window in V2UsageLimits.crossings(from: usageLimits, to: parsed) {
                    transcript.append(.systemNote(kind: .info, text: V2UsageLimits.crossingMessage(for: window)))
                }
                usageLimits = parsed
            }
        case .rateLimitEvent(let evt):
            rateLimitInfo = evt.rateLimitInfo
            // The push has status/reset but no percent — treat it as the
            // signal to fetch the full typed snapshot.
            refreshUsage()
        case .unknown(let t):
            log.notice("Stream session received an unknown event type")
        }
    }

    /// Maps a task_updated/task_notification status string to a terminal
    /// V2MonitorTask.State, or nil for anything that isn't actually terminal
    /// (e.g. an intermediate "watching" patch on a persistent monitor) —
    /// callers leave state untouched on nil, never guessing at a transition.
    private static func monitorTerminalState(for status: String) -> V2MonitorTask.State? {
        switch status {
        case "completed": return .completed
        case "failed", "error", "timeout", "cancelled": return .failed
        default: return nil
        }
    }

    private func handleSystem(_ sys: SystemEvent) {
        switch sys.subtype {
        case "init":
            sessionId = sys.sessionId ?? sessionId
            if let m = sys.model { model = m }
            if let p = sys.permissionMode { permissionMode = p }
            if let servers = sys.mcpServers { mcpServers = servers }
            if let t = sys.tools { tools = t }
            if let c = sys.cwd { cwd = c }
            if let sc = sys.slashCommands { reportedSlashCommands = sc }
            // Semantic correctness: after init, claude is idle waiting for
            // the first user message — that's .ready. Only promote from the
            // startup states. Crucially do NOT touch .working: the composer
            // lets you type during .initializing, so you can send before
            // system/init lands — and if init then reset .working → .ready it
            // would kill the "Working…" cue of an in-flight turn, which read
            // as "I sent but nothing happened" (intermittent dead air).
            if state == .spawning || state == .initializing {
                state = .ready
            }
        case "api_retry":
            isRetrying = true
            lastRetry = RetryInfo(
                attempt: sys.attempt ?? 1,
                maxRetries: sys.maxRetries ?? 5,
                retryDelayMs: sys.retryDelayMs.map { Int($0) },
                // Prefer the short reason ("rate_limit") over the bare HTTP
                // code — matches api_error's human-readable convention below.
                errorStatus: sys.errorDetail?.text ?? sys.errorStatus.map(String.init)
            )
        case "api_error":
            // Same shape as api_retry under a different subtype + key names.
            // claude auto-retries connection errors; we used to drop these
            // entirely, so a flaky connection looked like a dead session.
            // Route through the same retry indicator so the user sees
            // "retrying (1/10) — Connection error" instead of nothing.
            isRetrying = true
            lastRetry = RetryInfo(
                attempt: sys.retryAttempt ?? 1,
                maxRetries: sys.maxRetries ?? 10,
                retryDelayMs: sys.retryInMs.map { Int($0) },
                errorStatus: sys.errorDetail?.text ?? "API error"
            )
        case "compact_boundary":
            transcript.append(.compactBoundary)
        case "stop_hook_summary":
            // Output from the user's Stop hooks — previously invisible.
            if let body = sys.noteText, !body.isEmpty {
                transcript.append(.systemNote(kind: .hook, text: body))
            }
        case "task_started":
            // Only tracked when the tool_use_id matches a real Monitor call
            // (task_type alone doesn't distinguish Monitor from a plain
            // background Bash task — both report "local_bash", confirmed live).
            if let tid = sys.taskId, let toolId = sys.toolUseId,
               let pending = pendingMonitorCommands.removeValue(forKey: toolId) {
                monitorTasks.append(V2MonitorTask(
                    id: tid, toolUseId: toolId,
                    description: sys.taskDescription ?? pending.description,
                    command: pending.command,
                    startedAt: Date()
                ))
            }
        case "task_updated":
            if let tid = sys.taskId, let idx = monitorTasks.firstIndex(where: { $0.id == tid }),
               let status = sys.patch?["status"]?.asString,
               let terminal = Self.monitorTerminalState(for: status) {
                monitorTasks[idx].state = terminal
                monitorTasks[idx].finishedAt = Date()
            }
        case "task_notification":
            if let tid = sys.taskId, let idx = monitorTasks.firstIndex(where: { $0.id == tid }) {
                if let status = sys.taskStatus, let terminal = Self.monitorTerminalState(for: status) {
                    monitorTasks[idx].state = terminal
                }
                monitorTasks[idx].finishedAt = monitorTasks[idx].finishedAt ?? Date()
                monitorTasks[idx].lastEvent = sys.summary
                monitorTasks[idx].outputFile = sys.outputFile
            }
        case "informational", "bridge_status", "local_command",
             "scheduled_task_fire", "away_summary":
            if let body = sys.noteText, !body.isEmpty {
                transcript.append(.systemNote(kind: .info, text: "\(sys.subtype): \(body)"))
            }
        case "turn_duration":
            // High-frequency + already implied by the result footer; skip to
            // avoid spamming the transcript.
            break
        default:
            // Anything else claude introduces later: surface it rather than
            // silently swallow, so "see all states" actually holds.
            if let body = sys.noteText, !body.isEmpty {
                transcript.append(.systemNote(kind: .info, text: "\(sys.subtype): \(body)"))
            }
        }
    }

    private func handleStreamEvent(_ s: StreamEventInner) {
        // Sidechain guard (same as .assistant/.user in handle(event:)): no
        // real capture has shown a subagent streaming a text_delta into the
        // parent's stdout, but the field IS present on this event type too
        // — belt-and-suspenders against a subagent's words landing inside
        // the main assistant's own in-progress reply.
        guard s.parentToolUseId == nil else { return }
        // Token-by-token streaming — append onto the last assistant text block
        // if there is one; otherwise start a new text block.
        guard let delta = s.event.delta else { return }
        lastStreamActivityAt = Date()
        if delta.type == "text_delta", let text = delta.text {
            appendStreamingText(text)
        } else if delta.type == "thinking_delta", let thinking = delta.thinking {
            // O(1) amortized append, mirroring streamBuffer above — never
            // `existing + delta` (PERFORMANCE.md rule 1). No live row to
            // flush into yet; the block doesn't exist in `transcript` until
            // the assistant snapshot arrives, so this just accumulates.
            thinkingBuffer += thinking
        }
    }

    private func appendStreamingText(_ text: String) {
        // Tokens are flowing again — clear any retry banner that was showing
        // from an api_retry / api_error so it doesn't linger over a live reply.
        if isRetrying {
            isRetrying = false
            lastRetry = nil
        }
        if let idx = streamingIndex, idx == transcript.count - 1,
           case .assistantBlock(.text) = transcript[idx] {
            // Continue the open block: O(1) buffer append, throttled commit.
            streamBuffer += text
            scheduleStreamFlush()
        } else {
            // Start a new streaming block. Commit any prior buffer to its block
            // first so a tail delta isn't lost when we repoint.
            commitStreamBuffer()
            streamBuffer = text
            transcript.append(.assistantBlock(.text(text)))
            streamingIndex = transcript.count - 1
            streamTick &+= 1
        }
    }

    private func scheduleStreamFlush() {
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + streamFlushInterval) { [weak self] in
            guard let self, self.flushPending else { return }
            self.flushPending = false
            self.commitStreamBuffer()
        }
    }

    /// Write the accumulated buffer into the open block. `.text(streamBuffer)`
    /// shares the String storage (COW), so this is O(1), not an O(n) copy.
    private func commitStreamBuffer() {
        guard let idx = streamingIndex, idx < transcript.count,
              case .assistantBlock(.text) = transcript[idx] else { return }
        transcript[idx] = .assistantBlock(.text(streamBuffer))
        streamTick &+= 1
        V2Signpost.signposter.emitEvent("flush")
    }

    /// Seal the open streaming block: commit the buffer now and stop appending
    /// to it. Called before a non-text block is appended or a turn ends, so
    /// order is preserved and no tail text is dropped.
    private func finalizeStreamingText() {
        flushPending = false
        commitStreamBuffer()
        streamingIndex = nil
        streamBuffer = ""
    }

    private func handleControlRequest(_ req: ControlRequest) {
        guard req.request.subtype == "can_use_tool" else { return }

        // Auto-allow Reads of files the user explicitly attached this turn.
        // Skipping the prompt for paths the user JUST picked makes the
        // composer's @-attachments feel native — they shouldn't have to
        // approve their own pick.
        if req.request.toolName == "Read",
           let path = req.request.input?.dig("file_path")?.asString,
           preApprovedReadPaths.contains(path) {
            log.info("Stream session auto-allowed a pre-approved read")
            // Capture the writer on the main actor before hopping off — the
            // previous `await self.inputWriter` inside a non-isolated Task
            // was an isolation violation.
            let writer = inputWriter
            let requestId = req.requestId
            Task {
                try? await writer?.respondToPermission(
                    requestId: requestId,
                    behavior: .allow
                )
            }
            return
        }

        let preview = makePermissionPreview(toolName: req.request.toolName, input: req.request.input)
        // Interactive-looking Bash gets the "Run co-driven" offer on the card
        // (#57) — only meaningful when this session has the terminal bridge.
        var interactive: String?
        if req.request.toolName == "Bash",
           terminalBridge != nil,
           let cmd = req.request.input?.dig("command")?.asString,
           InteractiveCommandDetector.looksInteractive(cmd) {
            interactive = cmd
        }
        let request = PendingPermission(
            requestId: req.requestId,
            toolName: req.request.toolName ?? "unknown",
            previewText: preview,
            interactiveCommand: interactive
        )
        if pendingPermission == nil {
            pendingPermission = request
            state = .awaitingPermission
        } else {
            permissionQueue.append(request)
        }
    }

    private func makePermissionPreview(toolName: String?, input: JSONValue?) -> String {
        switch toolName {
        case "Bash":
            return input?.dig("command")?.asString ?? "(no command)"
        case "Edit", "Write":
            return input?.dig("file_path")?.asString ?? "(no path)"
        case "Read":
            return input?.dig("file_path")?.asString ?? "(no path)"
        default:
            return input?.preview ?? "(no input)"
        }
    }
}

// MARK: - Public model types

struct PendingPermission: Identifiable, Equatable {
    let id = UUID()
    let requestId: String
    let toolName: String
    let previewText: String
    /// Set when this is a Bash call that looks interactive — the permission
    /// card offers "Run co-driven" and steers via deny-with-message (#57).
    var interactiveCommand: String? = nil
}

/// A single row in the live transcript. The UI maps each to a SwiftUI view.
enum TranscriptItem: Identifiable {
    case userText(String)
    case assistantBlock(ContentBlock)
    case compactBoundary
    /// A claude `system` event surfaced as a subtle inline note — stop-hook
    /// output, informational notices, errors, etc. that we used to drop.
    /// `kind` drives the icon/color; `text` is the body.
    case systemNote(kind: SystemNoteKind, text: String)

    enum SystemNoteKind: Equatable {
        case info       // informational, bridge_status, local_command, …
        case hook       // stop_hook_summary
        case error      // non-retryable errors
    }

    var id: String {
        switch self {
        case .userText(let s):              return "u-\(s.hashValue)"
        case .assistantBlock(let b):        return "a-\(b.id)"
        case .compactBoundary:              return "cb-\(UUID().uuidString)"
        case .systemNote(let kind, let t):  return "sys-\(kind)-\(t.hashValue)"
        }
    }
}

// MARK: - Available model (from the initialize reply)

/// One entry of the binary's model catalog. `value` is the alias `set_model`
/// accepts ("sonnet", "opus[1m]"); `resolvedModel` is the concrete id it maps
/// to ("claude-sonnet-5").
struct V2AvailableModel: Identifiable, Equatable, Sendable, Codable {
    let value: String
    let resolvedModel: String
    let displayName: String
    let description: String
    var id: String { value }
}
