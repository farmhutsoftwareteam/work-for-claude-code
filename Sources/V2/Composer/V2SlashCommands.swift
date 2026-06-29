// Slash-command catalog + filtering for the composer popover.
// Matches the design in Atelier app.dc.html. For the shipping StreamSession
// path this is a curated static list of Claude Code's built-in commands;
// when the ACP cutover lands, ACPSession.commands (from the agent's
// available_commands_update) can replace it.

import Foundation

struct V2SlashCommand: Identifiable, Equatable {
    let name: String
    let desc: String
    var id: String { name }
}

enum V2SlashCatalog {
    static let all: [V2SlashCommand] = [
        .init(name: "clear",         desc: "Clear the conversation history"),
        .init(name: "compact",       desc: "Summarise context and compress tokens"),
        .init(name: "cost",          desc: "Show token + cost breakdown for this session"),
        .init(name: "doctor",        desc: "Check environment and surface any issues"),
        .init(name: "help",          desc: "List all available commands"),
        .init(name: "init",          desc: "Initialise CLAUDE.md in this project"),
        .init(name: "login",         desc: "Authenticate with Anthropic"),
        .init(name: "logout",        desc: "Sign out of the current account"),
        .init(name: "memory",        desc: "Edit persistent memory files"),
        .init(name: "model",         desc: "Switch the active Claude model"),
        .init(name: "permissions",   desc: "View and edit tool permission rules"),
        .init(name: "pr_comments",   desc: "Fetch and review open PR comments"),
        .init(name: "release-notes", desc: "Show what changed in the latest release"),
        .init(name: "review",        desc: "Request a code review on staged changes"),
        .init(name: "status",        desc: "Show running agents and loop state"),
        .init(name: "terminal",      desc: "Drop into a raw terminal session"),
        .init(name: "vim",           desc: "Open a file in vim inside the session"),
    ]

    /// Commands whose name has `query` (the text after the leading `/`) as a
    /// prefix, capped at 8 — matching the design's slice(0, 8).
    static func filtered(_ query: String) -> [V2SlashCommand] {
        let q = query.lowercased()
        return all.filter { $0.name.hasPrefix(q) }.prefix(8).map { $0 }
    }
}
