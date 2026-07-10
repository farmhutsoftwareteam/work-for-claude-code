// AgentConfigWriter — atomic writes for .claude/agents/<slug>.md files.
//
// File layout (matches Claude Code's convention and V2AgentLoader's parser):
//
//   ---
//   name: reviewer
//   description: Catches standard violations
//   model: opus
//   tools: [Read, Grep, Bash]
//   color: red
//   ---
//
//   System prompt body…
//
// Atomic = write to a sibling tmp file then rename. The parent .claude/agents/
// directory is created if missing.

import Foundation

enum AgentConfigWriter {

    // MARK: - Errors

    enum WriteError: LocalizedError {
        case invalidSlug
        case nameRequired
        case promptRequired

        var errorDescription: String? {
            switch self {
            case .invalidSlug:    return "Slug must be a non-empty, lowercase-with-dashes identifier."
            case .nameRequired:   return "Name is required."
            case .promptRequired: return "System prompt body is required."
            }
        }
    }

    // MARK: - Scope

    enum Scope: Equatable {
        case user
        case project(cwd: URL)

        func agentsDir() -> URL {
            switch self {
            case .user:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/agents")
            case .project(let cwd):
                return cwd.appendingPathComponent(".claude/agents")
            }
        }

        func url(forSlug slug: String) -> URL {
            agentsDir().appendingPathComponent("\(slug).md")
        }
    }

    // MARK: - Draft

    struct Draft {
        var slug: String
        var name: String
        var description: String
        var model: String
        var tools: [String]
        var color: String
        var prompt: String

        static let empty = Draft(
            slug: "",
            name: "",
            description: "",
            model: "",
            tools: [],
            color: "",
            prompt: ""
        )

        static func from(agent: V2Agent) -> Draft {
            Draft(
                slug: agent.slug,
                name: agent.name,
                description: agent.description,
                model: agent.model ?? "",
                tools: agent.tools,
                color: agent.color ?? "",
                prompt: agent.prompt
            )
        }
    }

    // MARK: - Save

    /// Validate + serialize + atomic write. On success returns the URL the
    /// file was written to (useful for revealing in Finder).
    @discardableResult
    static func save(draft: Draft, to scope: Scope) throws -> URL {
        let slug = draft.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !slug.isEmpty,
              slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            throw WriteError.invalidSlug
        }
        guard !name.isEmpty else { throw WriteError.nameRequired }
        guard !prompt.isEmpty else { throw WriteError.promptRequired }

        let url = scope.url(forSlug: slug)
        let fm = FileManager.default
        try fm.createDirectory(at: scope.agentsDir(), withIntermediateDirectories: true)

        let body = serialize(draft: draft, normalizedName: name, normalizedPrompt: prompt)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Delete the file for an agent (moves to Trash so it's recoverable).
    static func delete(slug: String, from scope: Scope) throws {
        let url = scope.url(forSlug: slug)
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }

    // MARK: - Serialize (pure — used by tests)

    static func serialize(draft: Draft, normalizedName: String, normalizedPrompt: String) -> String {
        var lines: [String] = ["---"]
        lines.append("name: \(escape(normalizedName))")
        let desc = draft.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !desc.isEmpty { lines.append("description: \(escape(desc))") }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !model.isEmpty { lines.append("model: \(escape(model))") }
        if !draft.tools.isEmpty {
            let serialized = draft.tools
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map(escapeToolItem)
                .joined(separator: ", ")
            lines.append("tools: [\(serialized)]")
        }
        let color = draft.color.trimmingCharacters(in: .whitespacesAndNewlines)
        if !color.isEmpty { lines.append("color: \(escape(color))") }
        lines.append("---")
        lines.append("")
        lines.append(normalizedPrompt)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// Quote a YAML scalar only when needed — colons, leading/trailing
    /// whitespace, or surrounding quotes would break the parser. Also covers
    /// the indicator characters plain YAML scalars can't start with
    /// (`#[]{}&!|>`) and an embedded " #" (starts an inline comment) —
    /// previously unhandled, so a field like "priority: #1" or one starting
    /// with "[urgent]" round-tripped as broken/misread YAML on next load
    /// (bug-hunt M6/M27).
    private static let indicatorChars: Set<Character> = ["#", "[", "]", "{", "}", "&", "!", "|", ">"]

    private static func escape(_ s: String) -> String {
        let startsWithIndicator = s.first.map(indicatorChars.contains) ?? false
        let needsQuotes = s.contains(":") || s.contains("\n") || s.first == " " || s.last == " "
            || s.contains(" #") || startsWithIndicator
        if needsQuotes {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return s
    }

    /// Same rules as `escape`, plus the flow-sequence delimiters that only
    /// matter inside `tools: [...]` — an unescaped `,`/`[`/`]` inside one
    /// tool token unbalances or splits the list (bug-hunt #15).
    private static func escapeToolItem(_ s: String) -> String {
        if s.contains(",") || s.contains("[") || s.contains("]") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return escape(s)
    }
}
