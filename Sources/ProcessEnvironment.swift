import Foundation

/// Environment used by agent subprocesses launched from the GUI app. Apps
/// started by LaunchServices inherit a minimal PATH, which otherwise prevents
/// Codex/Claude and their stdio MCP servers from finding node, npx, uv, or git.
enum AtelierProcessEnvironment {
    static func enriched(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        let home = environment["HOME"] ?? NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]
        let basePath = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = Set(basePath.split(separator: ":").map(String.init))
        let additions = candidates.filter {
            FileManager.default.fileExists(atPath: $0) && !existing.contains($0)
        }
        environment["PATH"] = (additions + [basePath]).joined(separator: ":")
        environment["HOME"] = home
        if environment["USER"] == nil { environment["USER"] = NSUserName() }
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        return environment
    }
}
