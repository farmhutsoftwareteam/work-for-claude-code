import Foundation
import AppKit

enum Launcher {

    // Locate the claude binary at startup, checking common install paths
    static let claudeBinary: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? "claude"
    }()

    // Open a new Claude session in Terminal for the given project
    @discardableResult
    static func newSession(in project: Project) -> Bool {
        newSession(atPath: project.cwd)
    }

    /// Open a new Claude session in Terminal at a raw directory path — useful
    /// right after cloning a repo, before it's been ingested into the Store.
    /// Returns true if AppleScript reported success.
    @discardableResult
    static func newSession(atPath cwd: String) -> Bool {
        let cmd = "cd \(shellQuote(cwd)) && \(shellQuote(claudeBinary))"
        return runInTerminal(cmd)
    }

    // Smart resume: if the session is actively running, bring that exact Terminal
    // tab to the front. Fall back to opening a new resume if focus fails.
    @discardableResult
    static func resumeOrFocus(_ session: Session, in project: Project) -> Bool {
        if session.isActive,
           let pid = findActivePID(sessionId: session.id),
           let tty = ttyForPID(pid),
           focusTerminalTab(tty: tty) {
            return true
        }
        return resume(session, in: project)
    }

    // Resume an existing Claude session in Terminal (always opens a new tab)
    @discardableResult
    static func resume(_ session: Session, in project: Project) -> Bool {
        let cmd = "cd \(shellQuote(project.cwd)) && \(shellQuote(claudeBinary)) --resume \(shellQuote(session.id))"
        return runInTerminal(cmd)
    }

    // MARK: - Focus helpers

    // Find the OS PID for a running Claude session by scanning ~/.claude/sessions/
    private static func findActivePID(sessionId: String) -> Int32? {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return nil }

        let decoder = JSONDecoder()
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let s = try? decoder.decode(ActiveSessionFile.self, from: data),
                  s.sessionId == sessionId,
                  kill(Int32(s.pid), 0) == 0   // process still alive
            else { continue }
            return Int32(s.pid)
        }
        return nil
    }

    // Ask `ps` for the controlling TTY of a PID — returns e.g. "s003"
    private static func ttyForPID(_ pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-p", "\(pid)", "-o", "tty="]
        let outPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = Pipe()   // suppress error noise
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // "??" means no controlling terminal (background process / no tty)
        return (raw.isEmpty || raw == "??") ? nil : raw
    }

    // Use AppleScript to find the Terminal tab whose TTY matches and bring it front.
    // ps gives "s003"; Terminal.app's `tty of tab` gives "/dev/ttys003".
    // Returns true if a matching tab was found and activated.
    private static func focusTerminalTab(tty psOutput: String) -> Bool {
        let fullTTY = "/dev/tty\(psOutput)"
        let escaped = appleScriptSafe(fullTTY)

        let script = """
        tell application "Terminal"
            set didFocus to false
            repeat with w in windows
                repeat with t in tabs of w
                    if (tty of t) is equal to "\(escaped)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        set didFocus to true
                        exit repeat
                    end if
                end repeat
                if didFocus then exit repeat
            end repeat
            return didFocus
        end tell
        """

        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            print("[Work] focusTerminalTab error: \(error["NSAppleScriptErrorMessage"] ?? error)")
        }
        return error == nil && result.booleanValue
    }

    // MARK: - Private

    @discardableResult
    private static func runInTerminal(_ command: String) -> Bool {
        let sanitized = appleScriptSafe(command)

        let script = """
        tell application "Terminal"
            activate
            do script "\(sanitized)"
        end tell
        """

        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            appleScript.executeAndReturnError(&error)
        }

        if let error {
            let message = error["NSAppleScriptErrorMessage"] as? String
                ?? "An unknown error occurred."
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Could not open Terminal"
                alert.informativeText = """
                \(message)

                If Terminal automation was denied, go to:
                System Settings → Privacy & Security → Automation
                and enable Terminal for Atelier.
                """
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return false
        }
        return true
    }

    /// Escape a string for embedding inside an AppleScript `"..."` literal.
    /// AppleScript treats `\` and `"` specially. NUL truncates the literal.
    /// `\n` / `\r` / `\t` get their AppleScript escape forms so they survive
    /// the round-trip instead of being silently dropped (the previous
    /// implementation skipped all control characters, which meant a path
    /// containing a stray newline would be turned into garbage with no error).
    private static func appleScriptSafe(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\":      out.append("\\\\")
            case "\"":      out.append("\\\"")
            case "\n":      out.append("\\n")
            case "\r":      out.append("\\r")
            case "\t":      out.append("\\t")
            case "\u{0000}":
                // NUL terminates an AppleScript literal early; skip with no
                // attempt to escape. Real paths never contain NUL.
                continue
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    // Any other control character: skip rather than corrupt
                    // the script. Should never occur in well-formed cwd /
                    // command input.
                    continue
                }
                out.append(Character(scalar))
            }
        }
        return out
    }

    // Wrap a path in single quotes; escape embedded single quotes with the '\'' idiom
    private static func shellQuote(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
