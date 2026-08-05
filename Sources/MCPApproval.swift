import Foundation

/// Project-scoped MCP servers (declared in a repo's `.mcp.json`) are gated
/// behind a one-time **approval** — Claude won't run one until you've said you
/// trust it, since a cloned repo could ship a malicious server. That approval
/// lives per-project in `~/.claude.json` as `enabledMcpjsonServers` (or the
/// blanket `enableAllProjectMcpServers`, also settable in a project's
/// `.claude/settings*.json`). Atelier previously had no concept of this and
/// mis-surfaced it as a sign-in error ("expo … sign in to retry"), which can
/// never fix it. This reads the approval state and can grant it — turning a
/// pending server into a one-click "Approve & reconnect".
enum MCPApproval {

    struct State: Equatable {
        var enableAll: Bool
        var enabled: Set<String>
        var disabled: Set<String>
    }

    /// Which of `names` (a project's `.mcp.json` servers) are still pending —
    /// i.e. not yet approved for `cwd`, so Claude refuses to run them.
    static func pending(cwd: String, names: [String]) -> Set<String> {
        guard !names.isEmpty else { return [] }
        let s = state(cwd: cwd)
        if s.enableAll { return [] }
        return Set(names).subtracting(s.enabled)
    }

    /// The effective approval state for `cwd`, unioned across the project's
    /// `.claude/settings{.local}.json` and `~/.claude.json → projects.<cwd>`
    /// (Claude reads all of these).
    static func state(cwd: String) -> State {
        var enableAll = false
        var enabled: Set<String> = []
        var disabled: Set<String> = []
        func absorb(_ obj: [String: Any]?) {
            guard let obj else { return }
            if obj["enableAllProjectMcpServers"] as? Bool == true { enableAll = true }
            if let e = obj["enabledMcpjsonServers"] as? [String] { enabled.formUnion(e) }
            if let d = obj["disabledMcpjsonServers"] as? [String] { disabled.formUnion(d) }
        }
        for rel in [".claude/settings.local.json", ".claude/settings.json"] {
            absorb(json(URL(fileURLWithPath: cwd).appendingPathComponent(rel)))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        if let root = json(home),
           let projects = root["projects"] as? [String: Any],
           let entry = projects[cwd] as? [String: Any] {
            absorb(entry)
        }
        return State(enableAll: enableAll, enabled: enabled, disabled: disabled)
    }

    enum ApprovalError: LocalizedError {
        case unreadable
        var errorDescription: String? { "Couldn't read ~/.claude.json to record the approval." }
    }

    /// Grant approval for one project server by adding it to
    /// `~/.claude.json → projects.<cwd>.enabledMcpjsonServers` (where Claude
    /// keeps per-project approval), read-modify-write, preserving everything
    /// else — the same pattern the app already uses to record project trust.
    static func approve(cwd: String, server: String) throws {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ApprovalError.unreadable
        }
        var projects = (root["projects"] as? [String: Any]) ?? [:]
        var entry = (projects[cwd] as? [String: Any]) ?? ["hasTrustDialogAccepted": true]

        var enabled = (entry["enabledMcpjsonServers"] as? [String]) ?? []
        if !enabled.contains(server) { enabled.append(server) }
        entry["enabledMcpjsonServers"] = enabled

        // If it was explicitly disabled, lift that — approving is the stronger
        // intent and Claude treats disabled as a veto.
        if var disabled = entry["disabledMcpjsonServers"] as? [String], disabled.contains(server) {
            disabled.removeAll { $0 == server }
            entry["disabledMcpjsonServers"] = disabled
        }

        projects[cwd] = entry
        root["projects"] = projects
        let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
        try out.write(to: url, options: .atomic)
    }

    private static func json(_ url: URL) -> [String: Any]? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}
