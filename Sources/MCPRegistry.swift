import Foundation

// MARK: - Registry models

struct RegistryMCP: Identifiable, Sendable {
    let id: String  // name + "@" + version
    let name: String
    let description: String
    let version: String
    let repositoryURL: String?
    let websiteURL: String?
    let packages: [Package]
    let remotes: [Remote]

    struct Package: Sendable, Hashable {
        let registryType: String       // "npm", "pypi", "oci"
        let identifier: String         // "@supabase/mcp-server-supabase"
        let packageVersion: String?
        let transport: String          // "stdio"
        let environmentVariables: [EnvRequirement]
    }

    struct Remote: Sendable, Hashable {
        let type: String               // "streamable-http", "sse"
        let url: String
        let headers: [HeaderRequirement]
    }

    struct EnvRequirement: Sendable, Hashable {
        let name: String
        let description: String
        let isRequired: Bool
        let isSecret: Bool
    }

    struct HeaderRequirement: Sendable, Hashable {
        let name: String
        let description: String
        let value: String              // e.g. "Bearer {api_key}"
        let isRequired: Bool
        let isSecret: Bool
    }

    /// A simple display-friendly short name, stripping common namespace prefixes.
    /// Uses the last path component, so "org/group/name" → "name".
    var displayName: String {
        if let slash = name.lastIndex(of: "/") {
            return String(name[name.index(after: slash)...])
        }
        return name
    }

    /// True if this entry has at least one installable option we support
    var hasInstallableOption: Bool {
        !packages.filter { ["npm", "pypi"].contains($0.registryType) }.isEmpty
            || !remotes.filter { ["streamable-http", "sse"].contains($0.type) }.isEmpty
    }
}

// MARK: - Registry client

enum MCPRegistry {
    // Hardcoded base URL — known valid at compile time
    private static let baseURLString = "https://registry.modelcontextprotocol.io"

    enum RegistryError: LocalizedError {
        case invalidResponse(status: Int?, body: String?)
        case networkError(Error)

        var errorDescription: String? {
            switch self {
            case .invalidResponse(let status, let body):
                if let s = status {
                    let snippet = body.map { " — \($0.prefix(200))" } ?? ""
                    return "Registry returned HTTP \(s)\(snippet)"
                }
                return "Registry returned an unexpected response."
            case .networkError(let err): return "Network error: \(err.localizedDescription)"
            }
        }
    }

    /// Fetch MCPs from the official registry. Search is case-insensitive substring on name.
    static func search(query: String? = nil, limit: Int = 50) async throws -> [RegistryMCP] {
        guard let base = URL(string: baseURLString),
              var components = URLComponents(url: base.appendingPathComponent("/v0/servers"), resolvingAgainstBaseURL: false) else {
            throw RegistryError.invalidResponse(status: nil, body: "Failed to construct registry URL")
        }
        var items: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(max(1, limit)))]
        if let q = query, !q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append(URLQueryItem(name: "search", value: q))
        }
        items.append(URLQueryItem(name: "version", value: "latest"))
        components.queryItems = items

        guard let url = components.url else {
            throw RegistryError.invalidResponse(status: nil, body: "Failed to construct registry URL")
        }

        // 15-second timeout; URLSession still supports cancellation via Swift concurrency
        var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        // Respect cancellation that arrived during the network call
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw RegistryError.invalidResponse(status: nil, body: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw RegistryError.invalidResponse(status: http.statusCode, body: body)
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = obj["servers"] as? [[String: Any]] else {
            throw RegistryError.invalidResponse(status: http.statusCode, body: "Response shape not recognized")
        }

        var seen: Set<String> = []
        var result: [RegistryMCP] = []
        for entry in servers {
            guard let parsed = parse(entry: entry) else { continue }
            // Registry already filters to latest via ?version=latest; first seen wins.
            if seen.contains(parsed.name) { continue }
            seen.insert(parsed.name)
            if parsed.hasInstallableOption {
                result.append(parsed)
            }
        }
        return result
    }

    // MARK: - Parsing

    private static func parse(entry: [String: Any]) -> RegistryMCP? {
        guard let server = entry["server"] as? [String: Any],
              let name = server["name"] as? String else {
            return nil
        }

        let description = server["description"] as? String ?? ""
        let version = server["version"] as? String ?? "0.0.0"
        let repo = (server["repository"] as? [String: Any])?["url"] as? String
        let website = server["websiteUrl"] as? String

        let packages = (server["packages"] as? [[String: Any]] ?? []).compactMap(parsePackage)
        let remotes = (server["remotes"] as? [[String: Any]] ?? []).compactMap(parseRemote)

        return RegistryMCP(
            id: "\(name)@\(version)",
            name: name,
            description: description,
            version: version,
            repositoryURL: repo,
            websiteURL: website,
            packages: packages,
            remotes: remotes
        )
    }

    private static func parsePackage(_ p: [String: Any]) -> RegistryMCP.Package? {
        guard let identifier = p["identifier"] as? String,
              let registryType = p["registryType"] as? String else { return nil }
        let version = p["version"] as? String
        let transport = (p["transport"] as? [String: Any])?["type"] as? String ?? "stdio"
        let envs = (p["environmentVariables"] as? [[String: Any]] ?? []).compactMap(parseEnv)
        return RegistryMCP.Package(
            registryType: registryType,
            identifier: identifier,
            packageVersion: version,
            transport: transport,
            environmentVariables: envs
        )
    }

    private static func parseRemote(_ r: [String: Any]) -> RegistryMCP.Remote? {
        guard let type = r["type"] as? String,
              let url = r["url"] as? String else { return nil }
        let headers = (r["headers"] as? [[String: Any]] ?? []).compactMap(parseHeader)
        return RegistryMCP.Remote(type: type, url: url, headers: headers)
    }

    private static func parseEnv(_ e: [String: Any]) -> RegistryMCP.EnvRequirement? {
        guard let name = e["name"] as? String else { return nil }
        return RegistryMCP.EnvRequirement(
            name: name,
            description: e["description"] as? String ?? "",
            isRequired: e["isRequired"] as? Bool ?? false,
            isSecret: e["isSecret"] as? Bool ?? false
        )
    }

    private static func parseHeader(_ h: [String: Any]) -> RegistryMCP.HeaderRequirement? {
        guard let name = h["name"] as? String else { return nil }
        return RegistryMCP.HeaderRequirement(
            name: name,
            description: h["description"] as? String ?? "",
            value: h["value"] as? String ?? "",
            isRequired: h["isRequired"] as? Bool ?? false,
            isSecret: h["isSecret"] as? Bool ?? false
        )
    }
}

// MARK: - Registry → MCPDraft translation

extension MCPRegistry {
    /// Build a ready-to-save MCPDraft from a registry entry and one of its install options.
    /// Returns nil if the install option isn't supported (e.g. OCI images for now).
    static func makeDraft(
        from mcp: RegistryMCP,
        package: RegistryMCP.Package? = nil,
        remote: RegistryMCP.Remote? = nil,
        customName: String? = nil
    ) -> MCPDraft? {
        let name = customName ?? sanitizedName(from: mcp.displayName)

        if let pkg = package {
            switch pkg.registryType {
            case "npm":
                // Guard against registry-provided identifiers that could inject npx flags.
                // Valid npm names: optional @scope/, then letters/digits/_-./
                guard isSafeNpmIdentifier(pkg.identifier) else { return nil }

                let versionSuffix: String
                if let v = pkg.packageVersion, !v.isEmpty {
                    versionSuffix = "@\(v)"
                } else {
                    versionSuffix = "@latest"
                }
                let args = ["-y", pkg.identifier + versionSuffix]
                var env: [String: String] = [:]
                for req in pkg.environmentVariables {
                    env[req.name] = ""
                }
                return MCPDraft(
                    name: name,
                    transport: .stdio(command: "npx", args: args),
                    env: env
                )
            case "pypi":
                guard isSafePypiIdentifier(pkg.identifier) else { return nil }
                var env: [String: String] = [:]
                for req in pkg.environmentVariables { env[req.name] = "" }
                return MCPDraft(
                    name: name,
                    transport: .stdio(command: "uvx", args: [pkg.identifier]),
                    env: env
                )
            default:
                return nil
            }
        }

        if let rem = remote {
            let transport: MCPServer.Transport
            switch rem.type {
            case "streamable-http", "http":
                transport = .http(url: rem.url)
            case "sse":
                transport = .sse(url: rem.url)
            default:
                return nil
            }
            return MCPDraft(name: name, transport: transport, env: [:])
        }

        return nil
    }

    // MARK: - Identifier validators

    private static func sanitizedName(from input: String) -> String {
        // Allow only letters, digits, dot, underscore, hyphen (matches MCPConfigWriter regex).
        // Replace anything else with "-", collapse runs, lowercase, trim.
        let allowed = input.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-" { return ch }
            return "-"
        }
        let collapsed = String(allowed).replacingOccurrences(
            of: "-+", with: "-", options: .regularExpression
        ).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let result = collapsed.lowercased()
        return result.isEmpty ? "mcp-server" : result
    }

    private static let npmIdentifierRegex = try! NSRegularExpression(
        pattern: #"^(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$"#,
        options: [.caseInsensitive]
    )

    private static func isSafeNpmIdentifier(_ identifier: String) -> Bool {
        // Reject if it starts with a dash (would be parsed as npx flag)
        if identifier.hasPrefix("-") { return false }
        let range = NSRange(location: 0, length: identifier.utf16.count)
        return npmIdentifierRegex.firstMatch(in: identifier, options: [], range: range) != nil
    }

    private static func isSafePypiIdentifier(_ identifier: String) -> Bool {
        // PyPI package names: letters, digits, underscore, hyphen, dot
        if identifier.hasPrefix("-") { return false }
        return identifier.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
    }
}
