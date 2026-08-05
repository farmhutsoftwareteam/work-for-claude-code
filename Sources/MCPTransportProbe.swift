import Foundation

/// Detects the MCP transport for a single user-supplied string, so the Add flow
/// can be ONE field instead of a stdio/HTTP/SSE picker. Forcing users to declare
/// the transport is the single most pervasive MCP-setup anti-pattern (per the
/// 2026-08 deep-research report), and the MCP spec itself prescribes this
/// client-side detection probe — so making the user choose is a UX decision, not
/// a protocol necessity. Model-layer only: no UI, no app state, no main-actor
/// isolation (the probe runs off the main thread).
enum MCPTransportProbe {

    /// What an input was detected to be.
    enum Result: Equatable {
        case stdio(command: String, args: [String])
        case http(url: String)   // modern Streamable HTTP
        case sse(url: String)    // deprecated HTTP+SSE

        var transport: MCPServer.Transport {
            switch self {
            case .stdio(let c, let a): return .stdio(command: c, args: a)
            case .http(let u):         return .http(url: u)
            case .sse(let u):          return .sse(url: u)
            }
        }
    }

    /// True when the input looks like a remote endpoint (an http/https URL)
    /// rather than a local command — the cheap synchronous discriminator.
    static func looksRemote(_ input: String) -> Bool {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.hasPrefix("http://") || t.hasPrefix("https://")
    }

    /// Instant, no-network classification for live UI feedback: a URL is
    /// assumed modern Streamable HTTP; anything else is a local command split
    /// into command + args. Whitespace split covers the common `npx -y pkg`
    /// case; quoted/complex commands are handled by the advanced editor.
    static func classify(_ input: String) -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if looksRemote(trimmed) { return .http(url: trimmed) }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        return .stdio(command: parts.first ?? "", args: Array(parts.dropFirst()))
    }

    /// Full detection. A local command is just `classify`. A remote URL runs
    /// the MCP spec's backwards-compatibility probe:
    ///   1. POST an InitializeRequest. A live HTTP endpoint — 2xx, or an auth
    ///      challenge (401/403), or even a 5xx — means modern Streamable HTTP.
    ///   2. Only a 400/404/405 suggests an old server, so GET with
    ///      `Accept: text/event-stream`; an event-stream reply ⇒ deprecated SSE.
    ///   3. Anything inconclusive (unreachable / timeout) defaults to modern
    ///      `.http` — SSE is deprecated, and add-time validation (Stage 3) is
    ///      what catches a genuinely dead URL.
    ///
    /// Uses `bytes(for:)` (not `data(for:)`) so we act on the response HEAD the
    /// moment it arrives and never consume the body — a Streamable-HTTP server
    /// that answers `initialize` with an SSE stream would otherwise block us
    /// until the timeout.
    static func detect(_ input: String, timeout: TimeInterval = 5) async -> Result {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksRemote(trimmed), let url = URL(string: trimmed) else {
            return classify(trimmed)
        }
        let session = URLSession(configuration: config(timeout))
        defer { session.invalidateAndCancel() }

        var post = URLRequest(url: url)
        post.httpMethod = "POST"
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        post.httpBody = initializeBody
        guard let (_, postResp) = try? await session.bytes(for: post),
              let postHTTP = postResp as? HTTPURLResponse else {
            return .http(url: trimmed)   // unreachable / timeout → default modern
        }
        switch postHTTP.statusCode {
        case 400, 404, 405:
            break                        // maybe a legacy SSE server — probe below
        default:
            return .http(url: trimmed)   // 2xx / 401 / 403 / 5xx: a live HTTP endpoint
        }

        var get = URLRequest(url: url)
        get.httpMethod = "GET"
        get.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let (_, getResp) = try? await session.bytes(for: get),
           let getHTTP = getResp as? HTTPURLResponse,
           (getHTTP.value(forHTTPHeaderField: "Content-Type") ?? "")
               .localizedCaseInsensitiveContains("text/event-stream") {
            return .sse(url: trimmed)
        }
        return .http(url: trimmed)
    }

    // MARK: - Internals

    private static func config(_ timeout: TimeInterval) -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = timeout
        c.timeoutIntervalForResource = timeout
        c.waitsForConnectivity = false
        return c
    }

    /// A minimal JSON-RPC `initialize` — enough for a server to answer the
    /// detection probe. Built once.
    private static let initializeBody: Data = {
        let version = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let obj: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 0,
            "method": "initialize",
            "params": [
                "protocolVersion": "2025-06-18",
                "capabilities": [String: Any](),
                "clientInfo": ["name": "Atelier", "version": version],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }()
}
