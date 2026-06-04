import Foundation

// MARK: - Auto PATH fix for native Claude installs
//
// Anthropic's native installer drops `claude` at `~/.local/bin/claude`.
// macOS users almost always have `~/.local/bin` missing from their shell
// PATH, so Claude Code prints a setup hint at startup. Work can detect
// this and offer to fix it in one click — append the export line to the
// user's shell rc file, idempotent, never destructive.

enum PathFixer {

    /// Anthropic's documented native install location.
    private static var claudeNativePath: String {
        "\(NSHomeDirectory())/.local/bin/claude"
    }

    /// True when:
    ///   • Claude is installed natively at `~/.local/bin/claude`
    ///   • AND the user's shell rc file doesn't already mention `~/.local/bin`
    ///
    /// We deliberately read the rc file directly rather than checking the
    /// process environment, because GUI apps inherit launchd's environment
    /// (which usually doesn't include the user's shell PATH at all).
    static func needsFix() -> Bool {
        guard FileManager.default.fileExists(atPath: claudeNativePath) else {
            return false
        }
        return !rcFileMentionsLocalBin(configURL: detectShellConfig())
    }

    /// Resolve the right rc file for the user's login shell. Falls back to
    /// `~/.zshrc` when the shell can't be classified.
    static func detectShellConfig() -> URL {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fm = FileManager.default

        if shell.hasSuffix("/zsh") {
            return home.appendingPathComponent(".zshrc")
        }
        if shell.hasSuffix("/bash") {
            // macOS bash users typically use .bash_profile (login shell).
            // Some setups source .bashrc from there. Prefer .bash_profile if
            // present; otherwise create .bashrc.
            let profile = home.appendingPathComponent(".bash_profile")
            if fm.fileExists(atPath: profile.path) { return profile }
            return home.appendingPathComponent(".bashrc")
        }
        if shell.hasSuffix("/fish") {
            return home.appendingPathComponent(".config/fish/config.fish")
        }
        return home.appendingPathComponent(".zshrc")
    }

    /// Have we already (somehow) added `~/.local/bin` to this rc file?
    /// Either via Work's previous run, the user themselves, an installer,
    /// or another tool — any reference is enough to skip.
    private static func rcFileMentionsLocalBin(configURL: URL) -> Bool {
        guard let content = try? String(contentsOf: configURL, encoding: .utf8) else {
            // File doesn't exist yet → definitely doesn't mention it
            return false
        }
        return content.contains("/.local/bin")
    }

    /// Append the export line to the shell rc file. Atomically creates the
    /// file if missing. Returns the URL we wrote to so callers can show it
    /// to the user.
    @discardableResult
    static func applyFix() throws -> URL {
        let configURL = detectShellConfig()
        let isFish = configURL.path.contains("/fish/")

        let exportLine = isFish
            ? #"set -gx PATH $HOME/.local/bin $PATH"#
            : #"export PATH="$HOME/.local/bin:$PATH""#
        let header = "\n# Added by Work — make `claude` available from any terminal\n"
        let toAppend = header + exportLine + "\n"

        let fm = FileManager.default

        // Make sure the parent directory exists (matters for fish: ~/.config/fish/)
        let parent = configURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        // Create empty file if needed
        if !fm.fileExists(atPath: configURL.path) {
            try Data().write(to: configURL, options: .atomic)
        }

        // Append (never overwrite). Use FileHandle so we don't accidentally
        // rewrite the whole file.
        let handle = try FileHandle(forWritingTo: configURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        if let data = toAppend.data(using: .utf8) {
            try handle.write(contentsOf: data)
        }

        return configURL
    }
}
