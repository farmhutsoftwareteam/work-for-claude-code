import Foundation

// MARK: - Remote pricing fetcher
//
// Pulls a fresh `pricing.json` from work.munyamakosa.com on app launch (and
// can be re-triggered post-Sparkle update). Decoded prices replace the
// `Pricing.liveTable` in memory. Disk-cached for 24h so offline / slow
// launches don't burn the fetch budget every time.
//
// Failure modes are all silent fallbacks to whichever table is currently
// live (cached file → embedded table). Sarah never sees a broken Usage tab
// because pricing.json was 500-ing.
//
// The fetcher is an actor so the swap-into-Pricing race doesn't matter —
// Pricing.liveTable is set on the main thread via an explicit @MainActor
// hop after decoding succeeds.

actor PricingFetcher {
    static let shared = PricingFetcher()

    private let remoteURL = URL(string: "https://work.munyamakosa.com/pricing.json")!
    private let cacheTTL: TimeInterval = 24 * 60 * 60  // 24h
    private let timeoutSeconds: TimeInterval = 5

    private var cacheURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.munyamakosa.work")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("pricing.json")
    }

    /// Call once on app launch (and again post-Sparkle update if you want
    /// instant-after-update). Silent on failure.
    func fetchIfStale() async {
        // First, try the disk cache. If it's fresh, swap it in immediately so
        // the UI uses the freshest known prices without waiting on network.
        if let cached = readCachedTableIfFresh() {
            await MainActor.run { Pricing.liveTable = cached }
            // Still attempt a refresh in the background — silent on failure.
        }

        do {
            let table = try await fetchRemote()
            await MainActor.run { Pricing.liveTable = table }
            writeCacheFromCurrentResponse(table)
        } catch {
            // Silent fallback. Whatever's currently in Pricing.liveTable
            // (cache or embedded) is fine — never crash on a pricing miss.
            Diagnostics.record(
                severity: .warning, subsystem: .network, operation: .pricingFetch, outcome: .failed,
                code: "fetch-failed"
            )
        }
    }

    // MARK: - Remote

    private func fetchRemote() async throws -> [String: ModelPrice] {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FetchError.badStatus
        }
        return try Self.decode(data)
    }

    // MARK: - Cache

    private func readCachedTableIfFresh() -> [String: ModelPrice]? {
        let url = cacheURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attrs[.modificationDate] as? Date,
              Date().timeIntervalSince(mtime) < cacheTTL,
              let raw = try? Data(contentsOf: url)
        else { return nil }
        return try? Self.decode(raw)
    }

    private func writeCacheFromCurrentResponse(_ table: [String: ModelPrice]) {
        // We re-encode our own struct rather than caching the raw response
        // bytes — that way the cache is always in a shape we know how to read.
        guard let payload = try? JSONEncoder().encode(EncodedTable(from: table)) else { return }
        try? payload.write(to: cacheURL, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode_t(0o600))],
            ofItemAtPath: cacheURL.path
        )
    }

    // MARK: - Decode

    private struct WirePrice: Codable {
        let input: String
        let output: String
        let cacheWrite5m: String
        let cacheWrite1h: String
        let cacheRead: String
    }

    private struct WireTable: Decodable {
        let version: String?
        let currency: String?
        let unit: String?
        let models: [String: WirePrice]
    }

    /// On-disk cache shape — mirrors the wire shape so we can reuse the
    /// same decoder for both. Strings, not numbers, for Decimal precision.
    private struct EncodedTable: Encodable {
        let version: String
        let currency: String
        let unit: String
        let models: [String: WirePrice]

        init(from table: [String: ModelPrice]) {
            self.version = "cached"
            self.currency = "USD"
            self.unit = "per_million_tokens"
            self.models = Dictionary(uniqueKeysWithValues: table.map { (key, price) in
                (key, WirePrice(
                    input: String(describing: price.inputPerMTok),
                    output: String(describing: price.outputPerMTok),
                    cacheWrite5m: String(describing: price.cacheWrite5mPerMTok),
                    cacheWrite1h: String(describing: price.cacheWrite1hPerMTok),
                    cacheRead: String(describing: price.cacheReadPerMTok)
                ))
            })
        }
    }

    private static func decode(_ data: Data) throws -> [String: ModelPrice] {
        let wire = try JSONDecoder().decode(WireTable.self, from: data)
        var out: [String: ModelPrice] = [:]
        for (model, prices) in wire.models {
            guard let input = Decimal(string: prices.input),
                  let output = Decimal(string: prices.output),
                  let cw5m = Decimal(string: prices.cacheWrite5m),
                  let cw1h = Decimal(string: prices.cacheWrite1h),
                  let cr = Decimal(string: prices.cacheRead)
            else {
                // A single malformed row rejects the whole table — partial
                // tables are worse than falling back to embedded prices.
                throw FetchError.malformedRow(model)
            }
            out[model] = ModelPrice(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheWrite5mPerMTok: cw5m,
                cacheWrite1hPerMTok: cw1h,
                cacheReadPerMTok: cr
            )
        }
        return out
    }

    enum FetchError: Error {
        case badStatus
        case malformedRow(String)
    }
}
