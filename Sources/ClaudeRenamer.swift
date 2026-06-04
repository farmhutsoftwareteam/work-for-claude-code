import Foundation

/// Drives Claude Code's own rename via `claude --resume <id> --name <name> -p ""`.
///
/// `--name` writes a `{"type":"custom-title", ...}` line into the session's
/// JSONL on startup. With an empty `-p ""` prompt, Claude bails out before
/// hitting the API (the empty deferred prompt errors), so the rename costs
/// roughly nothing — no tokens, no model call, no extra Terminal window.
/// Work's tail-scanner reads the customTitle on the next refresh.
enum ClaudeRenamer {
    enum Error: Swift.Error, CustomStringConvertible {
        case binaryNotFound
        case timedOut
        case nonZeroExit(Int32, output: String)

        var description: String {
            switch self {
            case .binaryNotFound: return "claude CLI not found in PATH"
            case .timedOut: return "Rename timed out — Claude didn't respond"
            case .nonZeroExit(let code, let out):
                return "Claude exited with status \(code): \(out.prefix(200))"
            }
        }
    }

    /// Run `claude --resume <id> --name <name> -p ""` headlessly.
    /// Returns when Claude exits (typically <2s). The "no deferred tool marker"
    /// stderr is expected and treated as success — the rename has been written
    /// before that error fires.
    static func renameSession(id: String, in cwd: String, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let claudePath = try resolveClaudeBinary()

        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: claudePath)
            process.arguments = ["--resume", id, "--name", trimmed, "-p", ""]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            // Inherit user PATH/HOME so claude finds its own deps
            var env = ProcessInfo.processInfo.environment
            env["TERM"] = env["TERM"] ?? "xterm-256color"
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice

            try process.run()

            // Hard cap so a wedged claude can't block the UI forever
            let deadline = Date().addingTimeInterval(15)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            if process.isRunning {
                // SIGTERM first. Give it a short grace to exit cleanly; if it
                // ignores the signal (stuck in an uninterruptible syscall,
                // blocked on an input prompt, etc.) escalate to SIGKILL so we
                // don't leak the child forever.
                process.terminate()
                for _ in 0..<20 {  // up to 1s
                    if !process.isRunning { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
                throw Error.timedOut
            }

            let status = process.terminationStatus
            // Status 0 (rare here) and status 1 (the expected "no deferred tool"
            // exit after --name has been written) both mean the rename landed.
            // Anything else is unexpected — surface it.
            guard status == 0 || status == 1 else {
                let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                let errStr = String(data: errData, encoding: .utf8) ?? ""
                throw Error.nonZeroExit(status, output: errStr)
            }
        }.value
    }

    /// Find `claude` in the user's PATH. Falls back to the common install path
    /// since GUI apps don't inherit shell PATH.
    private static func resolveClaudeBinary() throws -> String {
        let candidates = [
            ("\(NSHomeDirectory())/.local/bin/claude"),
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw Error.binaryNotFound
    }
}
