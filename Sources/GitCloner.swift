import Foundation

// MARK: - Clone a Git repo into a local directory
//
// Shells out to `git clone`, streaming output line-by-line so the UI can show
// progress. Relies on whatever git + credential setup the user already has
// (SSH keys, Keychain helper, GitHub CLI auth). We don't try to substitute
// for those — if git fails, we surface the error verbatim.

struct CloneDestination: Hashable {
    let url: URL
    let displayName: String   // e.g. "foo-app"
}

enum GitClonerError: LocalizedError {
    case invalidURL(String)
    case gitNotFound
    case cloneFailed(status: Int32, output: String)
    case destinationExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):                  return "Couldn't parse \(raw) as a Git URL."
        case .gitNotFound:                          return "git not found in PATH. Install via Xcode Command Line Tools or Homebrew."
        case .cloneFailed(let status, let output):
            let snippet = output.split(separator: "\n").suffix(6).joined(separator: "\n")
            return "git clone exited with status \(status).\n\n\(snippet)"
        case .destinationExists(let at):            return "A folder already exists at \(at.path). Pick a different name or delete the existing one first."
        }
    }
}

enum GitCloner {

    // MARK: - URL parsing

    /// Expand common shorthand + normalize various Git URL forms into a canonical
    /// HTTPS URL and a default display name. Accepts:
    ///   - https://github.com/foo/bar
    ///   - https://github.com/foo/bar.git
    ///   - git@github.com:foo/bar.git
    ///   - foo/bar            (assumed GitHub shorthand)
    ///   - https://gitlab.com/foo/bar, etc. (passed through unchanged except .git stripping for name)
    static func parse(_ raw: String) -> (gitURL: String, defaultName: String)? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // git@host:owner/repo(.git)
        if trimmed.hasPrefix("git@") {
            let parts = trimmed.components(separatedBy: ":")
            guard parts.count == 2 else { return nil }
            let name = (parts[1] as NSString).lastPathComponent.replacingOccurrences(of: ".git", with: "")
            return (trimmed, name)
        }

        // https://host/owner/repo(.git)  or  http://
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") {
            guard let u = URL(string: trimmed) else { return nil }
            let name = u.lastPathComponent.replacingOccurrences(of: ".git", with: "")
            guard !name.isEmpty else { return nil }
            return (trimmed, name)
        }

        // owner/repo  — shorthand, assume GitHub
        let shorthand = trimmed.trimmingCharacters(in: .init(charactersIn: "/"))
        let parts = shorthand.split(separator: "/")
        if parts.count == 2 {
            let name = String(parts[1]).replacingOccurrences(of: ".git", with: "")
            return ("https://github.com/\(shorthand)", name)
        }

        return nil
    }

    // MARK: - Clone

    /// Perform the clone. Returns the final URL on disk. `onOutput` is called
    /// from a background thread with each line of git's stdout/stderr as it
    /// arrives — suitable for streaming into a UI log.
    static func clone(
        sourceURL: String,
        destinationParent: URL,
        folderName: String,
        onOutput: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let gitPath = try resolveGitBinary()

        let dest = destinationParent.appendingPathComponent(folderName)
        if FileManager.default.fileExists(atPath: dest.path) {
            throw GitClonerError.destinationExists(dest)
        }

        try FileManager.default.createDirectory(at: destinationParent, withIntermediateDirectories: true)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gitPath)
        proc.arguments = ["clone", "--progress", sourceURL, dest.path]
        proc.standardInput = FileHandle.nullDevice

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Keep env so credential helpers + SSH keys work
        var env = ProcessInfo.processInfo.environment
        // Disable any interactive prompt — if auth is missing, fail fast
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "true"   // echo empty passphrase / cancel
        proc.environment = env

        let buffer = OutputBuffer()

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let text = String(data: data, encoding: .utf8) {
                let accum = buffer.append(text)
                for line in accum.newCompletedLines {
                    onOutput(line)
                }
            }
        }

        try proc.run()

        // Wait off the main actor
        await Task.detached(priority: .utility) {
            proc.waitUntilExit()
        }.value

        pipe.fileHandleForReading.readabilityHandler = nil
        if let leftover = buffer.flushRemaining() {
            onOutput(leftover)
        }

        let output = buffer.combined
        if proc.terminationStatus != 0 {
            throw GitClonerError.cloneFailed(status: proc.terminationStatus, output: output)
        }
        return dest
    }

    // MARK: - Helpers

    private static func resolveGitBinary() throws -> String {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) {
            return p
        }
        throw GitClonerError.gitNotFound
    }

    /// Buffered line splitter — git emits partial lines when streaming progress.
    /// We hold onto the tail and only emit complete lines.
    private final class OutputBuffer: @unchecked Sendable {
        private var tail = ""
        private var collected = ""
        private let lock = NSLock()

        var combined: String {
            lock.lock(); defer { lock.unlock() }
            return collected + tail
        }

        struct Append {
            let newCompletedLines: [String]
        }

        func append(_ text: String) -> Append {
            lock.lock(); defer { lock.unlock() }
            collected += text
            tail += text
            // Split on both \n and \r (git emits \r for progress bar updates)
            var completed: [String] = []
            let chars = Array(tail)
            var start = 0
            var i = 0
            while i < chars.count {
                if chars[i] == "\n" || chars[i] == "\r" {
                    let line = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
                    if !line.isEmpty { completed.append(line) }
                    start = i + 1
                }
                i += 1
            }
            tail = String(chars[start..<chars.count])
            return Append(newCompletedLines: completed)
        }

        func flushRemaining() -> String? {
            lock.lock(); defer { lock.unlock() }
            let leftover = tail.trimmingCharacters(in: .whitespaces)
            tail = ""
            return leftover.isEmpty ? nil : leftover
        }
    }
}
