// Co-driven terminal engine (#56). One CoTerminal = one real PTY running a
// command in a visible SwiftTerm pane that BOTH drivers share: the user can
// click in and type; Claude reads/writes through the atelier-terminal MCP
// tools (TerminalBridge).
//
// The security invariant lives HERE, not in the UI: while the PTY has terminal
// echo OFF (password prompts), tool reads are clamped to the pre-secure
// output and tool writes are rejected outright — the model can neither see
// nor type secrets, even if it holds one.
//
// Perf (PERFORMANCE.md): PTY bytes flow AppKit-side (ring buffer + SwiftTerm
// feed) — no per-byte SwiftUI publishes. Published state is low-frequency:
// running/exit/secure/agent-input-log.

import Foundation
import AppKit
import Combine
import SwiftTerm
import Darwin

// MARK: - Ring storage (any-thread, locked)

/// Append-only output ring with absolute byte cursors, so tool reads are
/// honest under TUI redraws ("give me bytes since X", never screen scraping).
final class CoTermRing: @unchecked Sendable {
    private let lock = NSLock()
    private var buf = Data()
    private var base = 0                 // absolute offset of buf[0]
    private var secureBoundary: Int?     // absolute offset where echo went off
    private let cap = 2_000_000

    var total: Int { lock.lock(); defer { lock.unlock() }; return base + buf.count }

    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        buf.append(d)
        if buf.count > cap {
            let drop = buf.count - cap
            buf.removeFirst(drop)
            base += drop
        }
    }

    func markSecure() {
        lock.lock(); defer { lock.unlock() }
        if secureBoundary == nil { secureBoundary = base + buf.count }
    }

    func clearSecure() {
        lock.lock(); defer { lock.unlock() }
        secureBoundary = nil
    }

    /// Read new output. `since` nil ⇒ the tail (~8KB). While a secure boundary
    /// is set, output past it is withheld (belt-and-braces: with echo off the
    /// secret bytes are never echoed anyway; this also hides `*` masks).
    func read(since: Int?) -> (text: String, cursor: Int, gapped: Bool) {
        lock.lock(); defer { lock.unlock() }
        let totalNow = base + buf.count
        let end = min(secureBoundary ?? totalNow, totalNow)
        var start = since ?? max(base, end - 8_192)
        let gapped = (since ?? base) < base
        start = min(max(start, base), end)
        let slice = buf[(start - base) ..< (end - base)]
        return (String(decoding: slice, as: UTF8.self), end, gapped)
    }
}

// MARK: - CoTerminal

@MainActor
final class CoTerminal: NSObject, ObservableObject, Identifiable {
    nonisolated let id = UUID()
    let command: String
    let cwd: String
    let startedAt = Date()

    @Published private(set) var isRunning = true
    @Published private(set) var exitCode: Int32?
    /// Set on process exit — freezes the header's duration readout.
    @Published private(set) var endedAt: Date?
    /// Pane folded to its header (Chrome download-shelf style). Lives on the
    /// model so it survives tab switches; forced open when a secure prompt
    /// appears (it requires the user's typing).
    @Published var isCollapsed = false
    @Published private(set) var secureInput = false
    /// Agent-typed input, for the pane's attribution strip. Secure writes are
    /// rejected upstream, so secrets can never land here.
    @Published private(set) var agentInputs: [String] = []
    @Published private(set) var lastAgentReadAt: Date?

    nonisolated let ring = CoTermRing()
    private var process: LocalProcess!
    private(set) var view: SwiftTerm.TerminalView!
    private var cols = 100, rows = 30
    private let ioQueue = DispatchQueue(label: "com.munyamakosa.work.coterm.io")

    init(command: String, cwd: String) {
        self.command = command
        self.cwd = cwd
        super.init()
        view = SwiftTerm.TerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 262))
        view.terminalDelegate = self
        // Design: the terminal body is dark in BOTH themes (--term-bg #161719,
        // --term-ink #d9dad6) — a terminal is a terminal.
        view.nativeBackgroundColor = NSColor(red: 0x16/255, green: 0x17/255, blue: 0x19/255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0xd9/255, green: 0xda/255, blue: 0xd6/255, alpha: 1)
        process = LocalProcess(delegate: self, dispatchQueue: ioQueue)
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        let envList = env.map { "\($0.key)=\($0.value)" }
        process.startProcess(
            executable: "/bin/zsh",
            args: ["-lc", command],
            environment: envList,
            currentDirectory: cwd
        )
    }

    // MARK: Echo / secure detection

    /// ECHO bit of the PTY's termios — off during password prompts. tcgetattr
    /// on the master fd reflects the pty's shared line discipline.
    nonisolated private func echoIsOff() -> Bool {
        let fd = childFD()
        guard fd >= 0 else { return false }
        var t = termios()
        guard tcgetattr(fd, &t) == 0 else { return false }
        return (t.c_lflag & UInt(ECHO)) == 0
    }

    nonisolated private func childFD() -> Int32 {
        // LocalProcess exposes the child fd (the pty master on our side).
        MainActor.assumeIsolated { process.childfd }
    }

    /// Re-sample echo state; adjust the ring's secure boundary + published flag.
    func refreshSecureState() {
        let off = echoIsOff()
        guard off != secureInput else { return }
        secureInput = off
        if off { ring.markSecure() } else { ring.clearSecure() }
    }

    // MARK: Tool-facing API (called on the main actor by the manager)

    struct ReadResult { let text: String; let cursor: Int; let gapped: Bool }

    func toolRead(since: Int?) -> ReadResult {
        refreshSecureState()
        lastAgentReadAt = Date()
        let r = ring.read(since: since)
        return ReadResult(text: r.text, cursor: r.cursor, gapped: r.gapped)
    }

    enum WriteError: Error { case secureInput, notRunning }

    func toolWrite(_ text: String, submit: Bool) throws {
        guard isRunning else { throw WriteError.notRunning }
        refreshSecureState()
        guard !secureInput else { throw WriteError.secureInput }
        let payload = submit ? text + "\r" : text
        process.send(data: ArraySlice(Array(payload.utf8)))
        agentInputs.append(submit ? "\(text) ⏎" : text)
        if agentInputs.count > 50 { agentInputs.removeFirst(agentInputs.count - 50) }
    }

    func terminate() {
        guard isRunning else { return }
        process.terminate()
    }
}

// MARK: LocalProcessDelegate (called on ioQueue)

extension CoTerminal: LocalProcessDelegate {
    nonisolated func dataReceived(slice: ArraySlice<UInt8>) {
        ring.append(Data(slice))
        let bytes = Array(slice)
        Task { @MainActor in
            self.view.feed(byteArray: bytes[...])
            self.refreshSecureState()
        }
    }

    nonisolated func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
        Task { @MainActor in
            self.isRunning = false
            self.exitCode = exitCode
            self.endedAt = Date()
            self.secureInput = false
            self.ring.clearSecure()
        }
    }

    nonisolated func getWindowSize() -> winsize {
        let (c, r) = MainActor.assumeIsolated { (cols, rows) }
        return winsize(ws_row: UInt16(r), ws_col: UInt16(c), ws_xpixel: 0, ws_ypixel: 0)
    }
}

// MARK: TerminalViewDelegate (user typing + view events, main thread)

// @preconcurrency: the protocol is nonisolated but AppKit's TerminalView only
// calls it on the main thread, where CoTerminal lives.
extension CoTerminal: @preconcurrency TerminalViewDelegate {
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        // The USER typed in the pane — straight to the PTY, never logged.
        process.send(data: data)
    }

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        cols = newCols; rows = newRows
        var ws = winsize(ws_row: UInt16(newRows), ws_col: UInt16(newCols), ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(process.childfd, TIOCSWINSZ, &ws)
    }

    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
    func bell(source: SwiftTerm.TerminalView) { NSSound.beep() }
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { V2Clipboard.copy(s) }
    }
}

// MARK: - Manager

/// Registry of co-driven terminals, scoped per StreamSession (ObjectIdentifier)
/// so one session's tools can never touch another session's terminals.
@MainActor
final class CoTerminalManager: ObservableObject {
    static let shared = CoTerminalManager()
    @Published private(set) var byScope: [ObjectIdentifier: [CoTerminal]] = [:]

    func terminals(for session: StreamSession) -> [CoTerminal] {
        byScope[ObjectIdentifier(session)] ?? []
    }

    func run(command: String, cwd: String, scope: ObjectIdentifier) -> CoTerminal {
        let t = CoTerminal(command: command, cwd: cwd)
        byScope[scope, default: []].append(t)
        return t
    }

    func terminal(id: String, scope: ObjectIdentifier) -> CoTerminal? {
        byScope[scope]?.first { $0.id.uuidString == id }
    }

    func close(_ t: CoTerminal, scope: ObjectIdentifier) {
        t.terminate()
        byScope[scope]?.removeAll { $0.id == t.id }
        if byScope[scope]?.isEmpty == true { byScope[scope] = nil }
    }

    func closeAll(scope: ObjectIdentifier) {
        byScope[scope]?.forEach { $0.terminate() }
        byScope[scope] = nil
    }

    // MARK: Tool dispatch (bridge calls this via main.sync)

    /// Returns (JSON text payload, isError) for a tools/call.
    func handleTool(name: String, args: [String: Any], scope: ObjectIdentifier, defaultCwd: String) -> (String, Bool) {
        func json(_ obj: [String: Any]) -> String {
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
                  let s = String(data: d, encoding: .utf8) else { return "{}" }
            return s
        }
        switch name {
        case "terminal_run":
            guard let command = args["command"] as? String, !command.isEmpty else {
                return (json(["error": "command is required"]), true)
            }
            let cwd = (args["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? defaultCwd
            let t = run(command: command, cwd: cwd, scope: scope)
            return (json([
                "terminal_id": t.id.uuidString,
                "note": "Terminal opened in a visible pane the user shares. Use terminal_read to see output (poll after writes); ask the user in chat for anything you can't answer. Secure prompts (passwords) are hidden from you — tell the user to type directly."
            ]), false)

        case "terminal_read":
            guard let t = requireTerminal(args, scope: scope) else {
                return (json(["error": "unknown terminal_id"]), true)
            }
            let since = args["since_cursor"] as? Int
            let r = t.toolRead(since: since)
            var out: [String: Any] = [
                "text": r.text,
                "cursor": r.cursor,
                "running": t.isRunning,
                "secure_input": t.secureInput,
            ]
            if t.secureInput { out["note"] = "[secure input in progress — output withheld; the user must type directly]" }
            if r.gapped { out["note_gap"] = "older output evicted; cursor restarted from available history" }
            if let code = t.exitCode { out["exit_code"] = Int(code) }
            return (json(out), false)

        case "terminal_write":
            guard let t = requireTerminal(args, scope: scope) else {
                return (json(["error": "unknown terminal_id"]), true)
            }
            guard let text = args["text"] as? String else {
                return (json(["error": "text is required"]), true)
            }
            let submit = (args["submit"] as? Bool) ?? true
            do {
                try t.toolWrite(text, submit: submit)
                return (json(["ok": true]), false)
            } catch CoTerminal.WriteError.secureInput {
                return (json(["error": "secure prompt — the user must type this directly in the terminal; do not attempt to enter it"]), true)
            } catch {
                return (json(["error": "terminal is not running"]), true)
            }

        case "terminal_status":
            guard let t = requireTerminal(args, scope: scope) else {
                return (json(["error": "unknown terminal_id"]), true)
            }
            var out: [String: Any] = [
                "running": t.isRunning,
                "secure_input": t.secureInput,
                "elapsed_seconds": Int(Date().timeIntervalSince(t.startedAt)),
                "command": t.command,
            ]
            if let code = t.exitCode { out["exit_code"] = Int(code) }
            return (json(out), false)

        case "terminal_list":
            let list = (byScope[scope] ?? []).map { t -> [String: Any] in
                var e: [String: Any] = [
                    "terminal_id": t.id.uuidString,
                    "command": t.command,
                    "running": t.isRunning,
                ]
                if let code = t.exitCode { e["exit_code"] = Int(code) }
                return e
            }
            return (json(["terminals": list]), false)

        default:
            return (json(["error": "unknown tool \(name)"]), true)
        }
    }

    private func requireTerminal(_ args: [String: Any], scope: ObjectIdentifier) -> CoTerminal? {
        guard let id = args["terminal_id"] as? String else { return nil }
        return terminal(id: id, scope: scope)
    }
}
