// HookConfigWriter — atomic edits to the `hooks` block in ~/.claude/settings.json
// and project-scoped <cwd>/.claude/settings.json. Mirrors the same
// preserve-unrelated-keys discipline as MCPConfigWriter:
//
//   1. Read the existing JSON (or start from {} if absent).
//   2. Mutate only the `hooks` key — every other top-level field is left
//      untouched, byte-for-byte if possible.
//   3. Atomic write via `.atomic` so a crash mid-write can't leave a
//      half-rewritten file.
//
// Schema (matches Claude Code's settings.json):
//
//   {
//     "hooks": {
//       "<EventName>": [
//         {
//           "matcher": "<optional regex/glob>",
//           "hooks": [
//             { "type": "command", "command": "<shell>" }
//           ]
//         }
//       ]
//     }
//   }

import Foundation

enum HookConfigWriter {

    // MARK: - Scopes

    enum Scope: Equatable {
        case user
        case project(cwd: URL)

        var settingsURL: URL {
            switch self {
            case .user:
                return FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude")
                    .appendingPathComponent("settings.json")
            case .project(let cwd):
                return cwd
                    .appendingPathComponent(".claude")
                    .appendingPathComponent("settings.json")
            }
        }
    }

    // MARK: - Edit operations

    /// Adds (or replaces, if a command with the same matcher+command already
    /// exists) a hook command to the named event. New commands always get
    /// `type: "command"` — the only documented variant.
    static func upsert(
        scope: Scope,
        event: String,
        matcher: String?,
        command: String
    ) throws {
        try edit(scope: scope) { hooksDict in
            var entries = (hooksDict[event] as? [[String: Any]]) ?? []

            // Find an existing matcher group for this matcher (matchers are
            // grouped — multiple commands can share a matcher).
            let normalizedMatcher = matcher?.trimmingCharacters(in: .whitespaces)
            let targetIdx = entries.firstIndex { entry in
                let m = entry["matcher"] as? String
                return m?.trimmingCharacters(in: .whitespaces) == normalizedMatcher
                    || (m == nil && (normalizedMatcher == nil || normalizedMatcher?.isEmpty == true))
            }

            let newHookObj: [String: Any] = ["type": "command", "command": command]

            if let idx = targetIdx {
                var commands = (entries[idx]["hooks"] as? [[String: Any]]) ?? []
                // De-dupe by command text within the same matcher group.
                if !commands.contains(where: { ($0["command"] as? String) == command }) {
                    commands.append(newHookObj)
                }
                entries[idx]["hooks"] = commands
            } else {
                var newEntry: [String: Any] = ["hooks": [newHookObj]]
                if let m = normalizedMatcher, !m.isEmpty {
                    newEntry["matcher"] = m
                }
                entries.append(newEntry)
            }

            hooksDict[event] = entries
            return hooksDict
        }
    }

    /// Replaces a specific command (identified by `oldCommand` + `oldMatcher`)
    /// with a new matcher + command pair. If the old isn't found this is a
    /// no-op — UI should call `upsert` for create instead.
    static func update(
        scope: Scope,
        event: String,
        oldMatcher: String?,
        oldCommand: String,
        newMatcher: String?,
        newCommand: String
    ) throws {
        // Remove the old, then upsert the new. The two-step keeps the writer
        // simple and naturally handles matcher changes (which means moving a
        // command between matcher groups).
        try remove(scope: scope, event: event, matcher: oldMatcher, command: oldCommand)
        try upsert(scope: scope, event: event, matcher: newMatcher, command: newCommand)
    }

    /// Removes a single command from the event's matcher group. If the group
    /// has no other commands after the removal, the group itself is dropped.
    /// If the event has no remaining groups, the event key is dropped. If
    /// the resulting `hooks` block is empty, the key is removed from the
    /// settings dict entirely.
    static func remove(
        scope: Scope,
        event: String,
        matcher: String?,
        command: String
    ) throws {
        try edit(scope: scope) { hooksDict in
            guard var entries = hooksDict[event] as? [[String: Any]] else { return hooksDict }
            let normalizedMatcher = matcher?.trimmingCharacters(in: .whitespaces)

            for i in entries.indices {
                let m = (entries[i]["matcher"] as? String)?.trimmingCharacters(in: .whitespaces)
                let matchesGroup = m == normalizedMatcher
                    || (m == nil && (normalizedMatcher == nil || normalizedMatcher?.isEmpty == true))
                if !matchesGroup { continue }

                var commands = (entries[i]["hooks"] as? [[String: Any]]) ?? []
                commands.removeAll { ($0["command"] as? String) == command }
                if commands.isEmpty {
                    entries[i]["hooks"] = nil as Any?
                } else {
                    entries[i]["hooks"] = commands
                }
            }

            // Drop empty matcher groups.
            entries.removeAll { entry in
                let cmds = entry["hooks"] as? [[String: Any]]
                return (cmds?.isEmpty ?? true)
            }

            if entries.isEmpty {
                hooksDict.removeValue(forKey: event)
            } else {
                hooksDict[event] = entries
            }
            return hooksDict
        }
    }

    // MARK: - Pure transform (testable, no IO)

    /// Apply an edit to a settings dictionary purely (no disk). Exposed so
    /// tests can verify the schema mutations without touching the user's
    /// real settings.json. Returns the new top-level dictionary.
    static func applyEdit(
        to settings: [String: Any],
        transform: (inout [String: Any]) -> [String: Any]
    ) -> [String: Any] {
        var hooksDict = (settings["hooks"] as? [String: Any]) ?? [:]
        hooksDict = transform(&hooksDict)
        var out = settings
        if hooksDict.isEmpty {
            out.removeValue(forKey: "hooks")
        } else {
            out["hooks"] = hooksDict
        }
        return out
    }

    // MARK: - Internal

    private static func edit(
        scope: Scope,
        _ transform: (inout [String: Any]) -> [String: Any]
    ) throws {
        let url = scope.settingsURL
        let fm = FileManager.default

        // Ensure the parent .claude/ exists. The MCP / plugin writers do the
        // same — first-run setup shouldn't fail on missing directories.
        let parent = url.deletingLastPathComponent()
        if !fm.fileExists(atPath: parent.path) {
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        }

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = json
        }

        let updated = applyEdit(to: settings, transform: transform)

        let outData = try JSONSerialization.data(
            withJSONObject: updated,
            options: [.prettyPrinted, .sortedKeys]
        )
        try outData.write(to: url, options: .atomic)
    }
}

// MARK: - Known event catalog

/// The full set of hook event names Claude Code supports. The editor sheet
/// uses this to populate the event picker; the parser also references this
/// list for stable ordering. Source: Claude Code docs.
enum ClaudeHookEvent: String, CaseIterable, Identifiable {
    case sessionStart      = "SessionStart"
    case userPromptSubmit  = "UserPromptSubmit"
    case preToolUse        = "PreToolUse"
    case postToolUse       = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case stop              = "Stop"
    case subagentStop      = "SubagentStop"
    case notification      = "Notification"
    case preCompact        = "PreCompact"
    case sessionEnd        = "SessionEnd"

    var id: String { rawValue }
    var label: String { rawValue }

    var summary: String {
        switch self {
        case .sessionStart:       return "When a new Claude session begins"
        case .userPromptSubmit:   return "Before each user message is sent"
        case .preToolUse:         return "Before a tool executes"
        case .postToolUse:        return "After a tool succeeds"
        case .postToolUseFailure: return "When a tool fails"
        case .stop:               return "When Claude finishes responding"
        case .subagentStop:       return "When a subagent finishes"
        case .notification:       return "When Claude surfaces a notification"
        case .preCompact:         return "Before a context compaction"
        case .sessionEnd:         return "When the session ends"
        }
    }
}
