// AtelierSpike — Phase 0 protocol validation for issue #9.
//
// Spawns `claude` with the full Mode-B flag set, parses each NDJSON event off
// stdout, sends one synthetic user turn over stdin, and tees both streams to
// /tmp for replay as parser fixtures.
//
// Run from Xcode (AtelierSpike scheme) or:
//   xcodebuild -scheme AtelierSpike build && \
//   $(xcodebuild -scheme AtelierSpike -showBuildSettings | awk '/CONFIGURATION_BUILD_DIR/{print $3}')/AtelierSpike
//
// Goals of the spike:
//   - confirm the spawn flags work as documented
//   - capture init / stream_event / tool_use / result / control_request shapes
//   - empirically resolve the open questions on issue #9

import Foundation

// MARK: - Locate the binary

func findClaude() -> URL? {
    let candidates = [
        "\(NSHomeDirectory())/.claude/local/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude"
    ]
    let fm = FileManager.default
    for path in candidates where fm.isExecutableFile(atPath: path) {
        return URL(fileURLWithPath: path)
    }
    // Fall back to `which claude` against the parent shell PATH.
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
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           fm.isExecutableFile(atPath: raw) {
            return URL(fileURLWithPath: raw)
        }
    } catch {
        // fall through
    }
    return nil
}

// MARK: - Capture files

func openCapture(at path: String) -> FileHandle {
    let fm = FileManager.default
    if !fm.fileExists(atPath: path) {
        fm.createFile(atPath: path, contents: nil)
    } else {
        // Truncate prior contents — every spike run starts fresh.
        try? Data().write(to: URL(fileURLWithPath: path))
    }
    return FileHandle(forUpdatingAtPath: path)!
}

// MARK: - Main

guard let claudeURL = findClaude() else {
    FileHandle.standardError.write(Data("AtelierSpike: can't find `claude` on PATH or in ~/.claude/local\n".utf8))
    exit(1)
}

// Don't let a broken pipe (claude exits early) kill us.
signal(SIGPIPE, SIG_IGN)

let outCapture = openCapture(at: "/tmp/atelier-spike-out.ndjson")
let inCapture  = openCapture(at: "/tmp/atelier-spike-in.ndjson")
let errCapture = openCapture(at: "/tmp/atelier-spike-stderr.log")

print("→ binary: \(claudeURL.path)")
print("→ stdout capture: /tmp/atelier-spike-out.ndjson")
print("→ stdin  capture: /tmp/atelier-spike-in.ndjson")
print()

let process = Process()
process.executableURL = claudeURL
process.arguments = [
    "-p",
    "--output-format", "stream-json",
    "--input-format", "stream-json",
    "--include-partial-messages",
    "--verbose"
]
process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

let stdin  = Pipe()
let stdout = Pipe()
let stderr = Pipe()
process.standardInput  = stdin
process.standardOutput = stdout
process.standardError  = stderr

// Drain stdout async — tee to capture file + pretty-print to console.
stdout.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    outCapture.write(data)
    if let str = String(data: data, encoding: .utf8) {
        // Per-line print so it's readable even when claude emits multiple
        // events per chunk.
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            print("← \(line)")
        }
    }
}

stderr.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    guard !data.isEmpty else { return }
    errCapture.write(data)
    if let str = String(data: data, encoding: .utf8) {
        for line in str.split(separator: "\n", omittingEmptySubsequences: true) {
            print("⚠ \(line)")
        }
    }
}

do {
    try process.run()
} catch {
    FileHandle.standardError.write(Data("AtelierSpike: failed to spawn claude: \(error)\n".utf8))
    exit(1)
}

print("spawned pid \(process.processIdentifier)")
print()

// Give claude a moment to emit `system/init` before we send a turn.
DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
    let userTurn = #"{"type":"user","message":{"role":"user","content":"hi — please reply with only the word ready"}}"#
    let line = userTurn + "\n"
    let data = Data(line.utf8)
    do {
        try stdin.fileHandleForWriting.write(contentsOf: data)
        inCapture.write(data)
        print("→ \(userTurn)")
    } catch {
        FileHandle.standardError.write(Data("AtelierSpike: stdin write failed: \(error)\n".utf8))
    }
}

// Run for ~30 seconds then close stdin cleanly and exit.
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    try? stdin.fileHandleForWriting.close()
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
        process.terminate()
    }
}

process.waitUntilExit()

print()
print("exit code: \(process.terminationStatus)")
print("captures saved to /tmp/atelier-spike-*.ndjson")
