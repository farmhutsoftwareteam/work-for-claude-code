// Loads the user's OWN slash commands off disk so the palette surfaces
// capability tailored to them — the real power-tool hook.
//
// Mirrors Claude Code's convention:
//   • <project>/.claude/commands/**/*.md   → project commands
//   • ~/.claude/commands/**/*.md           → personal commands
//   • subdirectories namespace the name:  frontend/component.md → /frontend:component
//   • optional YAML frontmatter: `description:` and `argument-hint:`
//   • the body is the prompt template, sent to the agent with $ARGUMENTS /
//     $1… expanded.
//
// Pure filesystem read — call off the main thread, then publish the result.

import Foundation

enum V2CommandRegistry {

    /// Project commands override personal ones of the same name (Claude Code
    /// precedence). `projectRoot` is the session's cwd; pass nil to load only
    /// the personal set.
    static func load(projectRoot: URL?) -> [V2SlashCommand] {
        var byName: [String: V2SlashCommand] = [:]
        for c in scan(dir: userCommandsDir, source: "user") { byName[c.name] = c }
        if let root = projectRoot {
            let projDir = root.appendingPathComponent(".claude/commands", isDirectory: true)
            for c in scan(dir: projDir, source: "project") { byName[c.name] = c }
        }
        return Array(byName.values)
    }

    private static var userCommandsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/commands", isDirectory: true)
    }

    // MARK: - Scan

    private static func scan(dir: URL, source: String) -> [V2SlashCommand] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        guard let walker = fm.enumerator(
            at: dir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [V2SlashCommand] = []
        for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let parsed = parse(raw)
            let name = namespacedName(of: url, under: dir)
            guard !name.isEmpty else { continue }
            out.append(V2SlashCommand(
                name: name,
                desc: parsed.description ?? "Custom command",
                category: .project,
                kind: .prompt(body: parsed.body, source: source),
                argumentHint: parsed.argumentHint
            ))
        }
        return out
    }

    /// Path under `dir`, minus the `.md`, with subdirs joined by ":".
    private static func namespacedName(of url: URL, under dir: URL) -> String {
        let base = dir.standardizedFileURL.pathComponents
        var comps = url.standardizedFileURL.deletingPathExtension().pathComponents
        guard comps.count > base.count else { return url.deletingPathExtension().lastPathComponent }
        comps.removeFirst(base.count)
        return comps.joined(separator: ":")
    }

    // MARK: - Parse

    private struct Parsed {
        var description: String?
        var argumentHint: String?
        var body: String
    }

    private static func parse(_ raw: String) -> Parsed {
        var description: String?
        var argumentHint: String?
        var body = raw

        // Optional frontmatter delimited by --- on its own lines.
        if raw.hasPrefix("---") {
            let lines = raw.components(separatedBy: "\n")
            if let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                for line in lines[1..<close] {
                    if let v = value(of: "description", in: line) { description = v }
                    if let v = value(of: "argument-hint", in: line) { argumentHint = v }
                }
                body = lines[(close + 1)...].joined(separator: "\n")
            }
        }

        body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Fall back to the first non-empty body line as the description.
        if description == nil {
            let firstLine = body
                .components(separatedBy: "\n")
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
                .trimmingCharacters(in: .whitespaces)
            description = firstLine.map { $0.count > 64 ? String($0.prefix(63)) + "…" : $0 }
        }
        return Parsed(description: description, argumentHint: argumentHint, body: body)
    }

    /// Extract `key: value` from a frontmatter line, stripping quotes.
    private static func value(of key: String, in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(key + ":") else { return nil }
        var v = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        if v.count >= 2,
           (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v.isEmpty ? nil : v
    }

    // MARK: - Argument expansion

    /// Expand a prompt template: `$ARGUMENTS` → all args, `$1`,`$2`… →
    /// positional words. Leftover placeholders collapse to empty.
    static func expand(_ template: String, args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = template.replacingOccurrences(of: "$ARGUMENTS", with: trimmed)
        let words = trimmed.split(separator: " ").map(String.init)
        for i in 1...9 {
            let token = "$\(i)"
            guard out.contains(token) else { continue }
            out = out.replacingOccurrences(of: token, with: i <= words.count ? words[i - 1] : "")
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
