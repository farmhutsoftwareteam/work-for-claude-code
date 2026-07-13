import Foundation

// MARK: - Pricing data
//
// Hardcoded table of per-million-token rates for every Claude model Claude
// Code can use, sourced from https://platform.claude.com/docs/en/about-claude/pricing
// (verified June 2026). Anthropic publishes no structured pricing endpoint,
// so this table is the source of truth at build time. A remote fetcher
// (#6 — PricingFetcher) can hot-swap these values without an app release,
// but the embedded table below is always the offline / first-launch fallback.
//
// Keys are the **normalised** model ID — date suffixes (e.g.
// "-20251001") are stripped before lookup so dated and undated forms map to
// the same prices.
//
// Cache writes have two TTL tiers (5m and 1h) priced differently. The JSONL
// does not record which TTL was used at the request, so callers default to
// `.fiveMin` unless they have out-of-band evidence otherwise.

struct ModelPrice: Equatable {
    /// Dollars per million input tokens.
    let inputPerMTok: Decimal
    /// Dollars per million output tokens.
    let outputPerMTok: Decimal
    /// Dollars per million tokens written into a 5-minute cache.
    let cacheWrite5mPerMTok: Decimal
    /// Dollars per million tokens written into a 1-hour cache.
    let cacheWrite1hPerMTok: Decimal
    /// Dollars per million tokens read from the cache (TTL agnostic).
    let cacheReadPerMTok: Decimal
}

enum Pricing {

    /// Embedded pricing table. June 2026 rates from platform.claude.com.
    /// Update when Anthropic announces a change; #6 ships a remote-fetch
    /// alternative so changes can roll out without an app release.
    ///
    /// Decimal initialised from string literals to side-step the
    /// `Decimal(5.00)` Double-precision round-trip footgun.
    static let embeddedTable: [String: ModelPrice] = [
        "claude-fable-5": ModelPrice(
            inputPerMTok:        Decimal(string: "10.00")!,
            outputPerMTok:       Decimal(string: "50.00")!,
            cacheWrite5mPerMTok: Decimal(string: "12.50")!,
            cacheWrite1hPerMTok: Decimal(string: "20.00")!,
            cacheReadPerMTok:    Decimal(string: "1.00")!
        ),
        "claude-opus-4-8": ModelPrice(
            inputPerMTok:        Decimal(string: "5.00")!,
            outputPerMTok:       Decimal(string: "25.00")!,
            cacheWrite5mPerMTok: Decimal(string: "6.25")!,
            cacheWrite1hPerMTok: Decimal(string: "10.00")!,
            cacheReadPerMTok:    Decimal(string: "0.50")!
        ),
        "claude-opus-4-7": ModelPrice(
            inputPerMTok:        Decimal(string: "5.00")!,
            outputPerMTok:       Decimal(string: "25.00")!,
            cacheWrite5mPerMTok: Decimal(string: "6.25")!,
            cacheWrite1hPerMTok: Decimal(string: "10.00")!,
            cacheReadPerMTok:    Decimal(string: "0.50")!
        ),
        "claude-opus-4-6": ModelPrice(
            inputPerMTok:        Decimal(string: "5.00")!,
            outputPerMTok:       Decimal(string: "25.00")!,
            cacheWrite5mPerMTok: Decimal(string: "6.25")!,
            cacheWrite1hPerMTok: Decimal(string: "10.00")!,
            cacheReadPerMTok:    Decimal(string: "0.50")!
        ),
        // Introductory pricing through Aug 31, 2026 ($2/$10) — confirmed live
        // at platform.claude.com/docs/en/about-claude/pricing (fetched
        // 2026-07-13). Standard pricing ($3/$15, same as sonnet-4-6 below)
        // takes effect Sep 1, 2026 — update this entry then, or rely on
        // PricingFetcher's remote table if pricing.json is kept current.
        // This model was entirely ABSENT from both this embedded table and
        // the live-fetched pricing.json until this fix — every dollar of
        // Sonnet 5 usage was silently excluded from the Usage tab's total
        // (unknown-model tokens contribute $0 "by convention").
        "claude-sonnet-5": ModelPrice(
            inputPerMTok:        Decimal(string: "2.00")!,
            outputPerMTok:       Decimal(string: "10.00")!,
            cacheWrite5mPerMTok: Decimal(string: "2.50")!,
            cacheWrite1hPerMTok: Decimal(string: "4.00")!,
            cacheReadPerMTok:    Decimal(string: "0.20")!
        ),
        "claude-sonnet-4-6": ModelPrice(
            inputPerMTok:        Decimal(string: "3.00")!,
            outputPerMTok:       Decimal(string: "15.00")!,
            cacheWrite5mPerMTok: Decimal(string: "3.75")!,
            cacheWrite1hPerMTok: Decimal(string: "6.00")!,
            cacheReadPerMTok:    Decimal(string: "0.30")!
        ),
        "claude-haiku-4-5": ModelPrice(
            inputPerMTok:        Decimal(string: "1.00")!,
            outputPerMTok:       Decimal(string: "5.00")!,
            cacheWrite5mPerMTok: Decimal(string: "1.25")!,
            cacheWrite1hPerMTok: Decimal(string: "2.00")!,
            cacheReadPerMTok:    Decimal(string: "0.10")!
        ),
        "claude-opus-4-1": ModelPrice(
            inputPerMTok:        Decimal(string: "15.00")!,
            outputPerMTok:       Decimal(string: "75.00")!,
            cacheWrite5mPerMTok: Decimal(string: "18.75")!,
            cacheWrite1hPerMTok: Decimal(string: "30.00")!,
            cacheReadPerMTok:    Decimal(string: "1.50")!
        ),
        "claude-opus-4": ModelPrice(
            inputPerMTok:        Decimal(string: "15.00")!,
            outputPerMTok:       Decimal(string: "75.00")!,
            cacheWrite5mPerMTok: Decimal(string: "18.75")!,
            cacheWrite1hPerMTok: Decimal(string: "30.00")!,
            cacheReadPerMTok:    Decimal(string: "1.50")!
        ),
        "claude-sonnet-3-5": ModelPrice(
            inputPerMTok:        Decimal(string: "3.00")!,
            outputPerMTok:       Decimal(string: "15.00")!,
            cacheWrite5mPerMTok: Decimal(string: "3.75")!,
            cacheWrite1hPerMTok: Decimal(string: "6.00")!,
            cacheReadPerMTok:    Decimal(string: "0.30")!
        ),
    ]

    /// Live table that `lookup` consults. Defaults to the embedded table at
    /// startup; #6's `PricingFetcher` can swap in a remotely-fetched copy.
    /// Marked `nonisolated(unsafe)` so it can be mutated from the fetcher
    /// actor without dragging `Pricing` into an actor (the table is set
    /// once on app launch and again rarely after that — atomic in practice).
    nonisolated(unsafe) static var liveTable: [String: ModelPrice] = embeddedTable

    /// Strip Anthropic-style date suffixes from a raw model ID so dated and
    /// undated forms collide on the same pricing row.
    /// `claude-haiku-4-5-20251001` → `claude-haiku-4-5`
    /// `claude-opus-4-8`           → `claude-opus-4-8` (idempotent)
    static func normalize(_ rawModel: String) -> String {
        // Match `-YYYYMMDD` exactly at end of string.
        let pattern = "-[0-9]{8}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return rawModel
        }
        let range = NSRange(location: 0, length: rawModel.utf16.count)
        return regex.stringByReplacingMatches(in: rawModel, range: range, withTemplate: "")
    }

    /// Look up the price row for a (possibly date-suffixed) model ID.
    /// Returns nil for unknown models; callers surface that to the user as
    /// `$? (unknown model)` rather than $0.
    static func lookup(_ rawModel: String) -> ModelPrice? {
        liveTable[normalize(rawModel)]
    }

    /// Sorted list of every model ID in the live table — useful for tests
    /// and for future "supported models" debug surfaces.
    static var allKnownModels: [String] {
        liveTable.keys.sorted()
    }
}
