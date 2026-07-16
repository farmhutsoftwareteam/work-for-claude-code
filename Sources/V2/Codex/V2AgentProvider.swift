import Foundation

/// The agent runtime backing a native-chat tab. Claude keeps using its
/// stream-json process; Codex uses the local `codex app-server` process and
/// the account already managed by Codex (including ChatGPT subscription auth).
enum V2AgentProvider: String, Codable, CaseIterable, Identifiable {
    case claude
    case codex

    var id: String { rawValue }
    var displayName: String { self == .claude ? "Claude" : "Codex" }
}

struct CodexReasoningEffort: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let description: String
}

struct CodexModel: Identifiable, Equatable, Codable, Sendable {
    let id: String
    let model: String
    let displayName: String
    let description: String
    let isDefault: Bool
    let defaultReasoningEffort: String
    let supportedReasoningEfforts: [CodexReasoningEffort]
    let inputModalities: [String]
}

struct CodexAccount: Equatable, Sendable {
    let email: String?
    let planType: String?

    var label: String {
        if let planType, !planType.isEmpty { return "ChatGPT \(planType)" }
        return email ?? "ChatGPT"
    }
}

struct CodexMCPServer: Identifiable, Equatable, Sendable {
    let name: String
    let authStatus: String
    let toolCount: Int
    let resourceCount: Int
    var id: String { name }

    var needsLogin: Bool { authStatus == "notLoggedIn" }
}

enum CodexBinary {
    static func locate() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(NSHomeDirectory())/.npm-global/bin/codex"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-lc", "command -v codex"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard (try? process.run()) != nil,
              semaphore.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty,
              fm.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func version(at url: URL) -> SemVer? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        guard (try? process.run()) != nil,
              semaphore.wait(timeout: .now() + 2) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8).flatMap(SemVer.parse)
    }
}
