// atelier-terminal MCP server (#55). Atelier hosts the server INSIDE the app
// (which owns the PTYs) on a per-session unix socket; the claude process
// reaches it through a zero-install stdio bridge: `/usr/bin/nc -U <socket>`,
// registered via --mcp-config at spawn (StreamSession.start).
//
// Protocol: MCP over newline-delimited JSON-RPC — initialize, tools/list,
// tools/call, ping; notifications ignored. Tool calls dispatch to
// CoTerminalManager on the main actor, scoped to the owning session so one
// session can never touch another's terminals.

import Foundation
import Darwin

final class TerminalBridge: @unchecked Sendable {
    let socketPath: String
    private let scope: ObjectIdentifier
    private let defaultCwd: String
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "com.munyamakosa.work.coterm.accept")
    private let stateLock = NSLock()
    private var closed = false
    private var connFDs: [Int32] = []

    enum BridgeError: Error { case socketPathTooLong, socketFailed(String) }

    init(scope: ObjectIdentifier, defaultCwd: String) throws {
        self.scope = scope
        self.defaultCwd = defaultCwd
        // Short path — sun_path caps at 104 bytes; NSTemporaryDirectory is
        // per-user (0700), so the socket is private by location.
        let name = "at-\(String(UUID().uuidString.prefix(8))).sock"
        self.socketPath = NSTemporaryDirectory() + name
        guard socketPath.utf8.count < 100 else { throw BridgeError.socketPathTooLong }

        listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFD >= 0 else { throw BridgeError.socketFailed("socket()") }
        unlink(socketPath)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let ok: Bool = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let bytes = Array(socketPath.utf8)
            guard bytes.count < raw.count else { return false }
            raw.baseAddress!.copyMemory(from: bytes, byteCount: bytes.count)
            raw[bytes.count] = 0
            return true
        }
        guard ok else { close(listenFD); throw BridgeError.socketPathTooLong }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listenFD, $0, size) }
        }
        guard bound == 0 else { close(listenFD); throw BridgeError.socketFailed("bind: \(String(cString: strerror(errno)))") }
        guard listen(listenFD, 4) == 0 else { close(listenFD); throw BridgeError.socketFailed("listen") }

        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    func closeBridge() {
        stateLock.lock()
        guard !closed else { stateLock.unlock(); return }
        closed = true
        let fds = connFDs
        connFDs.removeAll()
        stateLock.unlock()
        if listenFD >= 0 { close(listenFD) }
        fds.forEach { close($0) }
        unlink(socketPath)
    }

    private var isClosed: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return closed
    }

    // MARK: Accept + per-connection read loop

    private func acceptLoop() {
        while !isClosed {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { break }
            stateLock.lock(); connFDs.append(fd); stateLock.unlock()
            let q = DispatchQueue(label: "com.munyamakosa.work.coterm.conn.\(fd)")
            q.async { [weak self] in self?.readLoop(fd: fd) }
        }
    }

    private func readLoop(fd: Int32) {
        var pending = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        while !isClosed {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { break }
            pending.append(contentsOf: chunk[0..<n])
            while let nl = pending.firstIndex(of: 0x0A) {
                let line = pending.subdata(in: pending.startIndex..<nl)
                pending.removeSubrange(pending.startIndex...nl)
                handle(line: line, fd: fd)
            }
        }
        close(fd)
        stateLock.lock(); connFDs.removeAll { $0 == fd }; stateLock.unlock()
    }

    // MARK: JSON-RPC handling

    private func handle(line: Data, fd: Int32) {
        guard !line.isEmpty,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let method = obj["method"] as? String
        else { return }
        let id = obj["id"]   // Int or String; echo back verbatim. nil ⇒ notification.

        switch method {
        case "initialize":
            let params = obj["params"] as? [String: Any]
            let version = (params?["protocolVersion"] as? String) ?? "2025-06-18"
            reply(fd, id: id, result: [
                "protocolVersion": version,
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "atelier-terminal", "version": "0.1.0"],
            ])
        case "ping":
            reply(fd, id: id, result: [:])
        case "tools/list":
            reply(fd, id: id, result: ["tools": Self.toolSchemas])
        case "tools/call":
            guard let params = obj["params"] as? [String: Any],
                  let name = params["name"] as? String else {
                replyError(fd, id: id, code: -32602, message: "invalid params")
                return
            }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            // Hop to the main actor for engine state. Async, not .sync:
            // terminal_read/terminal_status can now block on wait_seconds
            // (up to 30s) to let the model wait for a command to finish
            // instead of guessing when to re-poll — a sync hop would freeze
            // the whole app's main thread for that long. The read loop moves
            // on to the next line immediately; replies are id-correlated, so
            // a slower call finishing after a later one is fine for JSON-RPC.
            // Args cross the isolation boundary as Data ([String:Any] isn't
            // Sendable-provable) and are re-decoded inside.
            let argsData = (try? JSONSerialization.data(withJSONObject: args)) ?? Data("{}".utf8)
            let scope = self.scope, cwd = self.defaultCwd
            Task { @MainActor [weak self] in
                let decoded = ((try? JSONSerialization.jsonObject(with: argsData)) as? [String: Any]) ?? [:]
                let (payload, isError) = await CoTerminalManager.shared.handleTool(
                    name: name, args: decoded, scope: scope, defaultCwd: cwd)
                self?.reply(fd, id: id, result: [
                    "content": [["type": "text", "text": payload]],
                    "isError": isError,
                ])
            }
        default:
            if method.hasPrefix("notifications/") { return }   // fire-and-forget
            if id != nil { replyError(fd, id: id, code: -32601, message: "method not found: \(method)") }
        }
    }

    private func reply(_ fd: Int32, id: Any?, result: [String: Any]) {
        guard let id else { return }
        send(fd, ["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func replyError(_ fd: Int32, id: Any?, code: Int, message: String) {
        guard let id else { return }
        send(fd, ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private let writeLock = NSLock()
    private func send(_ fd: Int32, _ obj: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        data.append(0x0A)
        writeLock.lock(); defer { writeLock.unlock() }
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { break }
                off += n
            }
        }
    }

    // MARK: Tool schemas — descriptions are prompt surface; they teach usage.

    // Immutable after init; [String: Any] just isn't Sendable-provable.
    nonisolated(unsafe) private static let toolSchemas: [[String: Any]] = [
        [
            "name": "terminal_run",
            "description": "Run a command in a VISIBLE terminal pane shared with the user (a real PTY — interactive CLIs work). Use this instead of Bash for commands that ask questions (logins, submissions, installers). Returns terminal_id IMMEDIATELY — the command keeps running in the background, it is NOT done when this call returns. To find out when it finishes, call terminal_read or terminal_status with wait_seconds set (e.g. 15) and check the running field in the response: if running is still true, call again with wait_seconds until it's false. Never conclude a command finished from a single instant read. The user sees the same terminal and can type in it; secure prompts (passwords) are hidden from you — ask the user to type those directly. Once running is false and you've read the output, close the pane with terminal_close.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "Shell command to run (zsh -lc)"],
                    "cwd": ["type": "string", "description": "Working directory (defaults to the project)"],
                ],
                "required": ["command"],
            ],
        ],
        [
            "name": "terminal_read",
            "description": "Read output from a co-driven terminal and check whether it has finished. Pass since_cursor from the previous read to get only what's new; omit it for the recent tail. ALWAYS check the running field in the response — if it's still true and you need to know when the command finishes, call this again with wait_seconds (e.g. 15): it blocks until the command exits or that many seconds pass, then returns with running:false and exit_code once it's actually done. Do not spin-poll without wait_seconds and do not assume completion from one read. When secure_input is true, output is withheld and the USER must type; tell them what's needed in chat.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "terminal_id": ["type": "string"],
                    "since_cursor": ["type": "integer", "description": "Cursor from the previous read"],
                    "wait_seconds": ["type": "number", "description": "Block until the command exits or this many seconds pass (max 30), instead of returning immediately. Use this to wait for completion reliably instead of guessing when to poll again."],
                ],
                "required": ["terminal_id"],
            ],
        ],
        [
            "name": "terminal_write",
            "description": "Type into a co-driven terminal (submit=true appends Enter). Use for routine answers you are confident about (menu choices, y/n). REJECTED during secure prompts — never try to enter passwords; ask the user to type them directly.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "terminal_id": ["type": "string"],
                    "text": ["type": "string"],
                    "submit": ["type": "boolean", "description": "Append Enter (default true)"],
                ],
                "required": ["terminal_id", "text"],
            ],
        ],
        [
            "name": "terminal_status",
            "description": "Running state, exit code, elapsed seconds, and secure_input flag for a co-driven terminal. Set wait_seconds (e.g. 15) to block until the command exits or that many seconds pass, instead of returning an instant (possibly still-running) snapshot — the reliable way to find out when a command is actually done.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "terminal_id": ["type": "string"],
                    "wait_seconds": ["type": "number", "description": "Block until the command exits or this many seconds pass (max 30), instead of returning immediately."],
                ],
                "required": ["terminal_id"],
            ],
        ],
        [
            "name": "terminal_list",
            "description": "List this session's co-driven terminals (id, command, running, exit code).",
            "inputSchema": ["type": "object", "properties": [String: Any]()],
        ],
        [
            "name": "terminal_close",
            "description": "Close a co-driven terminal's pane. Use this once a terminal you opened has finished and you've read what you need — finished panes otherwise stay on the user's screen until they dismiss each one by hand. Terminates the process if it is still running, so only close a running terminal when the user asked you to stop it.",
            "inputSchema": [
                "type": "object",
                "properties": ["terminal_id": ["type": "string"]],
                "required": ["terminal_id"],
            ],
        ],
    ]
}
