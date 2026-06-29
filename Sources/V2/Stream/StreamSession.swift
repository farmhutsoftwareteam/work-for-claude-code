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

@MainActor
final class StreamSession: ObservableObject {

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
        case closing
        case terminated(reason: String)
    }

    @Published private(set) var state: LifecycleState = .idle
    @Published private(set) var sessionId: String?
    @Published private(set) var model: String = "claude-sonnet"
    @Published private(set) var permissionMode: String = "default"

    /// MCP servers reported by the binary on `system/init`. Populated once the
    /// session is initialized; empty before then. Drives the right-dock MCP
    /// panel (#34).
    @Published private(set) var mcpServers: [MCPServerInfo] = []

    /// Tools available on this session (from `system/init.tools`). Drives
    /// the dock's tool inventory and the composer's slash-command autocomplete.
    @Published private(set) var tools: [String] = []

    /// Project cwd reported by `system/init`. Useful for UI breadcrumbs.
    @Published private(set) var cwd: String?

    /// Ordered, append-only transcript. Each item is a separate UI row.
    @Published private(set) var transcript: [TranscriptItem] = []

    /// Number of older user turns that exist on disk but weren't rendered
    /// into the transcript (we cap the preload at the latest N events).
    /// Drives the "↑ N earlier messages" affordance at the top of the
    /// transcript view; zero when nothing was trimmed.
    @Published private(set) var preloadOmittedTurns: Int = 0

    /// Latest queued permission request — the inline permission card binds here.
    @Published private(set) var pendingPermission: PendingPermission?

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

    // MARK: - Internals

    private var process: Process?
    private var inputWriter: StreamInputWriter?
    private var eventConsumer: Task<Void, Never>?
    private var stderrConsumer: Task<Void, Never>?
    /// Strong references to the pipe FileHandles so the OS keeps firing
    /// our readabilityHandlers. Without these, ARC has been observed to
    /// release the handles mid-session and the handler stops firing.
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

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
                for block in m.message.content {
                    switch block {
                    case .text(let s):
                        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            transcript.append(.userText(trimmed))
                        }
                    case .toolResult:
                        transcript.append(.assistantBlock(block))
                    default:
                        break
                    }
                }
            case .assistant(let m):
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
                    case .toolUse, .toolResult, .thinking, .unknown:
                        transcript.append(.assistantBlock(block))
                    }
                }
            default:
                break
            }
        }
    }

    /// Launch `claude -p` in the project's cwd. No-op if not idle. Pass a
    /// `resumeId` (an existing Claude session UUID under `~/.claude/projects`)
    /// to replay that session's history before the new turn — claude will
    /// stream its prior messages out of stdout in addition to handling new
    /// user turns.
    func start(cwd: URL, claudeURL: URL, resumeId: String? = nil, model: String? = nil, permissionMode: String? = nil) {
        guard state == .idle else { return }
        state = .spawning

        // Resolve the permission mode for this spawn: explicit arg →
        // persisted default → "acceptEdits". Persisting it here (and in
        // setPermissionMode / cyclePermissionMode) is what makes the choice
        // STICK across new tabs, restarts, and resumes — previously every
        // spawn reset to claude's "default" because we never passed
        // --permission-mode and never persisted the user's pick.
        let resolvedPermission = permissionMode
            ?? UserDefaults.standard.string(forKey: Self.defaultPermissionKey)
            ?? "acceptEdits"

        log.info("StreamSession.start cwd=\(cwd.path, privacy: .public) binary=\(claudeURL.path, privacy: .public) resume=\(resumeId ?? "-", privacy: .public) model=\(model ?? "-", privacy: .public) perm=\(resolvedPermission, privacy: .public)")

        let process = Process()
        process.executableURL = claudeURL
        var args: [String] = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]
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

        // Tee stdout to /tmp so we can verify chunks are arriving even when
        // the parser path appears stuck. Truncated per session.
        let debugLog = "/tmp/atelier-v2-stream-debug.ndjson"
        let fm = FileManager.default
        try? Data().write(to: URL(fileURLWithPath: debugLog))
        let debugHandle = (try? FileHandle(forWritingTo: URL(fileURLWithPath: debugLog))) ?? FileHandle.nullDevice
        if !fm.isWritableFile(atPath: debugLog) {
            fm.createFile(atPath: debugLog, contents: nil)
        }

        do {
            try process.run()
        } catch {
            log.error("spawn failed: \(error.localizedDescription, privacy: .public)")
            state = .terminated(reason: "spawn failed: \(error.localizedDescription)")
            return
        }
        log.info("StreamSession spawned pid=\(process.processIdentifier)")

        self.process = process
        let writer = StreamInputWriter(fileHandle: stdinPipe.fileHandleForWriting)
        self.inputWriter = writer
        self.state = .initializing

        // CRITICAL: claude with --input-format stream-json sits idle until
        // it receives the SDK's `initialize` control_request handshake on
        // stdin. Without this, system/init is never emitted and the session
        // is stuck on .initializing forever. (#36)
        Task {
            do {
                try await writer.initialize()
                log.info("StreamSession sent initialize handshake")
            } catch {
                log.error("initialize handshake failed: \(error.localizedDescription, privacy: .public)")
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
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                // EOF — claude closed its stdout.
                handle.readabilityHandler = nil
                try? debugHandle.close()
                Task { @MainActor [weak self] in
                    self?.handleStreamEnd()
                }
                return
            }
            try? debugHandle.write(contentsOf: chunk)
            buffer.append(chunk)
            for lineData in buffer.drainLines() {
                guard !lineData.isEmpty else { continue }
                do {
                    let event = try decoder.decode(StreamEvent.self, from: lineData)
                    Task { @MainActor [weak self] in
                        self?.handle(event: event)
                    }
                } catch {
                    let preview = String(data: lineData.prefix(200), encoding: .utf8) ?? "<binary>"
                    log.warning("ndjson decode skipped: \(error.localizedDescription, privacy: .public) — \(preview, privacy: .public)")
                }
            }
        }

        // Drain stderr — log + tee to /tmp so we can diagnose silent
        // spawn failures. If claude is printing 'command not found: node'
        // or similar bootstrap errors, this is where they show up.
        let stderrDebug = "/tmp/atelier-v2-stream-debug.stderr.log"
        try? Data().write(to: URL(fileURLWithPath: stderrDebug))
        let stderrDebugHandle = (try? FileHandle(forWritingTo: URL(fileURLWithPath: stderrDebug))) ?? FileHandle.nullDevice
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                try? stderrDebugHandle.close()
                return
            }
            try? stderrDebugHandle.write(contentsOf: chunk)
            if let line = String(data: chunk, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !line.isEmpty {
                log.warning("claude stderr: \(line, privacy: .public)")
            }
        }

        // Keep these handles strongly held so the OS keeps firing
        // readabilityHandler. Without these references, ARC could release
        // the FileHandles and the handlers silently stop.
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrHandle
    }

    private func handleStreamEnd() {
        log.info("StreamSession ndjson stream ended")
        // Cover every non-terminal state, not just .working / .initializing.
        // If claude crashed in .ready or .awaitingPermission, the UI would
        // previously leave the composer enabled and the permission card up
        // while the process was actually dead.
        switch state {
        case .terminated, .closing, .idle:
            break
        case .spawning, .initializing, .ready, .working, .awaitingPermission:
            state = .terminated(reason: "stream closed")
        }
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
                log.error("setModel failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send a user turn. Triggers a new assistant cycle from the binary.
    func send(text: String) {
        guard let inputWriter else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
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
        state = .working
        Task { [weak self] in
            guard let self else { return }
            do {
                try await inputWriter.sendUserText(trimmed)
            } catch {
                log.error("user-turn send failed: \(error.localizedDescription, privacy: .public)")
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
        preApprovedReadPaths.insert(path)
    }

    /// Resolve a pending permission request.
    func respondToPermission(allow: Bool, message: String? = nil) {
        guard let pending = pendingPermission, let inputWriter else { return }
        // Clear the card immediately so it doesn't get stuck on screen if
        // the write throws — the user has already made their call. If the
        // write does throw, we surface it in the transcript.
        pendingPermission = nil
        state = .working
        Task { [weak self] in
            guard let self else { return }
            do {
                try await inputWriter.respondToPermission(
                    requestId: pending.requestId,
                    behavior: allow ? .allow : .deny,
                    message: message
                )
            } catch {
                log.error("permission reply failed: \(error.localizedDescription, privacy: .public)")
                await MainActor.run {
                    self.transcript.append(.assistantBlock(
                        .text("⚠ permission reply failed: \(error.localizedDescription)")
                    ))
                }
            }
        }
    }

    /// Send a `control_request` to interrupt the current turn.
    func interrupt() {
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
        let modes = Self.permissionModes
        let current = modes.firstIndex(of: permissionMode) ?? -1
        let next = modes[(current + 1) % modes.count]
        setPermissionMode(next)
    }

    /// Close stdin (clean EOF) and terminate the child.
    func stop() {
        state = .closing
        eventConsumer?.cancel()
        stderrConsumer?.cancel()
        stdoutHandle?.readabilityHandler = nil
        stderrHandle?.readabilityHandler = nil
        stdoutHandle = nil
        stderrHandle = nil
        Task {
            try? await inputWriter?.close()
            process?.terminate()
            state = .terminated(reason: "user_stop")
        }
    }

    // MARK: - Event dispatch

    /// Internal so XCTest can replay captured NDJSON through the dispatch
    /// without actually spawning a child process.
    func handle(event: StreamEvent) {
        switch event {
        case .system(let sys):
            handleSystem(sys)
        case .assistant(let m):
            // With --include-partial-messages + --verbose, claude emits BOTH
            // stream_event text_deltas (live streaming) AND a final assistant
            // snapshot containing the same text. Rendering both duplicates
            // every reply. Strategy: trust stream_events for text (already
            // accumulated incrementally), use the assistant event only for
            // tool_use / thinking blocks which don't fully arrive via deltas
            // in a render-ready shape.
            for block in m.message.content {
                switch block {
                case .text:
                    // Already in transcript via appendStreamingText.
                    break
                case .toolUse, .toolResult, .thinking, .unknown:
                    transcript.append(.assistantBlock(block))
                }
            }
        case .user(let m):
            // Tool results echo back in user events — render as a result row.
            for block in m.message.content {
                if case .toolResult = block {
                    transcript.append(.assistantBlock(block))
                }
            }
        case .streamEvent(let s):
            handleStreamEvent(s)
        case .result(let r):
            latestResult = r
            tokensUsed = r.usage?.total ?? tokensUsed
            isRetrying = false
            lastRetry = nil
            // Result = current turn done. Session stays alive for the next
            // message → .ready (not .idle, which would re-trigger the Start
            // CTA in the UI).
            if state == .working || state == .awaitingPermission {
                state = .ready
            }
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
               cr.response.subtype == "success",
               state == .spawning || state == .initializing {
                state = .ready
            }
        case .unknown(let t):
            log.notice("unknown event type: \(t, privacy: .public)")
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
            // Semantic correctness: after init, claude is idle waiting for
            // the first user message — that's .ready, not .working. Going
            // straight to .working makes the composer render a Stop button
            // when nothing's actually running. The transition to .working
            // happens in send() when the user sends their first text.
            if state == .spawning || state == .initializing || state == .working {
                state = .ready
            }
        case "api_retry":
            isRetrying = true
            lastRetry = RetryInfo(
                attempt: sys.attempt ?? 1,
                maxRetries: sys.maxRetries ?? 5,
                retryDelayMs: sys.retryDelayMs,
                errorStatus: sys.errorStatus
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
                errorStatus: sys.errorDetail?.message ?? sys.errorDetail?.formatted ?? "API error"
            )
        case "compact_boundary":
            transcript.append(.compactBoundary)
        case "stop_hook_summary":
            // Output from the user's Stop hooks — previously invisible.
            if let body = sys.noteText, !body.isEmpty {
                transcript.append(.systemNote(kind: .hook, text: body))
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
        // Token-by-token streaming — append onto the last assistant text block
        // if there is one; otherwise start a new text block.
        guard let delta = s.event.delta else { return }
        if delta.type == "text_delta", let text = delta.text {
            appendStreamingText(text)
        }
    }

    private func appendStreamingText(_ text: String) {
        // Tokens are flowing again — clear any retry banner that was showing
        // from an api_retry / api_error so it doesn't linger over a live reply.
        if isRetrying {
            isRetrying = false
            lastRetry = nil
        }
        if case .assistantBlock(.text(let existing)) = transcript.last {
            transcript[transcript.count - 1] = .assistantBlock(.text(existing + text))
        } else {
            transcript.append(.assistantBlock(.text(text)))
        }
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
            log.info("auto-allow Read of pre-approved path \(path, privacy: .public)")
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
        pendingPermission = PendingPermission(
            requestId: req.requestId,
            toolName: req.request.toolName ?? "unknown",
            previewText: preview
        )
        state = .awaitingPermission
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
