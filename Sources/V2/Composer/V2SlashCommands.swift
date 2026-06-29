// Slash-command model for the composer palette.
//
// The key fact this models: slash commands are a *client* feature, not a
// model feature. The terminal CLI handles most of them locally and never
// sends them to Claude. So each command declares HOW it runs:
//
//   • .client(action)  — Atelier executes it in-app (clear, model, cost,
//                          permissions, help, compact). The agent never
//                          sees these.
//   • .prompt(body)    — a prompt template that IS sent to the agent, with
//                          $ARGUMENTS / $1… expanded first. Covers built-in
//                          prompt commands (/init, /review) and every custom
//                          command the user has authored under
//                          .claude/commands or ~/.claude/commands.
//
// When the ACP cutover lands, the agent's own available_commands_update can
// feed this same model — the UI doesn't change, only the source of truth.

import Foundation

// MARK: - Category (popover section)

enum V2SlashCategory: String, CaseIterable {
    case session = "SESSION"
    case context = "CONTEXT"
    case model   = "MODEL"
    case project = "PROJECT"
    case help    = "HELP"

    /// Display order in the palette.
    var rank: Int {
        switch self {
        case .session: return 0
        case .context: return 1
        case .model:   return 2
        case .project: return 3
        case .help:    return 4
        }
    }
}

// MARK: - Client actions (handled in-app, never sent to the agent)

enum V2ClientCommand: String, Equatable {
    case clear        // reset the conversation (fresh context)
    case cost         // show tokens + cost for this session
    case model        // switch the active model
    case permissions  // change the permission mode
    case mcp          // open the MCP servers dock panel
    case agents       // open the subagents dock panel
    case help         // list everything available here
}

// MARK: - How a command runs

enum V2SlashKind: Equatable {
    /// Atelier executes this itself. The model never sees it.
    case client(V2ClientCommand)
    /// A prompt template sent to the agent after $ARGUMENTS expansion.
    /// `source` is a short provenance label for the palette ("built-in",
    /// "project", "user").
    case prompt(body: String, source: String)

    var isClient: Bool { if case .client = self { return true }; return false }
}

// MARK: - Command

struct V2SlashCommand: Identifiable, Equatable {
    /// Includes any namespace, e.g. "frontend:component".
    let name: String
    let desc: String
    let category: V2SlashCategory
    let kind: V2SlashKind
    /// Hint shown in faint after the name when the command takes arguments,
    /// e.g. "<file>" or "[focus]". nil ⇒ no arguments.
    let argumentHint: String?

    var id: String { name }
    var takesArguments: Bool { argumentHint != nil }

    /// A tiny right-aligned tag describing where this runs, so the palette
    /// teaches the client/agent split at a glance.
    var runTag: String {
        switch kind {
        case .client:           return "app"
        case .prompt(_, let s): return s == "built-in" ? "→ agent" : s
        }
    }
}

// MARK: - Built-in catalog

enum V2SlashCatalog {

    /// Commands Atelier ships itself. Custom commands from disk are merged in
    /// by V2CommandRegistry; this is just the curated, always-present set.
    ///
    /// Deliberately small and honest: only commands that genuinely do
    /// something on the shipping StreamSession path. /init and /review are
    /// prompt commands in real Claude Code too, so they're faithful sends.
    static let builtins: [V2SlashCommand] = [
        .init(name: "clear",
              desc: "Clear this conversation",
              category: .session,
              kind: .client(.clear),
              argumentHint: nil),
        .init(name: "compact",
              desc: "Summarise the conversation so far",
              category: .context,
              kind: .prompt(
                body: "Summarise everything we've discussed and done so far into a concise but complete brief I can use to keep going — decisions made, current state, and what's left. Focus: $ARGUMENTS",
                source: "built-in"),
              argumentHint: "[focus]"),
        .init(name: "cost",
              desc: "Show tokens & cost for this session",
              category: .session,
              kind: .client(.cost),
              argumentHint: nil),
        .init(name: "model",
              desc: "Switch the active model",
              category: .model,
              kind: .client(.model),
              argumentHint: "[name]"),
        .init(name: "permissions",
              desc: "Change the permission mode",
              category: .session,
              kind: .client(.permissions),
              argumentHint: "[mode]"),
        .init(name: "mcp",
              desc: "Show this session's MCP servers",
              category: .session,
              kind: .client(.mcp),
              argumentHint: nil),
        .init(name: "agents",
              desc: "Show this session's subagents",
              category: .session,
              kind: .client(.agents),
              argumentHint: nil),
        .init(name: "init",
              desc: "Analyse this codebase and write a CLAUDE.md",
              category: .project,
              kind: .prompt(
                body: "Please analyse this codebase and create a CLAUDE.md file containing: build/lint/test commands, the high-level architecture, and any conventions a new contributor should follow. Read the existing structure first. $ARGUMENTS",
                source: "built-in"),
              argumentHint: nil),
        .init(name: "review",
              desc: "Review the current staged changes",
              category: .project,
              kind: .prompt(
                body: "Review the current git changes (run `git diff` and `git diff --cached`) for correctness, bugs, security issues, and style. Be specific and concise — cite file:line. $ARGUMENTS",
                source: "built-in"),
              argumentHint: "[focus]"),
        .init(name: "help",
              desc: "List everything you can do here",
              category: .help,
              kind: .client(.help),
              argumentHint: nil),
    ]

    /// Prefix-match against `query` (the text after the leading "/", before
    /// any space), sorted by category then name, capped at `limit`.
    static func filtered(_ query: String, in commands: [V2SlashCommand], limit: Int = 8) -> [V2SlashCommand] {
        let q = query.lowercased()
        return commands
            .filter { q.isEmpty || $0.name.lowercased().hasPrefix(q) }
            .sorted { lhs, rhs in
                lhs.category.rank != rhs.category.rank
                    ? lhs.category.rank < rhs.category.rank
                    : lhs.name < rhs.name
            }
            .prefix(limit)
            .map { $0 }
    }
}
