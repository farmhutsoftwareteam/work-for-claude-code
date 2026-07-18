// Claude has no app-server RPC for auth the way Codex does (verified
// 2026-07-18: no get_usage-style control_request for login). Its real auth
// surface is two plain CLI commands, confirmed live against the actual
// binary in an isolated CLAUDE_CONFIG_DIR sandbox so the probe never
// touched this machine's real logged-in session:
//
//   `claude auth status --json` → {"loggedIn": bool, "email", "subscriptionType", …}
//     cheap, instant, no side effects.
//
//   `claude auth login --claudeai` → prints "Opening browser to sign in…
//     If the browser didn't open, visit: https://…" then blocks on stdin
//     with "Paste code here if prompted >". Structurally the same shape as
//     Codex's login (open a URL, collect a code, feed it back) — just a
//     stdin paste instead of an app-server round trip.
//
// Before this, Atelier had no way to distinguish "not authenticated" from
// any other spawn failure — a fresh, never-logged-in user just saw
// whatever cryptic error fell out of a failed `claude -p` launch.

import Foundation
import AppKit
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "claude-auth")

@MainActor
final class ClaudeAuthManager: ObservableObject {
    enum Status: Equatable {
        case unknown
        case checking
        case loggedIn(email: String?, plan: String?)
        case loggedOut
        /// The status check ITSELF failed (corrupt binary, unreadable
        /// output) — distinct from .loggedOut so the UI can say what's
        /// actually wrong instead of offering a sign-in that will fail
        /// the identical way.
        case checkFailed(String)
    }

    enum LoginState: Equatable {
        case idle
        case waitingForURL
        case awaitingCode(url: URL)
        case submitting
        case failed(String)
    }

    @Published private(set) var status: Status = .unknown
    @Published private(set) var loginState: LoginState = .idle

    private var loginProcess: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var watchdog: Task<Void, Never>?

    func checkStatus(binary: URL) async {
        status = .checking
        let output = await V2Subprocess.runCollectingStdout(
            executable: binary,
            args: ["auth", "status", "--json"],
            cwd: FileManager.default.homeDirectoryForCurrentUser
        )
        status = Self.parseStatus(output)
        if case .checkFailed = status {
            log.error("claude auth status did not return parseable JSON")
        }
    }

    /// Pure parse of `claude auth status --json`'s stdout — real captured
    /// shape (2026-07-18): {"loggedIn": bool, "authMethod", "apiProvider",
    /// "email", "orgId", "orgName", "subscriptionType"}. Factored out so
    /// the JSON contract is unit-testable without spawning a real process.
    static func parseStatus(_ output: String) -> Status {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return .checkFailed("Couldn't read Claude's sign-in status.")
        }
        if json["loggedIn"] as? Bool == true {
            return .loggedIn(email: json["email"] as? String, plan: json["subscriptionType"] as? String)
        }
        return .loggedOut
    }

    /// Pure extraction of the auth URL from accumulated stdout. Matches
    /// any https URL rather than parsing the CLI's exact sentence — its
    /// wording ("If the browser didn't open, visit: …") isn't a stable
    /// contract, but it reliably prints exactly one https URL either way.
    ///
    /// The trailing `(?=\s)` lookahead is load-bearing, not decorative:
    /// stdout arrives in whatever chunks the pipe delivers, and this is
    /// re-run on the full accumulated buffer on every chunk. Without it, a
    /// chunk boundary landing mid-URL (e.g. buffer ends "…visit: https://
    /// claude.c" before the rest has arrived) would greedily match and
    /// open a truncated, broken URL immediately — found by writing the
    /// test for this, not by inspection.
    static func extractLoginURL(from buffer: String) -> URL? {
        guard let range = buffer.range(of: #"https://\S+(?=\s)"#, options: .regularExpression) else { return nil }
        return URL(string: String(buffer[range]))
    }

    /// Spawns `claude auth login`, watches stdout for the real auth URL
    /// (regex — the CLI's own wording isn't a stable contract, matching
    /// any https URL in its output is), and opens it. `submitCode` feeds
    /// the pasted code back over the same process's stdin.
    func beginLogin(binary: URL) {
        guard loginProcess == nil else { return }
        loginState = .waitingForURL
        stdoutBuffer = ""
        stderrBuffer = ""

        let process = Process()
        process.executableURL = binary
        process.arguments = ["auth", "login", "--claudeai"]
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.handleStdout(text) }
        }
        // Drained even though we don't surface it live — an undrained
        // stderr pipe deadlocks the child once its ~64KB buffer fills
        // (the exact bug V2Subprocess's header comment documents), and
        // its content becomes the real reason on a failed exit.
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty, let text = String(data: chunk, encoding: .utf8) else { return }
            Task { @MainActor [weak self] in self?.stderrBuffer += text }
        }
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in self?.handleExit(status: proc.terminationStatus) }
        }

        loginProcess = process
        stdinPipe = stdin
        stdoutPipe = stdout
        stderrPipe = stderr

        do {
            try process.run()
        } catch {
            log.error("claude auth login spawn failed: \(error.localizedDescription, privacy: .public)")
            loginState = .failed("Couldn't start Claude sign-in: \(error.localizedDescription)")
            cleanup()
            return
        }
        armWatchdog(seconds: 15) { [weak self] in
            guard let self, case .waitingForURL = self.loginState else { return }
            self.loginState = .failed("Claude sign-in didn't respond — check your connection and try again.")
            self.cancelLogin()
        }
    }

    private func handleStdout(_ text: String) {
        stdoutBuffer += text
        guard case .waitingForURL = loginState, let url = Self.extractLoginURL(from: stdoutBuffer) else { return }
        watchdog?.cancel()
        loginState = .awaitingCode(url: url)
        NSWorkspace.shared.open(url)
    }

    func submitCode(_ code: String) {
        guard case .awaitingCode = loginState, let stdinPipe else { return }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = (trimmed + "\n").data(using: .utf8) else { return }
        loginState = .submitting
        do {
            try stdinPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            log.error("writing auth code to claude auth login failed: \(error.localizedDescription, privacy: .public)")
            loginState = .failed("Couldn't submit that code: \(error.localizedDescription)")
            cancelLogin()
            return
        }
        // A rejected code doesn't always make the CLI exit promptly —
        // bound the wait rather than let a bad paste hang the sheet open
        // forever with no feedback.
        armWatchdog(seconds: 20) { [weak self] in
            guard let self, case .submitting = self.loginState else { return }
            self.loginState = .failed("That didn't complete — check the code and try again.")
            self.cancelLogin()
        }
    }

    func cancelLogin() {
        watchdog?.cancel()
        loginProcess?.terminate()
        cleanup()
        loginState = .idle
    }

    private func handleExit(status exitStatus: Int32) {
        watchdog?.cancel()
        let wasSubmitting = loginState == .submitting
        cleanup()
        if exitStatus == 0 {
            loginState = .idle
        } else if wasSubmitting {
            let detail = stderrBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            loginState = .failed(detail.isEmpty ? "Sign-in failed — the code may have been wrong or expired." : detail)
        } else {
            loginState = .failed("Claude sign-in exited unexpectedly.")
        }
    }

    private func armWatchdog(seconds: TimeInterval, _ onTimeout: @escaping () -> Void) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard self != nil, !Task.isCancelled else { return }
            onTimeout()
        }
    }

    private func cleanup() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        loginProcess = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }
}
