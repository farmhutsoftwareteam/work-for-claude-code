import Foundation

// MARK: - Aggregated token usage across sessions and projects

struct ProjectUsage: Identifiable, Equatable, Sendable {
    let projectCwd: String
    var usage: TokenUsage
    var sessionCount: Int

    var id: String { projectCwd }
}

struct SessionUsage: Identifiable, Equatable, Sendable {
    let sessionId: String
    let projectCwd: String
    var usage: TokenUsage

    /// Composite id — sessionId alone can collide across projects in edge cases.
    var id: String { "\(projectCwd)::\(sessionId)" }
}

struct UsageTotals: Sendable {
    var total: TokenUsage = .zero
    var byProject: [String: ProjectUsage] = [:]
    var bySession: [String: SessionUsage] = [:]  // keyed by composite id
    var byDay: [Date: TokenUsage] = [:]          // keyed by start-of-day (UTC)
}

/// Time-window selection for the Usage view.
enum UsageRange: String, CaseIterable, Identifiable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"
    var id: String { rawValue }

    /// Inclusive start date — anything older is excluded. `nil` means "no lower bound" (All).
    func start(from now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .week:  return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now))
        case .year:  return calendar.date(byAdding: .day, value: -364, to: calendar.startOfDay(for: now))
        case .all:   return nil
        }
    }

    /// How many trailing days to render in the chart for this range.
    var chartBucketCount: Int {
        switch self {
        case .week:  return 7
        case .month: return 30
        case .year:  return 12  // monthly buckets
        case .all:   return 0
        }
    }
}

// MARK: - Aggregator

enum UsageAggregator {

    /// Shared on-disk cache — actors are safe to share across calls.
    private static let cacheStore = UsageCacheStore()

    /// Build totals purely from the cached results on disk. Returns instantly,
    /// even with hundreds of sessions, because no JSONL files are read. The
    /// data may be slightly stale — call `aggregate()` afterwards to refresh.
    static func cachedTotals() async -> UsageTotals {
        let cache = await cacheStore.load()
        return totalsFromCache(cache.entries)
    }

    /// Scan every session JSONL file under ~/.claude/projects and sum token usage.
    /// Uses the per-session cache: only files whose mtime changed since last
    /// run are re-parsed. First run is slow (~1s/100MB), subsequent runs are
    /// near-instant unless Claude has been writing to many sessions.
    static func aggregate() async -> UsageTotals {
        let initialCache = await cacheStore.load()
        let result = await Task.detached(priority: .userInitiated) { () -> (UsageTotals, UsageCacheData) in
            var newCache = UsageCacheData(version: 1, entries: [:])

            let projectsDir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude")
                .appendingPathComponent("projects")

            guard let projectDirs = try? FileManager.default.contentsOfDirectory(
                at: projectsDir,
                includingPropertiesForKeys: nil
            ) else {
                return (UsageTotals(), newCache)
            }

            for projectDir in projectDirs {
                guard (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }

                guard let sessionFiles = try? FileManager.default.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: nil
                ) else { continue }

                for sessionFile in sessionFiles where sessionFile.pathExtension == "jsonl" {
                    let path = sessionFile.path
                    let sessionId = sessionFile.deletingPathExtension().lastPathComponent
                    let mtime = fileMTime(at: path) ?? 0

                    if let cached = initialCache.entries[path], cached.mtime == mtime {
                        // Cache hit — file unchanged, reuse parsed result
                        newCache.entries[path] = cached
                    } else {
                        // Miss — parse the file and write a new cache entry
                        let (sessionTotal, sessionCwd, sessionByDay) = parseSessionUsage(at: sessionFile)
                        if sessionTotal.total > 0 {
                            var byDayCodable: [String: TokenUsage] = [:]
                            for (day, usage) in sessionByDay {
                                byDayCodable[UsageCacheDateCoder.string(from: day)] = usage
                            }
                            newCache.entries[path] = UsageCacheEntry(
                                mtime: mtime,
                                sessionId: sessionId,
                                projectCwd: sessionCwd,
                                usage: sessionTotal,
                                byDay: byDayCodable
                            )
                        }
                    }
                }
            }

            // Resolve cwds per-project (prefer the in-JSONL cwd over the lossy dir name)
            // and produce the final UsageTotals from the new cache.
            let totals = totalsFromCache(newCache.entries)
            return (totals, newCache)
        }.value

        await cacheStore.save(result.1)
        return result.0
    }

    /// File mtime as a TimeInterval (seconds since epoch). Returns nil if missing.
    private static func fileMTime(at path: String) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date
        else { return nil }
        return date.timeIntervalSince1970
    }

    /// Reduce a set of per-file cache entries into rolled-up `UsageTotals`.
    /// Groups sessions by their authoritative cwd (from the JSONL when present,
    /// or reconstructed from the dir name as a last resort).
    private static func totalsFromCache(
        _ entries: [String: UsageCacheEntry]
    ) -> UsageTotals {
        var totals = UsageTotals()

        // Group entries by project directory (parent dir of the jsonl path)
        var byProjectDir: [String: [(path: String, entry: UsageCacheEntry)]] = [:]
        for (path, entry) in entries {
            let parentDir = (path as NSString).deletingLastPathComponent
            byProjectDir[parentDir, default: []].append((path, entry))
        }

        for (parentDir, group) in byProjectDir {
            // Prefer cwd from any session in this group; fall back to dir-name reconstruction
            let resolvedCwd = group.compactMap { $0.entry.projectCwd }.first
            let cwd = resolvedCwd ?? reconstructCwd(fromDirName: (parentDir as NSString).lastPathComponent)

            var projectUsage = TokenUsage.zero
            var sessionCount = 0
            for (_, entry) in group where entry.usage.total > 0 {
                projectUsage += entry.usage
                sessionCount += 1
                let key = "\(cwd)::\(entry.sessionId)"
                totals.bySession[key] = SessionUsage(
                    sessionId: entry.sessionId,
                    projectCwd: cwd,
                    usage: entry.usage
                )
                for (dayString, usage) in entry.byDay {
                    if let day = UsageCacheDateCoder.date(from: dayString) {
                        totals.byDay[day, default: .zero] += usage
                    }
                }
            }

            if projectUsage.total > 0 {
                totals.byProject[cwd] = ProjectUsage(
                    projectCwd: cwd,
                    usage: projectUsage,
                    sessionCount: sessionCount
                )
                totals.total += projectUsage
            }
        }

        return totals
    }

    /// Best-effort reconstruction of project cwd from the dash-encoded directory name.
    /// This is lossy — paths with literal `-` chars cannot be distinguished from path
    /// separators. Use the cwd from the JSONL payload when available instead.
    private static func reconstructCwd(fromDirName encoded: String) -> String {
        guard encoded.hasPrefix("-") else {
            return encoded  // Unexpected shape; return as-is
        }
        return "/" + encoded.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    /// Parse a single session JSONL and sum all assistant message usage.
    /// Also returns the first `cwd` field found and a per-day usage breakdown.
    private static func parseSessionUsage(at url: URL) -> (usage: TokenUsage, cwd: String?, byDay: [Date: TokenUsage]) {
        // Stream line-by-line via memory-mapped Data. Use `withUnsafeBytes` so
        // we iterate the mmap'd region directly instead of `Array(data)`,
        // which allocated a full UInt8 copy on the heap — defeating
        // `.mappedIfSafe`. For multi-MB session JSONLs this was the single
        // biggest allocation in usage aggregation.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return (.zero, nil, [:])
        }

        var total = TokenUsage.zero
        var cwd: String? = nil
        var byDay: [Date: TokenUsage] = [:]

        data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuf.count
            var lineStart = 0
            for i in 0..<count where base[i] == 0x0A /* '\n' */ {
                var lineEnd = i
                if lineEnd > lineStart && base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd > lineStart {
                    let lineData = Data(bytes: base.advanced(by: lineStart), count: lineEnd - lineStart)
                    processLine(lineData, total: &total, cwd: &cwd, byDay: &byDay)
                }
                lineStart = i + 1
            }
            if lineStart < count {
                let tail = Data(bytes: base.advanced(by: lineStart), count: count - lineStart)
                processLine(tail, total: &total, cwd: &cwd, byDay: &byDay)
            }
        }

        return (total, cwd, byDay)
    }

    /// Extract usage fields, cwd, and per-day breakdown from a single JSONL line.
    private static func processLine(
        _ lineData: Data,
        total: inout TokenUsage,
        cwd: inout String?,
        byDay: inout [Date: TokenUsage]
    ) {
        guard let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            return
        }

        // Pick up cwd from any message (user/assistant entries include it at top level)
        if cwd == nil, let c = obj["cwd"] as? String { cwd = c }

        guard obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return }

        // Capture the raw model string verbatim (e.g. "claude-opus-4-8" or
        // "claude-haiku-4-5-20251001"). Normalisation lives in Pricing.swift
        // (#2); the aggregator stores raw IDs so any version-suffix variants
        // round-trip through the cache untouched.
        let model = (message["model"] as? String) ?? ""
        // Real per-message usage objects carry a `cache_creation` sub-object
        // splitting the flat cache_creation_input_tokens count into 1h vs
        // 5m TTL buckets — confirmed on live captured JSONL. A 1h cache
        // write is billed at roughly 1.6x a 5m one; reading only the flat
        // total (as this used to) silently priced every 1h write at the 5m
        // rate downstream in CostCalculator, under-reporting real spend on
        // any session using 1h caching.
        let cacheCreation1h = (usage["cache_creation"] as? [String: Any])
            .map { intFromJSON($0["ephemeral_1h_input_tokens"]) } ?? 0
        let lineFlat = TokenUsage(
            inputTokens: intFromJSON(usage["input_tokens"]),
            outputTokens: intFromJSON(usage["output_tokens"]),
            cacheCreationTokens: intFromJSON(usage["cache_creation_input_tokens"]),
            cacheReadTokens: intFromJSON(usage["cache_read_input_tokens"]),
            cacheCreation1hTokens: cacheCreation1h
        )
        // Wrap with byModel only when the model is known; an empty key would
        // create a spurious "" bucket that pollutes downstream cost views.
        let lineUsage: TokenUsage = model.isEmpty
            ? lineFlat
            : TokenUsage(
                inputTokens: lineFlat.inputTokens,
                outputTokens: lineFlat.outputTokens,
                cacheCreationTokens: lineFlat.cacheCreationTokens,
                cacheReadTokens: lineFlat.cacheReadTokens,
                cacheCreation1hTokens: lineFlat.cacheCreation1hTokens,
                byModel: [model: lineFlat]
            )
        total += lineUsage

        // Bucket into a per-day total when timestamp is parseable
        if let tsString = obj["timestamp"] as? String,
           let ts = Self.iso8601.date(from: tsString) {
            let day = Self.utcStartOfDay(for: ts)
            byDay[day, default: .zero] += lineUsage
        }
    }

    /// One reusable formatter — ISO8601 with fractional seconds (matches Claude's output).
    /// `nonisolated(unsafe)` because ISO8601DateFormatter is documented as
    /// thread-safe for `date(from:)` since iOS 10 / macOS 10.12, but isn't
    /// declared Sendable in the SDK.
    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Truncate to start-of-day in UTC so buckets line up regardless of locale.
    private static func utcStartOfDay(for date: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return cal.startOfDay(for: date)
    }

    /// JSONSerialization returns NSNumber; `as? Int` fails for doubles encoded as numerics.
    /// Coerce via NSNumber to tolerate `1.0`, `Int64`, etc.
    private static func intFromJSON(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        return 0
    }

    /// Format a token count for display: 3.4T, 12.5B, 1.2M, 45.3K, 876
    static func format(_ count: Int) -> String {
        let abs = Swift.abs(count)
        if abs >= 1_000_000_000_000 {
            return String(format: "%.1fT", Double(count) / 1_000_000_000_000)
        } else if abs >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        } else if abs >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        } else if abs >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        } else {
            return "\(count)"
        }
    }
}
