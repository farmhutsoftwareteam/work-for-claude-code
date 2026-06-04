import Foundation

// MARK: - MCP Server

struct MCPServer: Identifiable, Hashable {
    let id: String
    let name: String
    let transport: Transport
    let source: Source
    var env: [String: String]?

    /// HTTP / SSE only — extra request headers (Bearer tokens, X-API-Key, etc.)
    /// nil ↔ "not configured." Serialized as the JSON `headers: {}` sub-object
    /// when non-nil and non-empty.
    var headers: [String: String]? = nil

    /// HTTP / SSE only — pre-configured OAuth credentials for servers that
    /// don't support Dynamic Client Registration. nil means "use Claude
    /// Code's default OAuth discovery (most servers)."
    var oauth: OAuthConfig? = nil

    /// Any transport — bypass MCP Tool Search and keep this server's tools
    /// in context every turn. Costs context window. nil = use Claude's
    /// default (deferred load).
    var alwaysLoad: Bool? = nil

    /// Any transport — per-server tool call timeout in milliseconds. nil =
    /// use Claude's default (60s). Floored to 1000ms by Claude regardless.
    var timeoutMs: Int? = nil

    enum Transport: Hashable {
        case stdio(command: String, args: [String])
        case http(url: String)
        case sse(url: String)
        case sdk
        case unknown(type: String)
    }

    enum Source: Hashable {
        /// `~/.claude.json` top-level `mcpServers` — loads in every project.
        case global
        /// `~/.claude.json` → `projects.<cwd>.mcpServers` — loads only in
        /// that project, private to the user. Default of `claude mcp add`.
        case localUser
        /// `<cwd>/.mcp.json` — shared with the team via version control.
        case project
        /// Bundled with a plugin.
        case plugin(name: String)
    }

    /// Explicit initializer with defaults for the optional Phase-1.1
    /// fields. Without this Swift's synthesized memberwise init would
    /// still require every caller to pass headers / oauth / alwaysLoad /
    /// timeoutMs explicitly. Callers that pre-date these fields keep
    /// working unchanged.
    init(
        id: String,
        name: String,
        transport: Transport,
        source: Source,
        env: [String: String]? = nil,
        headers: [String: String]? = nil,
        oauth: OAuthConfig? = nil,
        alwaysLoad: Bool? = nil,
        timeoutMs: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.source = source
        self.env = env
        self.headers = headers
        self.oauth = oauth
        self.alwaysLoad = alwaysLoad
        self.timeoutMs = timeoutMs
    }

    var transportLabel: String {
        switch transport {
        case .stdio:            "stdio"
        case .http:             "http"
        case .sse:              "sse"
        case .sdk:              "sdk"
        case .unknown(let t):   t
        }
    }

    var commandSummary: String {
        switch transport {
        case .stdio(let cmd, let args):
            return ([cmd] + args.prefix(3)).joined(separator: " ")
                + (args.count > 3 ? " ..." : "")
        case .http(let url), .sse(let url):
            return url
        case .sdk:
            return "Built-in"
        case .unknown(let t):
            return "Unknown (\(t))"
        }
    }
}

// MARK: - MCP OAuth config

/// Pre-configured OAuth credentials for HTTP / SSE MCP servers that don't
/// support Dynamic Client Registration (Slack, some enterprise SSO setups).
/// All fields are optional; the writer emits the `oauth: {}` JSON sub-object
/// only when at least one field is set. Mirrors the schema documented at
/// <https://code.claude.com/docs/en/mcp#authenticate-with-remote-mcp-servers>.
struct OAuthConfig: Hashable {
    /// OAuth client ID issued by the server's developer portal.
    var clientId: String?
    /// Fixed local callback port (`http://localhost:PORT/callback`). Some
    /// servers require this be pre-registered as a redirect URI.
    var callbackPort: Int?
    /// Space-separated scope list (RFC 6749 §3.3 format). Empty / nil means
    /// "let Claude Code negotiate scopes via the standard discovery flow."
    var scopes: String?
    /// Override the OAuth metadata discovery URL. Must use `https://`.
    /// Useful for routing through an internal SSO proxy.
    var authServerMetadataUrl: String?

    /// True only when every field is nil or empty — used by the writer to
    /// decide whether to emit the `oauth` key at all.
    var isEmpty: Bool {
        (clientId?.isEmpty ?? true)
        && callbackPort == nil
        && (scopes?.isEmpty ?? true)
        && (authServerMetadataUrl?.isEmpty ?? true)
    }
}

// MARK: - Skill

struct ClaudeSkill: Identifiable, Hashable {
    let id: String
    let name: String
    let skillDescription: String
    let author: String?
    let version: String?
    let source: Source
    let path: URL                    // directory for directory-backed skills, .skill zip for packaged
    let hasReferences: Bool
    let hasScripts: Bool
    let hasAssets: Bool

    // Extended frontmatter (all optional)
    let whenToUse: String?
    let allowedTools: [String]
    let model: String?
    let effort: String?
    let license: String?
    let argumentHint: String?
    let disableModelInvocation: Bool
    let userInvocable: Bool
    let paths: [String]              // glob patterns for auto-activation
    let packaging: Packaging

    // The raw frontmatter dictionary — useful for operations that want to
    // round-trip unknown keys without losing them.
    let rawFrontmatter: [String: String]

    enum Source: Hashable {
        case standalone
        case plugin(name: String)
        case project(cwd: String)
        case enterprise
    }

    /// Where the bits live physically.
    enum Packaging: Hashable {
        case directory          // <skill>/SKILL.md
        case zipArchive         // <skill>.skill (zip containing <skill>/SKILL.md)
    }

    static func == (lhs: ClaudeSkill, rhs: ClaudeSkill) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ClaudeSkill.Source {
    /// Precedence for same-named skills: higher wins.
    /// Matches Claude Code's documented order: enterprise > personal > project > plugin.
    var precedence: Int {
        switch self {
        case .enterprise:   return 4
        case .standalone:   return 3
        case .project:      return 2
        case .plugin:       return 1
        }
    }

    var sourceLabel: String {
        switch self {
        case .enterprise:           return "Enterprise"
        case .standalone:           return "Personal"
        case .project(let cwd):     return "Project (\((cwd as NSString).lastPathComponent))"
        case .plugin(let name):     return "Plugin (\(name))"
        }
    }
}

// MARK: - Plugin

struct ClaudePlugin: Identifiable, Hashable {
    let id: String          // e.g. "figma@claude-plugins-official"
    let name: String
    let marketplace: String
    var isEnabled: Bool

    static func == (lhs: ClaudePlugin, rhs: ClaudePlugin) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Hook

struct ClaudeHook: Identifiable, Hashable {
    let id: String
    let event: String
    let commands: [HookCommand]

    struct HookCommand: Identifiable, Hashable {
        let id: UUID
        let command: String
        let matcher: String?
    }

    var eventIcon: String {
        switch event {
        case "SessionStart":        "play.circle"
        case "SessionEnd":          "stop.circle"
        case "UserPromptSubmit":    "text.bubble"
        case "PreToolUse":          "wrench.and.screwdriver"
        case "PostToolUse":         "checkmark.circle"
        case "PostToolUseFailure":  "exclamationmark.triangle"
        case "Stop":                "hand.raised"
        default:                    "bolt"
        }
    }
}

// MARK: - MCP Status

enum MCPStatus: String {
    case running    = "Running"
    case needsAuth  = "Needs Auth"
    case configured = "Configured"
}

extension MCPServer {
    /// Unique key for status lookups — distinguishes same-named MCPs across projects
    var statusKey: String {
        switch transport {
        case .stdio(let cmd, let args):
            return "stdio:\(cmd):\(args.joined(separator: "|"))"
        case .http(let url):
            return "http:\(url)"
        case .sse(let url):
            return "sse:\(url)"
        case .sdk:
            return "sdk:\(name)"
        case .unknown(let t):
            return "unknown:\(t):\(name)"
        }
    }
}

// MARK: - Frontmatter parser

enum SkillFrontmatter {
    /// Extracts just the frontmatter section of a SKILL.md file, without the
    /// surrounding `---` delimiters. Returns nil if no frontmatter is present.
    static func extractFrontmatterBlock(_ text: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        guard let second = lines[(first + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return nil }
        return lines[(first + 1)..<second].joined(separator: "\n")
    }

    /// Everything after the frontmatter block — the Markdown body. Returns the
    /// whole file if no frontmatter exists.
    static func extractBody(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return text }
        return lines[(second + 1)...].joined(separator: "\n")
    }

    /// Parse a YAML scalar or inline list ("[a, b, c]" or "a, b, c") into an array.
    static func parseStringList(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("[") && s.hasSuffix("]") {
            s = String(s.dropFirst().dropLast())
        }
        return s.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
        }.filter { !$0.isEmpty }
    }

    /// Parse a YAML boolean (true/false/yes/no, case-insensitive).
    static func parseBool(_ raw: String?, default fallback: Bool) -> Bool {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return fallback }
        switch raw {
        case "true", "yes", "on", "1":  return true
        case "false", "no", "off", "0": return false
        default:                        return fallback
        }
    }

    /// Parses a SKILL.md YAML frontmatter block into a flat dictionary.
    static func parse(_ text: String) -> [String: String] {
        // Find content between first --- and second ---
        let lines = text.components(separatedBy: "\n")
        guard let firstDash = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return [:]
        }
        guard let secondDash = lines[(firstDash + 1)...].firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else {
            return [:]
        }

        let yamlLines = Array(lines[(firstDash + 1)..<secondDash])
        var result: [String: String] = [:]
        var currentKey: String?
        var currentValue = ""
        var inBlockScalar = false  // BUG-15 fix: track > or | block mode

        for line in yamlLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // BUG-16 fix: detect any leading whitespace, not just 2+ spaces
            let isIndented = line.first?.isWhitespace == true && !trimmed.isEmpty

            if !isIndented, let colonRange = trimmed.range(of: ":") {
                // Save previous
                if let key = currentKey {
                    let val = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !val.isEmpty { result[key] = val }
                }
                currentKey = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
                let afterColon = String(trimmed[colonRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                inBlockScalar = (afterColon == ">" || afterColon == "|")
                currentValue = inBlockScalar ? "" : afterColon
            } else if isIndented, currentKey != nil {
                // BUG-15 fix: in block scalar mode, always append (never parse as nested key)
                if inBlockScalar {
                    currentValue += (currentValue.isEmpty ? "" : " ") + trimmed
                } else if trimmed.contains(":") {
                    // Nested key like "author: name" under metadata
                    if let colonRange = trimmed.range(of: ":") {
                        let subKey = String(trimmed[trimmed.startIndex..<colonRange.lowerBound])
                        let subVal = String(trimmed[colonRange.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "\"", with: "")
                        result[subKey] = subVal
                    }
                } else {
                    // Multiline continuation
                    currentValue += (currentValue.isEmpty ? "" : " ") + trimmed
                }
            }
        }

        // Save last
        if let key = currentKey {
            let val = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\"", with: "")
            if !val.isEmpty { result[key] = val }
        }

        return result
    }
}
