import Foundation
import AppKit

// MARK: - Skill file-system operations
//
// Create / clone / delete / toggle-invocability for skills. All paths are
// resolved with symlinks and confined to the user's ~/.claude/ or ~/.agents/
// tree. Destructive actions go through NSWorkspace.recycle (Trash) so they're
// always recoverable.

enum SkillOperationError: Error, LocalizedError {
    case nameInvalid
    case nameTaken(URL)
    case notFound
    case writeFailed(String)
    case cloneFailed(String)

    var errorDescription: String? {
        switch self {
        case .nameInvalid:              return "Name must be lowercase letters, numbers, and hyphens only (max 64 chars)."
        case .nameTaken(let at):        return "A skill already exists at \(at.path)."
        case .notFound:                 return "Skill not found on disk."
        case .writeFailed(let msg):     return "Couldn't write SKILL.md: \(msg)"
        case .cloneFailed(let msg):     return "Clone failed: \(msg)"
        }
    }
}

enum SkillOperations {

    /// Matches Claude Code's documented name rule: lowercase letters, digits, hyphens. 2-64 chars.
    static func isValidName(_ name: String) -> Bool {
        let regex = #"^[a-z0-9][a-z0-9-]{1,63}$"#
        return name.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: - Create

    /// Scaffolds a new skill at ~/.claude/skills/<name>/ with SKILL.md + optional subdirs.
    @discardableResult
    static func createSkill(
        name: String,
        description: String,
        whenToUse: String?,
        model: String?,
        includeReferences: Bool,
        includeScripts: Bool,
        includeAssets: Bool
    ) throws -> URL {
        guard isValidName(name) else { throw SkillOperationError.nameInvalid }

        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")
        let skillDir = base.appendingPathComponent(name)

        if FileManager.default.fileExists(atPath: skillDir.path) {
            throw SkillOperationError.nameTaken(skillDir)
        }

        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        if includeReferences {
            try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("references"), withIntermediateDirectories: true)
        }
        if includeScripts {
            try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        }
        if includeAssets {
            try FileManager.default.createDirectory(at: skillDir.appendingPathComponent("assets"), withIntermediateDirectories: true)
        }

        // Build the SKILL.md
        var frontmatter = "---\nname: \(name)\ndescription: \(yamlEscape(description))\n"
        if let whenToUse, !whenToUse.isEmpty {
            frontmatter += "when_to_use: \(yamlEscape(whenToUse))\n"
        }
        if let model, !model.isEmpty {
            frontmatter += "model: \(model)\n"
        }
        frontmatter += "---\n\n"

        let body = "# \(name.replacingOccurrences(of: "-", with: " ").capitalized)\n\n\(description.isEmpty ? "Describe the skill workflow here." : description)\n"

        let content = frontmatter + body
        let skillMd = skillDir.appendingPathComponent("SKILL.md")
        do {
            try content.write(to: skillMd, atomically: true, encoding: .utf8)
        } catch {
            throw SkillOperationError.writeFailed(error.localizedDescription)
        }

        return skillDir
    }

    // MARK: - Clone

    /// Sidecar filename recording where a cloned skill came from — kept
    /// alongside SKILL.md, never merged into its frontmatter (that content
    /// belongs to the skill author, not to Atelier's bookkeeping). Presence
    /// of this file is also what scopes update-detection: only skills
    /// Atelier itself cloned get an "update available" check, never a
    /// skill the user wrote that happens to share a name with something in
    /// a marketplace.
    private static let provenanceFilename = ".atelier-clone-source.json"

    struct CloneProvenance: Codable {
        let pluginId: String   // "name@marketplace" — the store.pluginSkills key
        let skillName: String
    }

    /// Copies a plugin-scoped skill into ~/.claude/skills/ so the user can edit
    /// a personal override. Appends a suffix if the target name is taken.
    /// `pluginId` (the full "name@marketplace" key, when known) is stamped as
    /// a sidecar file so a later update-check can find the skill's current
    /// upstream content — pass nil for sources with no ongoing upstream to
    /// track (e.g. a one-off community git clone).
    @discardableResult
    static func cloneToPersonal(_ skill: ClaudeSkill, pluginId: String? = nil) throws -> URL {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("skills")

        // Work out the non-colliding target name
        var candidate = skill.name
        var suffix = 1
        while FileManager.default.fileExists(atPath: base.appendingPathComponent(candidate).path) {
            suffix += 1
            candidate = "\(skill.name)-\(suffix)"
        }
        let target = base.appendingPathComponent(candidate)

        // Plugin skills live as plain directories → straight recursive copy
        if skill.packaging == .directory {
            do {
                try FileManager.default.copyItem(at: skill.path, to: target)
            } catch {
                throw SkillOperationError.cloneFailed(error.localizedDescription)
            }
        } else {
            // Unzip a packaged .skill into the target directory
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-q", "-o", skill.path.path, "-d", target.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                throw SkillOperationError.cloneFailed("unzip exited with status \(proc.terminationStatus)")
            }
        }

        // If the copied skill's SKILL.md still has the old name, rewrite it
        if candidate != skill.name {
            let skillMd = target.appendingPathComponent("SKILL.md")
            if let content = try? String(contentsOf: skillMd, encoding: .utf8) {
                let rewritten = content.replacingOccurrences(
                    of: "name: \(skill.name)",
                    with: "name: \(candidate)"
                )
                try? rewritten.write(to: skillMd, atomically: true, encoding: .utf8)
            }
        }

        if let pluginId {
            let provenance = CloneProvenance(pluginId: pluginId, skillName: skill.name)
            if let data = try? JSONEncoder().encode(provenance) {
                try? data.write(to: target.appendingPathComponent(provenanceFilename))
            }
        }

        return target
    }

    /// Reads back a clone's provenance, if any. nil means either this skill
    /// wasn't cloned by Atelier, or its source had no ongoing upstream.
    static func cloneProvenance(for skill: ClaudeSkill) -> CloneProvenance? {
        guard skill.packaging == .directory else { return nil }
        let marker = skill.path.appendingPathComponent(provenanceFilename)
        guard let data = try? Data(contentsOf: marker) else { return nil }
        return try? JSONDecoder().decode(CloneProvenance.self, from: data)
    }

    /// Overwrites a cloned skill's SKILL.md with its current upstream
    /// content — the "take theirs" side of the update-diff flow. Always an
    /// explicit, user-confirmed call; nothing in this file calls it silently.
    static func applyUpdate(_ skill: ClaudeSkill, newContent: String) throws {
        guard skill.packaging == .directory else {
            throw SkillOperationError.writeFailed("Cannot update a packaged .skill archive in place.")
        }
        do {
            try newContent.write(to: skill.path.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        } catch {
            throw SkillOperationError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Delete

    /// Moves the skill to the user's Trash (not permanent). Returns both the
    /// original location and where it landed in Trash, so a caller can offer
    /// a real "undo" (moveItem back) rather than just a confirmation toast
    /// with no way to actually reverse it.
    @discardableResult
    static func deleteSkill(_ skill: ClaudeSkill) throws -> (originalPath: URL, trashedAt: URL) {
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: skill.path, resultingItemURL: &resultingURL)
        guard let trashedAt = resultingURL as URL? else {
            // Trashed successfully but macOS didn't report where — still a
            // success (file is safe in Trash), just not undo-able from here.
            return (skill.path, skill.path)
        }
        return (skill.path, trashedAt)
    }

    /// Reverses `deleteSkill` within the same run — moves the file back from
    /// Trash to its original path. Fails harmlessly if the user already
    /// emptied Trash or the original path is occupied again.
    static func restoreFromTrash(originalPath: URL, trashedAt: URL) throws {
        guard trashedAt != originalPath, FileManager.default.fileExists(atPath: trashedAt.path) else {
            throw SkillOperationError.notFound
        }
        guard !FileManager.default.fileExists(atPath: originalPath.path) else {
            throw SkillOperationError.nameTaken(originalPath)
        }
        try FileManager.default.moveItem(at: trashedAt, to: originalPath)
    }

    // MARK: - Toggle invocability (skill-level)

    /// Flip `disable-model-invocation` in the frontmatter. Preserves everything
    /// else exactly as written (including unknown keys and body).
    static func setDisableModelInvocation(_ disabled: Bool, for skill: ClaudeSkill) throws {
        guard skill.packaging == .directory else {
            throw SkillOperationError.writeFailed("Cannot edit a packaged .skill archive in place. Clone it first.")
        }
        try setFrontmatterBool(key: "disable-model-invocation", value: disabled, at: skill.path.appendingPathComponent("SKILL.md"))
    }

    /// Flip `user-invocable` (default true). When false, the skill can't be
    /// invoked via /skill-name but can still auto-invoke if enabled.
    static func setUserInvocable(_ invocable: Bool, for skill: ClaudeSkill) throws {
        guard skill.packaging == .directory else {
            throw SkillOperationError.writeFailed("Cannot edit a packaged .skill archive in place. Clone it first.")
        }
        try setFrontmatterBool(key: "user-invocable", value: invocable, at: skill.path.appendingPathComponent("SKILL.md"))
    }

    // MARK: - Toggle plugin enable/disable

    /// Write `enabledPlugins[<pluginId>] = enabled` into ~/.claude/settings.json.
    /// Creates the file if missing; preserves unrelated settings.
    static func setPluginEnabled(_ enabled: Bool, pluginId: String) throws {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("settings.json")

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        var enabledPlugins = settings["enabledPlugins"] as? [String: Bool] ?? [:]
        enabledPlugins[pluginId] = enabled
        settings["enabledPlugins"] = enabledPlugins

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Edit (full field + body rewrite)

    /// Rewrite an existing skill's frontmatter fields + body. Preserves every
    /// frontmatter key not passed here (unknown keys, `disable-model-invocation`,
    /// `user-invocable`, …) exactly as written — mirrors setFrontmatterBool's
    /// round-trip discipline, generalized to string fields + the body.
    /// `name` is intentionally NOT a parameter: renaming is a directory move,
    /// out of scope (see #2's issue) — callers editing an existing skill never
    /// touch it.
    static func updateSkill(
        _ skill: ClaudeSkill,
        description: String,
        whenToUse: String?,
        model: String?,
        effort: String?,
        license: String?,
        argumentHint: String?,
        body: String
    ) throws {
        guard skill.packaging == .directory else {
            throw SkillOperationError.writeFailed("Cannot edit a packaged .skill archive in place. Clone it first.")
        }
        let skillMd = skill.path.appendingPathComponent("SKILL.md")
        let existing = ((try? String(contentsOf: skillMd, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = existing.components(separatedBy: "\n")

        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            throw SkillOperationError.writeFailed("Missing YAML frontmatter in SKILL.md")
        }

        // key -> new value (nil value = remove the key if present)
        let updates: [(String, String?)] = [
            ("description", description),
            ("when_to_use", whenToUse?.isEmpty == false ? whenToUse : nil),
            ("model", model?.isEmpty == false ? model : nil),
            ("effort", effort?.isEmpty == false ? effort : nil),
            ("license", license?.isEmpty == false ? license : nil),
            ("argument-hint", argumentHint?.isEmpty == false ? argumentHint : nil),
        ]

        var frontmatterLines = Array(lines[(first + 1)..<second])
        for (key, value) in updates {
            frontmatterLines.removeAll {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):")
            }
            if let value {
                frontmatterLines.append("\(key): \(yamlEscape(value))")
            }
        }

        lines.replaceSubrange((first + 1)..<second, with: frontmatterLines)
        // Body: everything after the closing fence, replaced wholesale. The
        // closing-fence index shifts by however much the frontmatter grew/shrank.
        let newSecond = first + 1 + frontmatterLines.count
        let head = Array(lines[0...newSecond])
        let newContent = (head + ["", body]).joined(separator: "\n")

        do {
            try newContent.write(to: skillMd, atomically: true, encoding: .utf8)
        } catch {
            throw SkillOperationError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: - Internal helpers

    /// Rewrite a single boolean frontmatter key atomically. If the key is
    /// absent it gets appended before the closing `---`.
    private static func setFrontmatterBool(key: String, value: Bool, at url: URL) throws {
        // Normalize CRLF → LF before splitting. A SKILL.md authored on
        // Windows (or copy-pasted from a CRLF source) would otherwise leave
        // a stray `\r` on every line, breaking `hasPrefix("\(key):")` match
        // and `=== "---"` boundary detection.
        let existing = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
        let lines = existing.components(separatedBy: "\n")

        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            throw SkillOperationError.writeFailed("Missing YAML frontmatter in SKILL.md")
        }

        var newLines = lines
        var wrote = false
        for i in (first + 1)..<second {
            let trimmed = newLines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                newLines[i] = "\(key): \(value ? "true" : "false")"
                wrote = true
                break
            }
        }
        if !wrote {
            newLines.insert("\(key): \(value ? "true" : "false")", at: second)
        }

        try newLines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private static func yamlEscape(_ s: String) -> String {
        // Quote if the value contains characters YAML would interpret, otherwise emit plain.
        let needsQuoting = s.contains(":") || s.contains("\"") || s.hasPrefix("-") || s.hasPrefix(" ")
        if !needsQuoting { return s }
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
