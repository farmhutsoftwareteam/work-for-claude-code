// Headless discovery of the user's Supabase projects, so "connect Supabase"
// can offer a real picker instead of asking for a project_ref by hand.
//
// There's no way to list an MCP tool's results without an agentic turn —
// `claude mcp` only manages config (add/remove/list/login/logout); it has no
// "call this tool directly" command (confirmed via `claude mcp --help` and
// `claude mcp login --help` — login only takes a server NAME already in the
// persisted config, it doesn't accept an ad-hoc --mcp-config). So this spawns
// an ISOLATED, throwaway `claude -p` call against ONLY the account-wide
// (unscoped) Supabase MCP server, constrained to the exact JSON shape below
// via --json-schema, and reads the answer back from the CLI's own
// `structured_output` field — confirmed real via a live test call; it's the
// already-decoded object, NOT `result` (the same JSON double-encoded as a
// string).
//
// Credential-sharing caveat: `claude mcp login <name>` only authenticates a
// PERSISTED config entry — there's no way to sign in an ephemeral one
// directly. This reuses the exact name Claude Code gives the plugin's own
// server ("plugin:supabase:supabase") in its own --mcp-config file, betting
// that OAuth tokens are cached by server NAME (independent of which config
// source defined it) rather than by config file identity — the CLI's own
// `claude mcp logout <name>` / dynamic-client-registration-per-server
// language elsewhere points that way, but it's the one part of this design
// that needs a real signed-in run to fully confirm. If it's wrong, discovery
// fails with a clear auth error and the picker's retry loop recovers once
// the user has actually completed sign-in via V2McpPanel.authenticate.

import Foundation

struct SupabaseProject: Decodable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let organizationName: String?

    enum CodingKeys: String, CodingKey {
        case id, name
        case organizationName = "organization_name"
    }
}

enum SupabaseDiscoveryError: LocalizedError {
    case spawnFailed
    case timedOut
    case claudeError(String)
    case unparseable

    var errorDescription: String? {
        switch self {
        case .spawnFailed:
            return "Couldn't start claude."
        case .timedOut:
            return "Timed out waiting for your Supabase projects. Make sure you're signed in, then try again."
        case .claudeError(let message):
            return message
        case .unparseable:
            return "Got a response, but couldn't read a project list out of it."
        }
    }
}

enum SupabaseProjectDiscovery {
    /// The exact NAME the plugin's own manifest resolves to at runtime
    /// (system/init reports it as "plugin:supabase:supabase" — see
    /// V2McpPanel's real captured wire data). Matching it here is what makes
    /// the credential-sharing bet above possible.
    private static let serverName = "plugin:supabase:supabase"

    private static let unscopedConfigJSON = """
    {"mcpServers":{"\(serverName)":{"type":"http","url":"https://mcp.supabase.com/mcp"}}}
    """

    private static let prompt =
        "Call the list_projects tool and return every project you have access to. Do not call any other tool. Do not explain anything."

    private static let schema = """
    {"type":"object","properties":{"projects":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"name":{"type":"string"},"organization_name":{"type":"string"}},"required":["id","name"]}}},"required":["projects"]}
    """

    static func listProjects(claudeBinary: URL, timeoutSeconds: Double = 30) async throws -> [SupabaseProject] {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-supabase-discovery-\(UUID().uuidString).json")
        try unscopedConfigJSON.write(to: configURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: configURL) }

        let args = [
            "-p", prompt,
            "--mcp-config", configURL.path,
            "--strict-mcp-config",
            "--model", "haiku",
            "--output-format", "json",
            "--json-schema", schema,
            "--max-budget-usd", "0.10",
            "--no-session-persistence",
        ]

        guard let raw = await runWithTimeout(
            seconds: timeoutSeconds,
            executable: claudeBinary,
            args: args,
            cwd: FileManager.default.temporaryDirectory
        ) else {
            throw SupabaseDiscoveryError.timedOut
        }
        guard !raw.isEmpty else { throw SupabaseDiscoveryError.spawnFailed }

        guard let data = raw.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw SupabaseDiscoveryError.unparseable }

        if top["is_error"] as? Bool == true {
            let reason = (top["result"] as? String) ?? "claude reported an error."
            throw SupabaseDiscoveryError.claudeError(reason)
        }
        guard let structured = top["structured_output"] as? [String: Any],
              let projectsRaw = structured["projects"]
        else { throw SupabaseDiscoveryError.unparseable }

        let projectsData = try JSONSerialization.data(withJSONObject: projectsRaw)
        return try JSONDecoder().decode([SupabaseProject].self, from: projectsData)
    }

    /// V2Subprocess honours Task cancellation (SIGTERMs the child) but has
    /// no built-in wall-clock timeout — race it against a sleep so a hung
    /// probe can't leave the picker stuck on a spinner forever.
    private static func runWithTimeout(
        seconds: Double, executable: URL, args: [String], cwd: URL
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await V2Subprocess.runCollectingStdout(executable: executable, args: args, cwd: cwd)
                return result as String?
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
