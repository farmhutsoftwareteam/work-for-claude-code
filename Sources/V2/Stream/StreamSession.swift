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
    func start(cwd: URL, claudeURL: URL, resumeId: String? = nil) {
        guard state == .idle else { return }
        state = .spawning
        log.info("StreamSession.start cwd=\(cwd.path, privacy: .public) binary=\(claudeURL.path, privacy: .public) resume=\(resumeId ?? "-", privacy: .public)")

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
        if state == .working || state == .initializing {
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
        Task {
            do { try await inputWriter.sendUserText(trimmed); state = .working }
            catch { log.error("user-turn send failed: \(error.localizedDescription, privacy: .public)") }
        }
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
        Task {
            do {
                try await inputWriter.respondToPermission(
                    requestId: pending.requestId,
                    behavior: allow ? .allow : .deny,
                    message: message
                )
                pendingPermission = nil
                state = .working
            } catch {
                log.error("permission reply failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Send a `control_request` to interrupt the current turn.
    func interrupt() {
        Task { try? await inputWriter?.interrupt() }
    }

    /// Set the permission mode directly (used by the runningPill menu).
    func setPermissionMode(_ mode: String) {
        permissionMode = mode
        Task { try? await inputWriter?.setPermissionMode(mode) }
    }

    /// Cycle through Claude's permission modes.
    func cyclePermissionMode() {
        let modes = ["default", "acceptEdits", "plan", "dontAsk", "bypassPermissions", "auto"]
        let idx = (modes.firstIndex(of: permissionMode) ?? 0 + 1) % modes.count
        let next = modes[(idx + 1) % modes.count]
        permissionMode = next
        Task { try? await inputWriter?.setPermissionMode(next) }
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
        case "compact_boundary":
            transcript.append(.compactBoundary)
        default:
            break
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
            Task { [weak self] in
                guard let self, let writer = await self.inputWriter else { return }
                try? await writer.respondToPermission(
                    requestId: req.requestId,
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

    var id: String {
        switch self {
        case .userText(let s):       return "u-\(s.hashValue)"
        case .assistantBlock(let b): return "a-\(b.id)"
        case .compactBoundary:       return "cb-\(UUID().uuidString)"
        }
    }
}
