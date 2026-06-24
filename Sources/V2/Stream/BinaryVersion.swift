// Resolve the user's `claude` binary location and version. Used at app
// launch to decide whether Mode-B is supported on this machine.

import Foundation

enum ClaudeBinary {
    /// Locate `claude` on the user's PATH. Tries common install locations
    /// first, then falls back to a `command -v claude` through their shell.
    static func locate() -> URL? {
        let fm = FileManager.default
        let candidates = [
            "\(NSHomeDirectory())/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(NSHomeDirectory())/.local/bin/claude"
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        // Fall back to the parent shell PATH.
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/bin/sh")
        which.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        do {
            try which.run()
            which.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !raw.isEmpty,
               fm.isExecutableFile(atPath: raw) {
                return URL(fileURLWithPath: raw)
            }
        } catch {
            // fall through
        }
        return nil
    }

    /// Run `claude --version` and parse semver. Returns nil if the binary
    /// fails to launch or the output is unparseable.
    static func version(at url: URL) -> SemVer? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let raw = String(data: data, encoding: .utf8) else { return nil }
            return SemVer.parse(raw)
        } catch {
            return nil
        }
    }

    /// Minimum supported version for Mode-B (the 10 MB stdin pipe cap landed
    /// in 2.1.128). Bump as we learn more from Phase 0 captures.
    static let minimumSupported = SemVer(major: 2, minor: 1, patch: 128)
}

struct SemVer: Comparable, Sendable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    /// Extract the first `MAJOR.MINOR.PATCH` from a freeform string
    /// (claude prints something like "claude-code v2.1.128 (build …)").
    static func parse(_ raw: String) -> SemVer? {
        let pattern = #"(\d+)\.(\d+)\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: raw,
                range: NSRange(raw.startIndex..., in: raw)
              ),
              let r1 = Range(match.range(at: 1), in: raw),
              let r2 = Range(match.range(at: 2), in: raw),
              let r3 = Range(match.range(at: 3), in: raw),
              let maj = Int(raw[r1]),
              let min = Int(raw[r2]),
              let pat = Int(raw[r3])
        else { return nil }
        return SemVer(major: maj, minor: min, patch: pat)
    }
}
