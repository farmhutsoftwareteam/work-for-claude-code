// Sources model context windows from the provider instead of hardcoding
// them. Anthropic's Models API (GET /v1/models) returns `max_input_tokens`
// per model — the authoritative context-window size. We are not the model
// provider, so we read their number rather than baking guesses into Swift.
//
// Requires an API key (x-api-key). When none is available (e.g. OAuth /
// subscription auth), the fetch is skipped and the UI degrades to showing
// raw tokens-in-context with no percentage — never an invented denominator.

import Foundation

enum V2ModelCatalog {

    /// The API key, if the app's environment carries one. OAuth/subscription
    /// setups won't have this — that's expected; callers degrade gracefully.
    static var apiKey: String? {
        let key = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? ""
        return key.isEmpty ? nil : key
    }

    // The committed snapshot bundled in the app (model-windows.json). This is
    // the keyless baseline — every user gets real, provider-sourced numbers
    // without an API key. A live /v1/models fetch overrides it when a key is
    // present. Regenerate the file with scripts/sync-model-windows.sh.
    private struct Snapshot: Decodable {
        let windows: [String: Int]
        let syncedAt: String?
    }

    /// `id → max_input_tokens` from the bundled snapshot, or nil if missing.
    static func bundledWindows() -> [String: Int]? {
        guard let url = Bundle.main.url(forResource: "model-windows", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data),
              !snap.windows.isEmpty
        else { return nil }
        return snap.windows
    }

    // Only the fields we use from the Models API response.
    private struct ModelsResponse: Decodable {
        let data: [ModelInfo]
    }
    private struct ModelInfo: Decodable {
        let id: String
        let maxInputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case id
            case maxInputTokens = "max_input_tokens"
        }
    }

    /// Fetch `id → max_input_tokens` straight from Anthropic. Returns nil on
    /// any failure (no key, network down, auth rejected, empty) so the caller
    /// keeps its last-known cache and the meter falls back to tokens-only.
    static func fetch() async -> [String: Int]? {
        guard let apiKey else { return nil }
        guard var comps = URLComponents(string: "https://api.anthropic.com/v1/models") else { return nil }
        comps.queryItems = [URLQueryItem(name: "limit", value: "1000")]
        guard let url = comps.url else { return nil }

        var req = URLRequest(url: url)
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.timeoutInterval = 12

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let decoded = try JSONDecoder().decode(ModelsResponse.self, from: data)
            var map: [String: Int] = [:]
            for m in decoded.data {
                if let w = m.maxInputTokens, w > 0 { map[m.id] = w }
            }
            return map.isEmpty ? nil : map
        } catch {
            return nil
        }
    }
}
