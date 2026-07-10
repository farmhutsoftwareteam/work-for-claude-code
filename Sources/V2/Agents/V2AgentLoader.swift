// V2AgentLoader — reads agents from user + project scopes and parses each
// file's YAML frontmatter. Synchronous, no caching — call when the panel
// appears or the user clicks refresh. Disk reads are cheap (a handful of
// small .md files); we'll add caching only if it shows up in a profile.
//
// Frontmatter format (matches Claude Code's convention):
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
// We parse a deliberately tiny subset of YAML: top-level scalar key-value
// pairs and bracketed list literals. Nested objects / multiline blocks /
// quoted edge cases the standard supports are out of scope — agents files
// in the wild use the simple form.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "agents")

enum V2AgentLoader {

    // MARK: - Public

    /// Load agents from both user scope (~/.claude/agents/) and project
    /// scope (<projectCwd>/.claude/agents/). Returns an empty array if a
    /// scope's directory doesn't exist — it's not an error condition.
    static func load(projectCwd: URL?) -> [V2Agent] {
        var agents: [V2Agent] = []
        agents.append(contentsOf: load(scope: .user, dir: userAgentsDir()))
        if let cwd = projectCwd {
            agents.append(contentsOf: load(scope: .project, dir: projectAgentsDir(cwd: cwd)))
        }
        return agents.sorted {
            // User scope first, then alphabetical within each scope.
            if $0.scope != $1.scope { return $0.scope == .user }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Scope roots

    static func userAgentsDir() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".claude/agents")
    }

    static func projectAgentsDir(cwd: URL) -> URL {
        cwd.appendingPathComponent(".claude/agents")
    }

    // MARK: - Scoped loader

    private static func load(scope: V2Agent.Scope, dir: URL) -> [V2Agent] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        return entries.compactMap { url -> V2Agent? in
            guard url.pathExtension.lowercased() == "md" else { return nil }
            return parse(fileURL: url, scope: scope)
        }
    }

    // MARK: - Single-file parser

    static func parse(fileURL: URL, scope: V2Agent.Scope) -> V2Agent? {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else {
            log.warning("could not read \(fileURL.path, privacy: .public)")
            return nil
        }
        return parse(content: raw, fileURL: fileURL, scope: scope)
    }

    /// Pure parser — separated from disk IO so tests can drive it directly.
    static func parse(content raw: String, fileURL: URL, scope: V2Agent.Scope) -> V2Agent? {
        let (frontmatter, body) = splitFrontmatter(raw)

        // Without frontmatter we can't claim to have an agent — Claude Code
        // refuses to load one too.
        guard let frontmatter else { return nil }
        let fields = parseFrontmatter(frontmatter)

        // name + description are required.
        guard let name = fields["name"]?.first, !name.isEmpty else { return nil }
        let description = fields["description"]?.first ?? ""

        // Tools field accepts either `tools` (Claude Code) or `allowed-tools`
        // (older skill convention) — accept both.
        let tools = (fields["tools"] ?? fields["allowed-tools"] ?? fields["allowed_tools"] ?? [])

        let model = fields["model"]?.first
        let color = fields["color"]?.first

        let slug = fileURL.deletingPathExtension().lastPathComponent

        return V2Agent(
            id: UUID(),
            path: fileURL,
            scope: scope,
            slug: slug,
            name: name,
            description: description,
            model: model,
            tools: tools,
            color: color,
            prompt: body.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    // MARK: - Frontmatter split

    /// Returns the frontmatter block (without the `---` fences) and the body
    /// remainder. If the file doesn't start with `---`, returns
    /// `(nil, raw)` — the caller treats that as "no frontmatter, skip".
    static func splitFrontmatter(_ raw: String) -> (frontmatter: String?, body: String) {
        // Tolerate a leading BOM or whitespace lines but the first
        // non-empty line must be exactly `---`. The comment above always
        // claimed BOM tolerance, but nothing actually stripped it — a
        // leading U+FEFF stays glued to the first line, `== "---"` never
        // matches, and the file silently fails the frontmatter check (the
        // agent just vanishes from the list, no log) (bug-hunt M7/M28).
        var raw = raw
        if raw.hasPrefix("\u{FEFF}") { raw.removeFirst() }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)

        // Find first non-blank line.
        guard let firstNonBlank = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[firstNonBlank].trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, raw)
        }

        // Find closing fence.
        var closing: Int? = nil
        for i in (firstNonBlank + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closing = i
            break
        }
        guard let closingIdx = closing else { return (nil, raw) }

        let frontmatter = lines[(firstNonBlank + 1)..<closingIdx].joined(separator: "\n")
        let body = lines[(closingIdx + 1)...].joined(separator: "\n")
        return (frontmatter, body)
    }

    // MARK: - YAML-ish key/value parser

    /// Parses a tiny subset of YAML — top-level `key: value` pairs and
    /// bracketed list literals (`key: [a, b, c]`). Each entry is normalized
    /// into an array (single-value scalars get a one-element array) so the
    /// caller can treat lists uniformly.
    static func parseFrontmatter(_ raw: String) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for line in raw.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            guard let colonIdx = trimmed.firstIndex(of: ":") else { continue }
            let key = trimmed[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
            let rest = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
            out[key] = parseValue(String(rest))
        }
        return out
    }

    /// Bracketed list (`[a, b, "c d"]`) → array of items.
    /// Otherwise treats the whole rest-of-line as a single scalar; strips
    /// matching single or double quotes if present.
    static func parseValue(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
            let inside = trimmed.dropFirst().dropLast()
            return inside.split(separator: ",").map { item -> String in
                let s = item.trimmingCharacters(in: .whitespaces)
                return unquote(s)
            }.filter { !$0.isEmpty }
        }
        return [unquote(trimmed)]
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2 else { return s }
        let first = s.first!
        let last = s.last!
        if (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            return String(s.dropFirst().dropLast())
        }
        return s
    }
}
