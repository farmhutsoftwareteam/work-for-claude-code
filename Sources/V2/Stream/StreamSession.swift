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
        case idle
        case spawning
        case initializing
        case working
        case awaitingPermission
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

    /// Latest queued permission request — the inline permission card binds here.
    @Published private(set) var pendingPermission: PendingPermission?

    /// Latest result event totals (for the result footer).
    @Published private(set) var latestResult: ResultEvent?

    /// Total tokens used this session, summed from result.usage.
    @Published private(set) var tokensUsed: Int = 0

    /// Set true while an `api_retry` is in flight.
    @Published private(set) var isRetrying: Bool = false

    // MARK: - Internals

    private var process: Process?
    private var inputWriter: StreamInputWriter?
    private var eventConsumer: Task<Void, Never>?
    private var stderrConsumer: Task<Void, Never>?

    // MARK: - Lifecycle

    /// Launch `claude -p` in the project's cwd. No-op if not idle.
    func start(cwd: URL, claudeURL: URL) {
        guard state == .idle else { return }
        state = .spawning

        let process = Process()
        process.executableURL = claudeURL
        process.arguments = [
            "-p",
            "--output-format", "stream-json",
            "--input-format", "stream-json",
            "--include-partial-messages",
            "--verbose"
        ]
        process.currentDirectoryURL = cwd

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
            log.error("spawn failed: \(error.localizedDescription, privacy: .public)")
            state = .terminated(reason: "spawn failed: \(error.localizedDescription)")
            return
        }

        self.process = process
        self.inputWriter = StreamInputWriter(fileHandle: stdinPipe.fileHandleForWriting)
        self.state = .initializing

        // Drain stdout into the dispatch loop.
        eventConsumer = Task { [weak self, stdoutPipe] in
            guard let self else { return }
            for await event in stdoutPipe.fileHandleForReading.ndjsonEvents() {
                await self.handle(event: event)
                if Task.isCancelled { break }
            }
        }

        // Drain stderr — log only; we don't surface this in the UI yet.
        stderrConsumer = Task { [stderrPipe] in
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    log.warning("claude stderr: \(line, privacy: .public)")
                    if Task.isCancelled { break }
                }
            } catch {
                log.error("stderr drain failed: \(error.localizedDescription, privacy: .public)")
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
        Task {
            try? await inputWriter?.close()
            process?.terminate()
            state = .terminated(reason: "user_stop")
        }
    }

    // MARK: - Event dispatch

    private func handle(event: StreamEvent) {
        switch event {
        case .system(let sys):
            handleSystem(sys)
        case .assistant(let m):
            for block in m.message.content {
                transcript.append(.assistantBlock(block))
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
            if state == .working || state == .awaitingPermission {
                state = .idle
            }
        case .controlRequest(let req):
            handleControlRequest(req)
        case .controlResponse:
            // Replies to our outgoing control requests — fine to ignore for now.
            break
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
            state = .working
        case "api_retry":
            isRetrying = true
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
