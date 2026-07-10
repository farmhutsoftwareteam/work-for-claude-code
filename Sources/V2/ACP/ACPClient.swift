// ACPClient — Agent Client Protocol client for Atelier (Phase 1 of the
// stream-json → ACP migration; see memory: atelier-acp-migration).
//
// Speaks JSON-RPC 2.0 over newline-delimited stdio to `claude-code-acp`
// (https://github.com/zed-industries/claude-code-acp), a Node binary that
// wraps the Claude Agent SDK and exposes the full surface — permissions,
// tool calls, plan, MCP, cancellation — over a documented protocol. This
// replaces the hand-rolled `StreamSession` control protocol that we kept
// finding gaps in.
//
// Foundation-only (no SwiftUI) so the same file compiles into both the app
// and the AtelierSpikeACP CLI smoke test. The app wraps this in an
// ObservableObject; the CLI drives the closures directly.
//
// Protocol shapes verified against @zed-industries/agent-client-protocol
// schema.json (protocolVersion 1) and a live round-trip on 2026-06-29:
//   initialize → session/new → session/prompt → agent_message_chunk → stopReason
//
// Phase 1 scope: connect, initialize, new session, one prompt turn, stream
// agent text back. Permission requests (session/request_permission), tool
// streaming, plan, cancellation, resume are stubbed for later phases.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "acp")

// (Phase-1 stderr breadcrumb helper removed — crash was traced to
// callbacks running off the main thread; see onMain below.)

/// Hop to the main thread. All consumer-facing callbacks (onAgentText,
/// onModels, …) are invoked here: the reader runs on a background thread,
/// but these callbacks drive @Published SwiftUI state in the app (which
/// must be on main) and even plain stdout writes trap off-main in a CLI.
/// Internal protocol sequencing stays on the reader thread.
private func onMain(_ block: @escaping () -> Void) {
    if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
}

final class ACPClient: @unchecked Sendable {

    // MARK: - Callbacks (the app / CLI sets these)

    /// A chunk of the agent's reply text streamed in.
    var onAgentText: ((String) -> Void)?
    /// A chunk of the agent's internal reasoning (thinking).
    var onAgentThought: ((String) -> Void)?
    /// The current prompt turn finished. Argument is the stop reason
    /// ("end_turn", "max_tokens", "cancelled", …).
    var onTurnEnd: ((String) -> Void)?
    /// The models the agent reported at session/new.
    var onModels: (([ACPModel]) -> Void)?
    /// A tool call started or changed. The full merged ACPToolCall is
    /// emitted each time (tool_call_update sends only deltas; the client
    /// merges them), so the consumer can render the complete current state.
    var onToolCall: ((ACPToolCall) -> Void)?
    /// The agent's current plan (todo list). Emitted on every `plan` update
    /// with the full entry list.
    var onPlan: (([ACPPlanEntry]) -> Void)?
    /// The session's permission mode changed (either we set it, or the agent
    /// did — e.g. exiting plan mode). Keeps the UI's mode pill in sync.
    var onModeChanged: ((String) -> Void)?
    /// Slash commands the agent advertises (for composer autocomplete).
    var onCommands: (([ACPCommand]) -> Void)?
    /// A protocol-level or transport error.
    var onError: ((String) -> Void)?
    /// Agent is asking the client to approve a tool use. This is a
    /// NOTIFICATION, not a synchronous query — the reader thread must not
    /// block waiting for a click. The consumer shows UI and later calls
    /// resolvePermission(requestId:optionId:). Delivered on the main thread.
    var onPermissionRequest: ((ACPPermissionRequest) -> Void)?

    // MARK: - State

    private(set) var sessionId: String?
    private(set) var isConnected = false

    private var process: Process?
    private var stdinHandle: FileHandle?
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?

    private let lineBuffer = ACPLineBuffer()
    private var nextId = 0
    private let idLock = NSLock()

    /// Serializes writes to the child's stdin. Reads happen on a dedicated
    /// blocking thread (readerThread); writes can come from the main thread
    /// (start/prompt) or the reader thread (a response triggering the next
    /// request), so the write lock guards against interleaving. We
    /// deliberately avoid FileHandle.readabilityHandler + DispatchQueue —
    /// that combo traps in _dispatch_assert_queue_fail when a write is
    /// issued from the read queue. A plain blocking reader sidesteps it.
    private let writeLock = NSLock()
    private var readerThread: Thread?
    private var running = false
    private var stdinFD: Int32 = -1

    /// JSON-RPC ids of in-flight session/request_permission requests we
    /// haven't answered yet. On cancel we must reply to each with the
    /// `cancelled` outcome (spec requirement) or the agent hangs.
    private var pendingPermissionIds: Set<Int> = []
    private let permLock = NSLock()

    /// Tool calls by toolCallId. Mutated only on the reader thread (in
    /// handleSessionUpdate, which runs serially there), so no lock needed.
    /// tool_call_update carries only changed fields; we merge into the
    /// stored value and emit the full object.
    private var toolCalls: [String: ACPToolCall] = [:]

    /// id → handler for our outgoing requests' responses.
    private var pending: [Int: (Result<[String: Any], ACPError>) -> Void] = [:]
    private let pendingLock = NSLock()

    // MARK: - Lifecycle

    /// Defense-in-depth alongside the explicit `stop()` call site
    /// (V2ACPChatView.onDisappear) — if some other owner ever forgets to
    /// call stop(), the subprocess still dies when this object does instead
    /// of outliving the view it was created for (bug-hunt H4).
    deinit {
        process?.terminate()
        try? stdinHandle?.close()
    }

    /// Spawn `node <acpIndexJS>` and run the initialize → session/new
    /// handshake. `cwd` is the project directory the session operates in.
    func start(nodeURL: URL, acpIndexJS: URL, cwd: URL, completion: @escaping (Bool) -> Void) {
        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [acpIndexJS.path]
        process.currentDirectoryURL = cwd
        process.environment = Self.enrichedEnvironment()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        signal(SIGPIPE, SIG_IGN)

        do {
            try process.run()
        } catch {
            log.error("ACP spawn failed: \(error.localizedDescription, privacy: .public)")
            onError?("spawn failed: \(error.localizedDescription)")
            completion(false)
            return
        }

        self.process = process
        self.stdinHandle = stdinPipe.fileHandleForWriting
        self.stdoutHandle = stdoutPipe.fileHandleForReading
        self.stderrHandle = stderrPipe.fileHandleForReading
        self.stdinFD = stdinPipe.fileHandleForWriting.fileDescriptor
        self.running = true

        // RAW POSIX I/O. Foundation's FileHandle read/write paths install
        // private dispatch sources that assert they aren't reused off their
        // owning queue (EXC_BREAKPOINT in _dispatch_assert_queue_fail) — they
        // are not safe for a hand-rolled blocking reader thread that also
        // writes. read(2)/write(2) on the raw fds have no such machinery.
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let reader = Thread { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 64 * 1024)
            while self.running {
                let n = buf.withUnsafeMutableBytes { read(outFD, $0.baseAddress, $0.count) }
                if n <= 0 { break }  // EOF or error — child closed stdout
                self.lineBuffer.append(Data(buf[0..<n]))
                for line in self.lineBuffer.drainLines() {
                    self.handleLine(line)
                }
            }
        }
        reader.stackSize = 1 << 20
        reader.name = "acp-reader"
        self.readerThread = reader
        reader.start()

        // stderr drain on its own thread so a chatty child can't fill the
        // pipe buffer and stall.
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        let errThread = Thread {
            var buf = [UInt8](repeating: 0, count: 16 * 1024)
            while true {
                let n = buf.withUnsafeMutableBytes { read(errFD, $0.baseAddress, $0.count) }
                if n <= 0 { break }
                if let s = String(bytes: buf[0..<n], encoding: .utf8) {
                    for ln in s.split(whereSeparator: \.isNewline)
                    where !ln.trimmingCharacters(in: .whitespaces).isEmpty {
                        log.warning("acp stderr: \(String(ln), privacy: .public)")
                    }
                }
            }
        }
        errThread.name = "acp-stderr"
        errThread.start()

        // initialize → on success, session/new → on success, ready.
        sendRequest(method: "initialize", params: [
            "protocolVersion": 1,
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false
            ]
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                onMain { self.onError?("initialize failed: \(e.message)"); completion(false) }
            case .success:
                self.sendRequest(method: "session/new", params: [
                    "cwd": cwd.path,
                    "mcpServers": []
                ]) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .failure(let e):
                        onMain { self.onError?("session/new failed: \(e.message)"); completion(false) }
                    case .success(let r):
                        self.sessionId = r["sessionId"] as? String
                        self.isConnected = self.sessionId != nil
                        let models: [ACPModel] = ((r["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? []).map {
                            ACPModel(id: $0["modelId"] as? String ?? "",
                                     name: $0["name"] as? String ?? "",
                                     description: $0["description"] as? String ?? "")
                        }
                        let connected = self.isConnected
                        onMain {
                            if !models.isEmpty { self.onModels?(models) }
                            completion(connected)
                        }
                    }
                }
            }
        }
    }

    /// Send a user prompt turn. Streams back via onAgentText / onTurnEnd.
    func prompt(_ text: String) {
        guard let sessionId else { onMain { self.onError?("no session") }; return }
        sendRequest(method: "session/prompt", params: [
            "sessionId": sessionId,
            "prompt": [["type": "text", "text": text]]
        ]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e): onMain { self.onError?("prompt failed: \(e.message)") }
            case .success(let r):
                let reason = r["stopReason"] as? String ?? "end_turn"
                onMain { self.onTurnEnd?(reason) }
            }
        }
    }

    /// Switch the session's model (session/set_model). modelId comes from
    /// the list session/new returned (default / sonnet / haiku / …).
    func setModel(_ modelId: String) {
        guard let sessionId else { return }
        sendRequest(method: "session/set_model",
                    params: ["sessionId": sessionId, "modelId": modelId]) { _ in }
    }

    /// Switch the session's permission mode (session/set_mode). This is the
    /// CORRECT way to change modes — including the bypassPermissions case
    /// the stream-json path couldn't switch to at runtime. A
    /// current_mode_update notification confirms it via onModeChanged.
    func setMode(_ modeId: String) {
        guard let sessionId else { return }
        sendRequest(method: "session/set_mode",
                    params: ["sessionId": sessionId, "modeId": modeId]) { _ in }
    }

    /// Resume a prior session (session/load). Replays its history as
    /// session/update notifications, then the session is live again — the
    /// native replacement for `claude --resume` + manual jsonl preload.
    func loadSession(sessionId: String, cwd: URL, completion: @escaping (Bool) -> Void) {
        sendRequest(method: "session/load", params: [
            "sessionId": sessionId, "cwd": cwd.path, "mcpServers": []
        ]) { [weak self] result in
            switch result {
            case .failure(let e): onMain { self?.onError?("session/load failed: \(e.message)"); completion(false) }
            case .success:
                self?.sessionId = sessionId
                self?.isConnected = true
                onMain { completion(true) }
            }
        }
    }

    func stop() {
        running = false
        try? stdinHandle?.close()
        process?.terminate()
        process = nil
        isConnected = false
    }

    // MARK: - Inbound line dispatch

    private func handleLine(_ data: Data) {
        guard !data.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // Response to one of our requests?
        if let id = obj["id"] as? Int, obj["method"] == nil {
            let handler: ((Result<[String: Any], ACPError>) -> Void)?
            pendingLock.lock(); handler = pending.removeValue(forKey: id); pendingLock.unlock()
            if let err = obj["error"] as? [String: Any] {
                handler?(.failure(ACPError(message: err["message"] as? String ?? "error",
                                           code: err["code"] as? Int ?? 0)))
            } else {
                handler?(.success(obj["result"] as? [String: Any] ?? [:]))
            }
            return
        }

        // Notification or agent→client request, dispatched by method.
        guard let method = obj["method"] as? String else { return }
        let params = obj["params"] as? [String: Any] ?? [:]

        switch method {
        case "session/update":
            handleSessionUpdate(params)
        case "session/request_permission":
            // Agent→client REQUEST (has id) — must respond, but NOT
            // synchronously: surface it and let the UI resolve later.
            if let id = obj["id"] as? Int { handlePermission(id: id, params: params) }
        default:
            // fs/*, terminal/* and others arrive in later phases.
            log.debug("acp unhandled method \(method, privacy: .public)")
        }
    }

    private func handleSessionUpdate(_ params: [String: Any]) {
        guard let update = params["update"] as? [String: Any],
              let kind = update["sessionUpdate"] as? String else { return }
        switch kind {
        case "agent_message_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                onMain { self.onAgentText?(text) }
            }
        case "agent_thought_chunk":
            if let text = (update["content"] as? [String: Any])?["text"] as? String {
                onMain { self.onAgentThought?(text) }
            }
        case "tool_call", "tool_call_update":
            // Both carry the same field set; merge handles new vs delta.
            handleToolCall(update)
        case "plan":
            let entries = (update["entries"] as? [[String: Any]] ?? []).map {
                ACPPlanEntry(
                    content: $0["content"] as? String ?? "",
                    status: $0["status"] as? String ?? "pending",
                    priority: $0["priority"] as? String ?? "medium"
                )
            }
            onMain { self.onPlan?(entries) }
        case "current_mode_update":
            if let mode = update["currentModeId"] as? String {
                onMain { self.onModeChanged?(mode) }
            }
        case "available_commands_update":
            let cmds = (update["availableCommands"] as? [[String: Any]] ?? []).map {
                ACPCommand(name: $0["name"] as? String ?? "",
                           description: $0["description"] as? String ?? "")
            }
            onMain { self.onCommands?(cmds) }
        default:
            break
        }
    }

    /// Build or merge a tool call from a tool_call / tool_call_update.
    private func handleToolCall(_ u: [String: Any]) {
        guard let id = u["toolCallId"] as? String else { return }
        var call = toolCalls[id] ?? ACPToolCall(
            id: id, title: "", kind: "other", status: "pending", content: []
        )
        // Merge only present fields (updates are sparse).
        if let t = u["title"] as? String { call.title = t }
        if let k = u["kind"] as? String { call.kind = k }
        if let s = u["status"] as? String { call.status = s }
        if let content = u["content"] as? [[String: Any]] {
            call.content = content.compactMap { Self.parseToolContent($0) }
        }
        toolCalls[id] = call
        onMain { self.onToolCall?(call) }
    }

    private static func parseToolContent(_ c: [String: Any]) -> ACPToolContent? {
        switch c["type"] as? String {
        case "content":
            // { type:"content", content: ContentBlock(text) }
            if let text = (c["content"] as? [String: Any])?["text"] as? String {
                return .text(text)
            }
            return nil
        case "diff":
            guard let path = c["path"] as? String,
                  let newText = c["newText"] as? String else { return nil }
            return .diff(path: path, oldText: c["oldText"] as? String, newText: newText)
        case "terminal":
            guard let tid = c["terminalId"] as? String else { return nil }
            return .terminal(terminalId: tid)
        default:
            return nil
        }
    }

    private func handlePermission(id: Int, params: [String: Any]) {
        let toolCall = params["toolCall"] as? [String: Any] ?? [:]
        let options = (params["options"] as? [[String: Any]] ?? []).map {
            ACPPermissionOption(
                id: $0["optionId"] as? String ?? "",
                name: $0["name"] as? String ?? "(option)",
                kind: $0["kind"] as? String ?? "allow_once"
            )
        }
        // Pull a human-readable command/detail out of rawInput (Bash →
        // {command}, Edit/Write → {file_path}, etc.).
        let raw = toolCall["rawInput"] as? [String: Any] ?? [:]
        let detail = raw["command"] as? String
            ?? raw["file_path"] as? String
            ?? raw["path"] as? String

        let req = ACPPermissionRequest(
            requestId: id,
            toolName: toolCall["title"] as? String ?? toolCall["kind"] as? String ?? "tool",
            toolKind: toolCall["kind"] as? String,
            detail: detail,
            options: options
        )

        permLock.lock(); pendingPermissionIds.insert(id); permLock.unlock()

        if onPermissionRequest != nil {
            onMain { self.onPermissionRequest?(req) }
        } else {
            // No handler wired — fail safe by rejecting (prefer a reject_once
            // option, else the first option) so the agent never hangs.
            let fallback = options.first(where: { $0.kind.hasPrefix("reject") })?.id
                ?? options.first?.id ?? "reject"
            resolvePermission(requestId: id, optionId: fallback)
        }
    }

    /// Answer a pending permission request with the user's chosen option.
    /// Safe to call from the main thread; the actual write is serialized.
    func resolvePermission(requestId: Int, optionId: String) {
        permLock.lock()
        let wasPending = pendingPermissionIds.remove(requestId) != nil
        permLock.unlock()
        guard wasPending else { return }  // already answered / cancelled
        respond(id: requestId, result: ["outcome": ["outcome": "selected", "optionId": optionId]])
    }

    /// Cancel the current turn. Per the ACP spec we must answer every
    /// in-flight permission request with the `cancelled` outcome before /
    /// alongside the session/cancel notification, or the agent stalls.
    func cancel() {
        guard let sessionId else { return }
        permLock.lock()
        let inflight = pendingPermissionIds
        pendingPermissionIds.removeAll()
        permLock.unlock()
        for id in inflight {
            respond(id: id, result: ["outcome": ["outcome": "cancelled"]])
        }
        writeMessage(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
    }

    // MARK: - Outbound

    private func sendRequest(method: String, params: [String: Any],
                             handler: @escaping (Result<[String: Any], ACPError>) -> Void) {
        idLock.lock(); nextId += 1; let id = nextId; idLock.unlock()
        pendingLock.lock(); pending[id] = handler; pendingLock.unlock()
        writeMessage(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func respond(id: Any?, result: [String: Any]) {
        guard let id else { return }
        writeMessage(["jsonrpc": "2.0", "id": id, "result": result])
    }

    /// Returns whether the write actually succeeded. On failure — almost
    /// always the child process has died — and only when `obj` is one of
    /// OUR requests (has a "method", distinguishing it from a `respond()`
    /// call answering the AGENT's request, which reuses the agent's own id
    /// namespace and must not be looked up here), fires and removes the
    /// matching `pending[id]` handler with a failure instead of leaving it
    /// registered forever. Previously this only logged, so the caller's
    /// completion handler (registered in sendRequest) dangled — the UI
    /// stayed stuck at `.working` with no error surfaced (bug-hunt #11/M32).
    @discardableResult
    private func writeMessage(_ obj: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return false }
        var line = data
        line.append(0x0A)
        var succeeded = true
        writeLock.lock()
        // Raw write(2) — write the whole frame, handling partial writes.
        line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var off = 0
            let total = raw.count
            guard let base = raw.baseAddress else { succeeded = false; return }
            while off < total {
                let n = write(stdinFD, base + off, total - off)
                if n <= 0 { log.error("acp write failed (errno \(errno))"); succeeded = false; return }
                off += n
            }
        }
        writeLock.unlock()

        if !succeeded, let id = obj["id"] as? Int, obj["method"] != nil {
            pendingLock.lock()
            let handler = pending.removeValue(forKey: id)
            pendingLock.unlock()
            if let handler {
                onMain { handler(.failure(ACPError(message: "write failed", code: -1))) }
            }
        }
        return succeeded
    }

    // MARK: - Environment

    /// GUI-launched apps inherit launchd's stripped PATH; node + the acp bin
    /// live in user dirs. Mirror the PATH enrichment StreamSession uses, and
    /// strip CLAUDECODE so the wrapped Agent SDK doesn't think it's nested.
    static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extra = [
            "\(home)/.local/bin", "\(home)/.npm-global/bin",
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "\(home)/.nvm/current/bin"
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extra + [existing]).joined(separator: ":")
        env.removeValue(forKey: "CLAUDECODE")
        env.removeValue(forKey: "CLAUDE_CODE_SSE_PORT")
        env.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")
        return env
    }
}

// MARK: - Types

struct ACPModel: Equatable, Sendable {
    let id: String
    let name: String
    let description: String
}

/// A single entry in the agent's plan (todo list). status walks
/// pending → in_progress → completed; priority is high/medium/low.
struct ACPPlanEntry: Sendable, Equatable {
    let content: String
    let status: String
    let priority: String
}

/// A slash command the agent advertises (for composer autocomplete).
struct ACPCommand: Sendable, Equatable, Identifiable {
    let name: String
    let description: String
    var id: String { name }
}

/// One rendered piece of a tool call's output.
enum ACPToolContent: Sendable, Equatable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(terminalId: String)
}

/// A tool call as it streams: created via tool_call, refined via
/// tool_call_update. `status` walks pending → in_progress → completed/failed.
/// `kind` is the ACP ToolKind (read/edit/delete/move/search/execute/think/
/// fetch/switch_mode/other) — drives the icon in the UI.
struct ACPToolCall: Sendable, Identifiable, Equatable {
    let id: String
    var title: String
    var kind: String
    var status: String
    var content: [ACPToolContent]
}

struct ACPPermissionOption: Equatable, Sendable, Identifiable {
    let id: String       // optionId to send back
    let name: String     // human label ("Allow once", …)
    let kind: String     // allow_once | allow_always | reject_once | reject_always

    var isAllow: Bool { kind.hasPrefix("allow") }
    var isRemembered: Bool { kind.hasSuffix("always") }
}

struct ACPPermissionRequest: Sendable, Identifiable {
    let requestId: Int
    let toolName: String       // e.g. "Bash" / "Run shell command"
    let toolKind: String?      // ACP ToolKind hint (execute, edit, read, …)
    let detail: String?        // the command / file path being acted on
    let options: [ACPPermissionOption]
    var id: Int { requestId }
}

struct ACPError: Error, Sendable {
    let message: String
    let code: Int
}

/// Newline-delimited frame buffer for the JSON-RPC stream. NSLock-guarded
/// because readabilityHandler fires on a background queue.
final class ACPLineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    func drainLines() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var lines: [Data] = []
        while let nl = data.firstIndex(of: 0x0A) {
            lines.append(Data(data[data.startIndex..<nl]))
            data.removeSubrange(data.startIndex...nl)
        }
        return lines
    }
}
