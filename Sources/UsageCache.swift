import Foundation

// MARK: - Per-session cache for token aggregation
//
// Scanning every JSONL in ~/.claude/projects costs seconds for heavy users.
// Cache each parsed session keyed by absolute file path + mtime. On the next
// load, we compare mtimes and only re-parse the files Claude has actually
// written to since the last run — typically just the active session.
//
// Cache file: ~/Library/Application Support/com.munyamakosa.work/usage-cache.json

struct UsageCacheEntry: Codable {
    let mtime: TimeInterval
    let sessionId: String
    let projectCwd: String?
    let usage: TokenUsage
    /// Day buckets keyed by ISO-8601 start-of-day-UTC string ("2026-04-13T00:00:00Z").
    let byDay: [String: TokenUsage]
}

struct UsageCacheData: Codable {
    /// Version 1: original schema, token totals only.
    /// Version 2 (1.2.0): TokenUsage gains `byModel` for cost attribution.
    ///   v1 caches are invalidated at load time and force a one-time re-parse
    ///   of every session JSONL — the only way to populate byModel for
    ///   previously-cached sessions.
    var version: Int = 2
    var entries: [String: UsageCacheEntry] = [:]   // keyed by absolute jsonl path

    static let empty = UsageCacheData()
}

/// Atomic disk-backed cache. All mutations serialized through the actor.
actor UsageCacheStore {
    private(set) var data: UsageCacheData = .empty
    private let url: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.munyamakosa.work")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("usage-cache.json")
    }

    func load() -> UsageCacheData {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? Data(contentsOf: url),
              !raw.isEmpty,
              let decoded = try? JSONDecoder().decode(UsageCacheData.self, from: raw)
        else {
            data = .empty
            return data
        }
        // Version 2 (1.2.0) added byModel for cost attribution. Pre-v2 rows
        // would render as "$? (unknown model)" forever, so we invalidate and
        // force one re-parse on first launch after upgrade.
        if decoded.version != 2 {
            NSLog("[Work] Usage cache version %d → invalidating (1.2.0 migration to v2).", decoded.version)
            data = .empty
            return data
        }
        data = decoded
        return decoded
    }

    func save(_ newData: UsageCacheData) {
        data = newData
        do {
            let encoder = JSONEncoder()
            // Compact (no pretty-printing) — this file can grow large with many sessions
            let bytes = try encoder.encode(newData)
            try bytes.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode_t(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // Best-effort — cache is performance, not correctness
        }
    }
}

// MARK: - ISO-8601 helpers shared across cache <-> aggregator

enum UsageCacheDateCoder {
    /// `nonisolated(unsafe)` for the same reason UsageAggregator's instance is —
    /// ISO8601DateFormatter is documented thread-safe but isn't Sendable in the SDK.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(from date: Date) -> String { iso8601.string(from: date) }
    static func date(from string: String) -> Date? { iso8601.date(from: string) }
}
