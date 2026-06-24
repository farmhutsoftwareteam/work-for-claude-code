// Atelier's read-side model of a Claude Code subagent. One per .md file
// under ~/.claude/agents/ (user scope) or <project>/.claude/agents/ (project
// scope). The disk format is YAML frontmatter + Markdown body — see
// V2AgentLoader for the parser.

import Foundation

struct V2Agent: Identifiable, Equatable {
    let id: UUID
    let path: URL
    let scope: Scope
    /// Slug from filename (e.g. "reviewer" from reviewer.md). Used as the
    /// stable identifier the binary recognizes for `Task` dispatching.
    let slug: String

    // YAML frontmatter fields. `name` and `description` are required;
    // everything else is optional and falls back to nil / empty.
    let name: String
    let description: String
    let model: String?
    let tools: [String]
    let color: String?

    /// Markdown body — the system prompt.
    let prompt: String

    enum Scope: String, Equatable, CaseIterable, Identifiable {
        case user, project
        var id: String { rawValue }
        var label: String {
            switch self {
            case .user:    return "user"
            case .project: return "project"
            }
        }
    }

    /// One-line summary shown in the dock panel below the agent name.
    /// Mirrors the design: "<model> · <tool1> · <tool2>. <description>"
    var summaryLine: String {
        var lead: [String] = []
        if let m = model, !m.isEmpty { lead.append(m) }
        lead.append(contentsOf: tools.prefix(3))
        let head = lead.joined(separator: " · ")
        if description.isEmpty { return head }
        return head.isEmpty ? description : "\(head). \(description)"
    }
}
