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

    /// Declared explicitly — adding the `agentReported` initializer below
    /// suppresses Swift's synthesized memberwise init, which `builtins`'
    /// `.init(name:desc:category:kind:argumentHint:)` array literal needs.
    init(name: String, desc: String, category: V2SlashCategory, kind: V2SlashKind, argumentHint: String?) {
        self.name = name
        self.desc = desc
        self.category = category
        self.kind = kind
        self.argumentHint = argumentHint
    }

    /// A tiny right-aligned tag describing where this runs, so the palette
    /// teaches the client/agent split at a glance. "built-in" and "agent"
    /// both read as "→ agent" — Atelier's own curated prompt commands and
    /// ones the live agent process reported are the same KIND of thing to
    /// the user (something the agent runs), just from different sources.
    var runTag: String {
        switch kind {
        case .client:           return "app"
        case .prompt(_, let s): return (s == "built-in" || s == "agent") ? "→ agent" : s
        }
    }

    /// Adapts a command the real agent process reported (ACP's
    /// `available_commands_update`) into the same model the popover already
    /// renders. Running it sends the literal "/name args" text straight
    /// through — the agent already knows what its own command means, there's
    /// no local template to expand. `argumentHint` defaults to a generic
    /// placeholder since ACP doesn't expose a per-command argument schema —
    /// safer than guessing "no arguments" and firing a command immediately
    /// with nothing typed.
    init(agentReported cmd: ACPCommand) {
        self.init(
            name: cmd.name,
            desc: cmd.description,
            category: .project,
            kind: .prompt(body: "/\(cmd.name) $ARGUMENTS", source: "agent"),
            argumentHint: "[args]"
        )
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

    /// Merges agent-reported commands (from ACP's `available_commands_update`
    /// — see `ACPClient.swift`/`ACPSession.commands`) after Atelier's own
    /// curated list. Appended, never replacing an existing entry — even a
    /// name collision (Atelier's own `/checkup` vs. the agent's own) shows
    /// as two separate rows, distinguished by run-tag, rather than one
    /// silently overwriting the other's wording. `agentReported` is simply
    /// `[]` for any session still on the pre-ACP `StreamSession` path —
    /// that's the documented fallback, not a placeholder: the merged list
    /// is just the curated baseline, unchanged from before.
    static func merged(builtins: [V2SlashCommand], agentReported: [ACPCommand]) -> [V2SlashCommand] {
        builtins + agentReported.map(V2SlashCommand.init(agentReported:))
    }

    /// Case-insensitive fuzzy match: an exact substring scores highest, an
    /// in-order (non-contiguous) subsequence scores lower, no match at all
    /// returns nil. An empty query matches everything at score 0 — "show
    /// the whole catalog" stays exactly today's behavior. Mirrors
    /// Slack/Notion/Discord's own "/" search feel — abbreviated or slightly
    /// misspelled typing ("chkup") still finds the right command.
    private static func fuzzyScore(_ query: String, in text: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let q = query.lowercased()
        let t = text.lowercased()
        if t.contains(q) { return 2 }
        var searchFrom = t.startIndex
        for ch in q {
            guard let found = t[searchFrom...].firstIndex(of: ch) else { return nil }
            searchFrom = t.index(after: found)
        }
        return 1
    }

    /// Matches against both `name` and `desc` — real search, not just a name
    /// prefix, so typing what a command DOES ("check up") finds it even
    /// when the name itself doesn't start with those letters. Sorted by
    /// match quality first, falling back to today's category-then-name
    /// order for ties (keeps the empty-query / full-catalog view stable).
    static func matched(_ query: String, in commands: [V2SlashCommand], limit: Int = 8) -> [V2SlashMatch] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let scored: [(command: V2SlashCommand, score: Int, field: V2SlashMatch.MatchedField)] = commands.compactMap { cmd in
            let nameScore = fuzzyScore(q, in: cmd.name)
            let descScore = fuzzyScore(q, in: cmd.desc)
            guard let best = [nameScore, descScore].compactMap({ $0 }).max() else { return nil }
            let field: V2SlashMatch.MatchedField = (nameScore ?? -1) >= (descScore ?? -1) ? .name : .desc
            return (cmd, best, field)
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.command.category.rank != rhs.command.category.rank {
                return lhs.command.category.rank < rhs.command.category.rank
            }
            return lhs.command.name < rhs.command.name
        }
        return sorted.prefix(limit).map { V2SlashMatch(command: $0.command, matchedOn: q.isEmpty ? nil : $0.field) }
    }

    /// Convenience for callers that only need the commands, not which field
    /// matched (e.g. `/help`'s full listing).
    static func filtered(_ query: String, in commands: [V2SlashCommand], limit: Int = 8) -> [V2SlashCommand] {
        matched(query, in: commands, limit: limit).map(\.command)
    }
}

/// A search result plus which field it matched on — the popover shows a
/// "matched: desc" tag when a result isn't an obvious name match, so a
/// fuzzy hit doesn't feel arbitrary. `matchedOn` is nil for an empty query
/// (nothing to explain — it's just the full catalog).
struct V2SlashMatch: Identifiable {
    let command: V2SlashCommand
    let matchedOn: MatchedField?
    enum MatchedField { case name, desc }
    var id: String { command.id }
}
