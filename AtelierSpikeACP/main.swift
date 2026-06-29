// AtelierSpikeACP — Phase 1 smoke test for the ACP migration.
//
// Compiles the SAME Sources/V2/ACP/ACPClient.swift the app will use, spawns
// claude-code-acp, runs initialize → session/new → session/prompt, and prints
// the streamed reply. Standalone CLI (type: tool) — does NOT launch the GUI
// app or a test host, so it can't disturb the running production app.
//
// Run:
//   xcodebuild -scheme AtelierSpikeACP -configuration Debug build
//   <build-dir>/AtelierSpikeACP /path/to/node /path/to/claude-code-acp/dist/index.js
//
// Args:
//   1: node binary path        (default: resolves via PATH)
//   2: claude-code-acp index.js path (required)
//   3: prompt text             (default: "Reply with exactly: ACP_OK")

import Foundation

func resolveNode(_ explicit: String?) -> URL? {
    if let explicit, FileManager.default.isExecutableFile(atPath: explicit) {
        return URL(fileURLWithPath: explicit)
    }
    for p in ["/opt/homebrew/bin/node", "/usr/local/bin/node",
              "\(NSHomeDirectory())/.nvm/current/bin/node"] {
        if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
    }
    // `which node` via login shell
    let which = Process()
    which.executableURL = URL(fileURLWithPath: "/bin/zsh")
    which.arguments = ["-lc", "which node"]
    let pipe = Pipe(); which.standardOutput = pipe
    try? which.run(); which.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return out.isEmpty ? nil : URL(fileURLWithPath: out)
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: AtelierSpikeACP <node> <claude-code-acp/dist/index.js> [prompt]\n".utf8))
    exit(64)
}
guard let node = resolveNode(args[1] == "-" ? nil : args[1]) else {
    FileHandle.standardError.write(Data("could not resolve node\n".utf8))
    exit(69)
}
let acpIndex = URL(fileURLWithPath: args[2])
let promptText = args.count >= 4 ? args[3] : "Reply with exactly: ACP_OK"

let client = ACPClient()
var replyBuffer = ""

client.onModels = { models in
    print("MODELS: " + models.map { $0.id }.joined(separator: ", "))
}
client.onAgentText = { chunk in
    replyBuffer += chunk
    FileHandle.standardOutput.write(Data(chunk.utf8))
}
client.onAgentThought = { _ in print("[thinking…]") }
client.onError = { err in
    FileHandle.standardError.write(Data("ERROR: \(err)\n".utf8))
    exit(1)
}
client.onTurnEnd = { reason in
    print("\n--- turn end: \(reason) ---")
    let ok = replyBuffer.contains("ACP_OK") || !replyBuffer.isEmpty
    print(ok ? "✓ ACP round-trip OK" : "✗ no reply text received")
    client.stop()
    exit(ok ? 0 : 2)
}

print("spawning claude-code-acp via \(node.path)…")
client.start(nodeURL: node, acpIndexJS: acpIndex, cwd: URL(fileURLWithPath: "/tmp")) { connected in
    guard connected else {
        FileHandle.standardError.write(Data("failed to connect / create session\n".utf8))
        exit(1)
    }
    print("session ready: \(client.sessionId ?? "?") — sending prompt")
    client.prompt(promptText)
}

// Keep the CLI alive while async stdio runs; exits via onTurnEnd / onError.
RunLoop.main.run(until: Date().addingTimeInterval(90))
FileHandle.standardError.write(Data("timeout\n".utf8))
exit(3)
