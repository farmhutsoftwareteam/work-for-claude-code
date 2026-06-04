import Foundation

// MARK: - Draft model used by the editor

struct MCPDraft {
    var name: String
    var transport: MCPServer.Transport
    var env: [String: String]
    /// http / sse only — extra request headers (Bearer tokens, X-API-Key …).
    var headers: [String: String]
    /// http / sse only — pre-configured OAuth, for servers that don't support
    /// Dynamic Client Registration. Empty config means "use server defaults."
    var oauth: OAuthConfig
    /// Any transport — keep tools eagerly in context (skip Tool Search).
    var alwaysLoad: Bool
    /// Any transport — per-server tool call timeout. nil = use Claude's
    /// default (60s). UI collects seconds, writer emits milliseconds.
    var timeoutMs: Int?

    /// Explicit init so existing call sites (Integrations panel catalog,
    /// marketplace install) that predate the Phase-1.1 fields can keep
    /// constructing drafts with just `name + transport + env`.
    init(
        name: String,
        transport: MCPServer.Transport,
        env: [String: String] = [:],
        headers: [String: String] = [:],
        oauth: OAuthConfig = OAuthConfig(),
        alwaysLoad: Bool = false,
        timeoutMs: Int? = nil
    ) {
        self.name = name
        self.transport = transport
        self.env = env
        self.headers = headers
        self.oauth = oauth
        self.alwaysLoad = alwaysLoad
        self.timeoutMs = timeoutMs
    }

    static func empty(type: String = "stdio") -> MCPDraft {
        MCPDraft(
            name: "",
            transport: type == "stdio"
                ? .stdio(command: "", args: [])
                : type == "http" ? .http(url: "")
                : .sse(url: ""),
            env: [:],
            headers: [:],
            oauth: OAuthConfig(),
            alwaysLoad: false,
            timeoutMs: nil
        )
    }

    static func from(_ mcp: MCPServer) -> MCPDraft {
        MCPDraft(
            name: mcp.name,
            transport: mcp.transport,
            env: mcp.env ?? [:],
            headers: mcp.headers ?? [:],
            oauth: mcp.oauth ?? OAuthConfig(),
            alwaysLoad: mcp.alwaysLoad ?? false,
            timeoutMs: mcp.timeoutMs
        )
    }
}

// MARK: - Writer service

enum MCPConfigWriter {

    /// One of the three scopes Claude Code recognizes. `.global` is preserved
    /// as a synonym for `.user` to keep existing call sites compiling while we
    /// gradually migrate them. The two values are `Equatable` and resolve to
    /// the same on-disk location.
    enum Scope: Equatable {
        /// `~/.claude.json` top-level `mcpServers` — loads in every project.
        case user
        /// `~/.claude.json` → `projects.<cwd>.mcpServers` — loads only in
        /// the given project, private to the user. This is the default of
        /// `claude mcp add`.
        case local(cwd: String)
        /// `<cwd>/.mcp.json` — shared with the team via version control.
        case project(cwd: String)

        /// Older name for `.user`. Kept so existing UI / tests compile.
        /// New code should prefer `.user`.
        static var global: Scope { .user }

        /// File the JSON config lives in for this scope. The two
        /// `~/.claude.json`-backed scopes (`.user` and `.local`) share the
        /// same file but write into different sub-trees — that's handled
        /// in `coordinatedReadWrite`, not here.
        var configURL: URL {
            let home = FileManager.default.homeDirectoryForCurrentUser
            switch self {
            case .user, .local:
                return home.appendingPathComponent(".claude.json")
            case .project(let cwd):
                return URL(fileURLWithPath: cwd).appendingPathComponent(".mcp.json")
            }
        }

        /// Stable identifier suitable for Picker tags + UI dedupe. The
        /// project-scoped cases include the cwd so two different projects
        /// don't collide.
        var stableKey: String {
            switch self {
            case .user:                  return "user"
            case .local(let cwd):        return "local:\(cwd)"
            case .project(let cwd):      return "project:\(cwd)"
            }
        }
    }

    enum WriteError: LocalizedError {
        case invalidName(String)
        case invalidConfig(String)
        case invalidScope(String)
        case malformedConfig(String)
        case ioError(Error)
        case duplicateName(String)

        var errorDescription: String? {
            switch self {
            case .invalidName(let msg): return "Invalid name: \(msg)"
            case .invalidConfig(let msg): return msg
            case .invalidScope(let msg): return msg
            case .malformedConfig(let msg): return "Config file is malformed: \(msg)"
            case .ioError(let err): return "Failed to write config: \(err.localizedDescription)"
            case .duplicateName(let name): return "An MCP named '\(name)' already exists in this scope."
            }
        }
    }

    // MARK: - Save

    /// Save a draft MCP. If `originalName` is non-nil, replaces that entry; otherwise adds a new one.
    static func save(_ draft: MCPDraft, scope: Scope, originalName: String? = nil) throws {
        try validate(draft)
        try validateScope(scope)

        try mutateMCPServers(scope: scope) { mcpServers in
            // Duplicate check when adding
            if originalName == nil, mcpServers[draft.name] != nil {
                throw WriteError.duplicateName(draft.name)
            }

            // Rename — also reject if the new name collides with an unrelated
            // existing entry, otherwise we'd silently overwrite someone else.
            if let original = originalName, original != draft.name {
                if mcpServers[draft.name] != nil {
                    throw WriteError.duplicateName(draft.name)
                }
                mcpServers.removeValue(forKey: original)
            }

            mcpServers[draft.name] = buildConfigDict(for: draft)
        }
    }

    /// Delete an MCP by name from the given scope.
    static func delete(name: String, scope: Scope) throws {
        try validateScope(scope)
        try mutateMCPServers(scope: scope) { mcpServers in
            mcpServers.removeValue(forKey: name)
        }
    }

    /// Apply `mutator` to the right `mcpServers` dict for `scope`, then write
    /// the whole config back. Hides the difference between:
    ///
    /// - `.user`:     `~/.claude.json` → root `mcpServers`
    /// - `.local`:    `~/.claude.json` → `projects[cwd].mcpServers`
    /// - `.project`:  `<cwd>/.mcp.json` → root `mcpServers` (or flat layout)
    ///
    /// The mutator only sees the dict it's modifying — wrapper handles
    /// extraction + write-back at the right path.
    private static func mutateMCPServers(
        scope: Scope,
        mutator: (inout [String: Any]) throws -> Void
    ) throws {
        try coordinatedReadWrite(scope: scope) { rootRef, flatInfo in
            switch scope {
            case .user, .project:
                // Existing flow: mcpServers lives at the root of the file.
                var mcpServers = try extractMCPServers(from: rootRef.pointee)
                try mutator(&mcpServers)
                if flatInfo {
                    rootRef.pointee = mcpServers
                } else {
                    rootRef.pointee["mcpServers"] = mcpServers
                }

            case .local(let cwd):
                // Dive into `projects.<cwd>.mcpServers`. Preserve every
                // sibling key under that project entry (Claude Code stores
                // trust state, allowed tools, last-used timestamps there).
                var projects = (rootRef.pointee["projects"] as? [String: Any]) ?? [:]
                var projectEntry = (projects[cwd] as? [String: Any]) ?? [:]
                var mcpServers = (projectEntry["mcpServers"] as? [String: Any]) ?? [:]
                try mutator(&mcpServers)
                if mcpServers.isEmpty {
                    projectEntry.removeValue(forKey: "mcpServers")
                } else {
                    projectEntry["mcpServers"] = mcpServers
                }
                projects[cwd] = projectEntry
                rootRef.pointee["projects"] = projects
            }
        }
    }

    // MARK: - Validation

    private static let validNameRegex = try! NSRegularExpression(
        pattern: "^[A-Za-z0-9_.\\-]+$"
    )

    private static func validate(_ draft: MCPDraft) throws {
        let trimmed = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WriteError.invalidName("Name cannot be empty")
        }
        guard trimmed == draft.name else {
            throw WriteError.invalidName("Name cannot have leading/trailing whitespace")
        }
        let range = NSRange(location: 0, length: trimmed.utf16.count)
        guard validNameRegex.firstMatch(in: trimmed, options: [], range: range) != nil else {
            throw WriteError.invalidName("Name must be letters, digits, '_', '-' or '.' only")
        }

        switch draft.transport {
        case .stdio(let cmd, _):
            guard !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw WriteError.invalidConfig("Command cannot be empty for stdio MCPs")
            }
        case .http(let url), .sse(let url):
            let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedURL.isEmpty else {
                throw WriteError.invalidConfig("URL cannot be empty")
            }
            guard let parsed = URL(string: trimmedURL),
                  let scheme = parsed.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                throw WriteError.invalidConfig("URL must use http:// or https:// scheme")
            }
        case .sdk, .unknown:
            throw WriteError.invalidConfig("Cannot save MCPs of type sdk/unknown")
        }
    }

    private static func validateScope(_ scope: Scope) throws {
        // Both .project and .local carry a cwd that has to be a real
        // absolute directory path on disk. .user has no path to validate.
        let cwd: String? = {
            switch scope {
            case .project(let c): return c
            case .local(let c):   return c
            case .user:           return nil
            }
        }()
        guard let cwd else { return }

        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WriteError.invalidScope("Project path cannot be empty")
        }
        guard trimmed.hasPrefix("/") else {
            throw WriteError.invalidScope("Project path must be absolute (got '\(trimmed)')")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: trimmed, isDirectory: &isDir), isDir.boolValue else {
            throw WriteError.invalidScope("Project path does not exist or is not a directory: \(trimmed)")
        }
    }

    /// Build the JSON-serializable config dict for a draft. Transport-specific
    /// keys come first (type/command/args/url), then transport-aware extras
    /// (env for stdio, headers + oauth for http/sse), then common knobs
    /// (alwaysLoad, timeout) that apply to any transport.
    private static func buildConfigDict(for draft: MCPDraft) -> [String: Any] {
        var config: [String: Any] = [:]

        switch draft.transport {
        case .stdio(let cmd, let args):
            config["type"] = "stdio"
            config["command"] = cmd
            config["args"] = args
            // Only stdio transports carry env vars; filter empty keys AND values
            let nonEmptyEnv = draft.env.filter { !$0.key.isEmpty && !$0.value.isEmpty }
            if !nonEmptyEnv.isEmpty {
                config["env"] = nonEmptyEnv
            }
        case .http(let url):
            config["type"] = "http"
            config["url"] = url
            emitHTTPExtras(draft: draft, into: &config)
        case .sse(let url):
            config["type"] = "sse"
            config["url"] = url
            emitHTTPExtras(draft: draft, into: &config)
        case .sdk, .unknown:
            break // validate() prevents this
        }

        // Common: alwaysLoad and timeout apply to every transport.
        if draft.alwaysLoad {
            config["alwaysLoad"] = true
        }
        if let ms = draft.timeoutMs, ms > 0 {
            config["timeout"] = ms
        }

        return config
    }

    /// Serialize the http/sse-only extras (headers + oauth) into `config`.
    /// Both are omitted when empty so we don't leave dead keys in the JSON.
    private static func emitHTTPExtras(draft: MCPDraft, into config: inout [String: Any]) {
        let nonEmptyHeaders = draft.headers.filter { !$0.key.isEmpty && !$0.value.isEmpty }
        if !nonEmptyHeaders.isEmpty {
            config["headers"] = nonEmptyHeaders
        }
        if !draft.oauth.isEmpty {
            var oauth: [String: Any] = [:]
            if let v = draft.oauth.clientId, !v.isEmpty { oauth["clientId"] = v }
            if let p = draft.oauth.callbackPort { oauth["callbackPort"] = p }
            if let v = draft.oauth.scopes, !v.isEmpty { oauth["scopes"] = v }
            if let v = draft.oauth.authServerMetadataUrl, !v.isEmpty {
                oauth["authServerMetadataUrl"] = v
            }
            if !oauth.isEmpty {
                config["oauth"] = oauth
            }
        }
    }

    // MARK: - Extract + validate mcpServers

    /// Given the root JSON object (wrapped or flat), return the mcpServers dict.
    /// Throws if the key exists but isn't a dict — prevents silent data loss.
    private static func extractMCPServers(from root: [String: Any]) throws -> [String: Any] {
        if let wrapped = root["mcpServers"] {
            guard let dict = wrapped as? [String: Any] else {
                throw WriteError.malformedConfig("'mcpServers' must be an object")
            }
            return dict
        }
        return [:]
    }

    // MARK: - Coordinated read-write

    /// Perform a coordinated read-modify-write on the config file using NSFileCoordinator
    /// to serialize access with other writers (Claude Code CLI, other instances of the app).
    /// The mutator is given a pointer to the root dict (which it may rewrite entirely) and
    /// a bool indicating whether the original file was in the legacy flat .mcp.json format.
    private static func coordinatedReadWrite(
        scope: Scope,
        mutator: (UnsafeMutablePointer<[String: Any]>, Bool) throws -> Void
    ) throws {
        let url = scope.configURL
        let coordinator = NSFileCoordinator()
        var coordinatorError: NSError?
        var thrownError: Error?

        coordinator.coordinate(
            writingItemAt: url,
            options: [],
            error: &coordinatorError
        ) { writeURL in
            do {
                // Read current state
                let (root, isFlat) = try readRootWithLayout(at: writeURL, scope: scope)

                // Apply mutation
                var mutableRoot = root
                try withUnsafeMutablePointer(to: &mutableRoot) { ptr in
                    try mutator(ptr, isFlat)
                }

                // Write back
                try writeRoot(mutableRoot, to: writeURL)
            } catch {
                thrownError = error
            }
        }

        if let err = coordinatorError { throw WriteError.ioError(err) }
        if let err = thrownError {
            if let writeErr = err as? WriteError { throw writeErr }
            throw WriteError.ioError(err)
        }
    }

    // MARK: - Read

    /// Read the top-level JSON object from disk, along with whether the layout was "flat"
    /// (project .mcp.json with no mcpServers wrapper — a legacy format).
    /// Throws WriteError.malformedConfig if the file exists but isn't a JSON object.
    private static func readRootWithLayout(at url: URL, scope: Scope) throws -> (root: [String: Any], isFlat: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ([:], false)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WriteError.ioError(error)
        }

        // Empty file → treat as fresh (wrapped format)
        guard !data.isEmpty else { return ([:], false) }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw WriteError.malformedConfig("Not valid JSON: \(error.localizedDescription)")
        }

        guard let obj = parsed as? [String: Any] else {
            throw WriteError.malformedConfig("Top-level JSON must be an object")
        }

        // For .mcp.json project scope, detect legacy flat format (top-level IS mcpServers)
        if case .project = scope, obj["mcpServers"] == nil && !obj.isEmpty {
            // Flat format: every value is an MCP config dict. If ANY value
            // doesn't look like an MCP, reject the write rather than silently
            // breaking the file — the user likely has a hand-edited file we
            // don't understand, and appending an `mcpServers` wrapper next
            // to those keys would desync the file from what Claude reads.
            let mcpLikeCount = obj.values.filter { value in
                guard let d = value as? [String: Any] else { return false }
                return d["type"] != nil || d["command"] != nil || d["url"] != nil
            }.count
            if mcpLikeCount == obj.count {
                return (obj, true)
            }
            if mcpLikeCount > 0 {
                throw WriteError.malformedConfig(
                    ".mcp.json mixes MCP and non-MCP top-level keys. Move your MCPs under an 'mcpServers' object and retry."
                )
            }
            // Zero MCP-shaped keys — treat as a regular object where we'll
            // add `mcpServers` alongside whatever the user had.
            return (obj, false)
        }

        return (obj, false)
    }

    // MARK: - Write

    private static func writeRoot(_ root: [String: Any], to url: URL) throws {
        do {
            // Ensure parent directory exists
            let parent = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent, withIntermediateDirectories: true
            )

            // Pretty-printed, but NOT sorted. `~/.claude.json` is a user-owned
            // file that also contains non-MCP keys Claude CLI writes; sorting
            // would shuffle their order on every save. Dict key iteration order
            // is still effectively random, but at least we don't force it.
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted]
            )

            // Atomic write — temp file + rename. Claude CLI doesn't participate
            // in NSFileCoordinator, so there's a tiny residual race if it writes
            // concurrently; in practice Claude only writes on command, not
            // continuously, so the window is narrow.
            try data.write(to: url, options: .atomic)

            // Tighten permissions to 0600 — config may contain secrets in env
            // vars. Use mode_t (UInt16) and surface failures; a chmod failure
            // on a user-owned config file should only happen if permissions
            // are already wrong, and we want to know about it.
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode_t(0o600))],
                ofItemAtPath: url.path
            )
        } catch let error as WriteError {
            throw error
        } catch {
            throw WriteError.ioError(error)
        }
    }
}
