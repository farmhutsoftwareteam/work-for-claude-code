import Foundation

/// A curated, one-click MCP server. The gold-standard install UX (Claude
/// Desktop Extensions) is a built-in directory of popular servers you add
/// without hunting GitHub or hand-writing a command — this is the local,
/// offline version of that, above the (thin) official registry. Each preset is
/// a ready `MCPDraft`; "add" drops it straight into the editor prefilled, so
/// the user reviews (and, per stage 3, can test) rather than types `npx …`.
struct MCPPreset: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let draft: MCPDraft

    var remote: Bool {
        switch draft.transport {
        case .http, .sse: return true
        default:          return false
        }
    }

    private static func stdio(_ id: String, _ title: String, _ subtitle: String,
                              _ command: String, _ args: [String]) -> MCPPreset {
        MCPPreset(id: id, title: title, subtitle: subtitle,
                  draft: MCPDraft(name: id, transport: .stdio(command: command, args: args)))
    }

    private static func remote(_ id: String, _ title: String, _ subtitle: String,
                               _ url: String) -> MCPPreset {
        MCPPreset(id: id, title: title, subtitle: subtitle,
                  draft: MCPDraft(name: id, transport: .http(url: url)))
    }

    /// Kept conservative on purpose — every entry is a well-known server with a
    /// template I'm confident about (the official `@modelcontextprotocol/*` and
    /// `mcp-server-*` servers, plus a few widely-used remotes). A slightly-off
    /// template still lands in the editor for review + the stage-3 test, but
    /// the point of a preset is that it's right, so this list only grows with
    /// entries that are verified, not guessed.
    static let catalog: [MCPPreset] = [
        stdio("filesystem", "Filesystem",
              "Read & write files in a directory you choose (edit the path after adding).",
              "npx", ["-y", "@modelcontextprotocol/server-filesystem", NSHomeDirectory()]),
        stdio("git", "Git",
              "Inspect and operate on a local git repository.",
              "uvx", ["mcp-server-git"]),
        stdio("fetch", "Fetch",
              "Fetch a URL and hand its contents to the model.",
              "uvx", ["mcp-server-fetch"]),
        stdio("memory", "Memory",
              "A knowledge graph the model can remember across turns.",
              "npx", ["-y", "@modelcontextprotocol/server-memory"]),
        stdio("sequential-thinking", "Sequential Thinking",
              "A step-by-step structured-reasoning scratchpad.",
              "npx", ["-y", "@modelcontextprotocol/server-sequential-thinking"]),
        stdio("time", "Time",
              "Current time and timezone conversions.",
              "uvx", ["mcp-server-time"]),
        stdio("playwright", "Playwright",
              "Drive a real browser — navigate, click, screenshot, extract.",
              "npx", ["-y", "@playwright/mcp@latest"]),
        stdio("context7", "Context7",
              "Up-to-date library documentation, fetched on demand.",
              "npx", ["-y", "@upstash/context7-mcp"]),
        remote("github", "GitHub",
               "Issues, PRs, and code search. Signs in with your GitHub account.",
               "https://api.githubcopilot.com/mcp/"),
    ]
}
