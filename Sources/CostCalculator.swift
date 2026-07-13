import Foundation

// MARK: - Cost calculator
//
// Pure functions that turn TokenUsage into dollar amounts using the rates
// in Pricing.swift. No state. No I/O. No UI. All math is `Decimal` to avoid
// floating-point drift across thousands of token rows.

/// Which cache-write TTL price to apply to a `TokenUsage` that has NO
/// per-record 1h/5m split (`cacheCreation1hTokens == 0` because the data
/// predates that field, not because every write was really 5-min). Real
/// per-message usage DOES carry the split (TokenUsage.cacheCreation1hTokens)
/// and is costed exactly via that instead — this is purely the fallback for
/// old rows, kept so pre-existing cached/serialised data doesn't shift cost
/// out from under itself on next load.
enum CacheTTL { case fiveMin, oneHour }

/// Dollar breakdown of a multi-model TokenUsage.
struct CostBreakdown: Equatable {
    /// Total dollars across every known-model row.
    let total: Decimal
    /// Dollars contributed per model, keyed by the same raw model IDs that
    /// appear in `TokenUsage.byModel`.
    let byModel: [String: Decimal]
    /// Models present in `byModel` that did NOT resolve in `Pricing.lookup`.
    /// UI surfaces these as a small footnote ("N tokens from unknown models")
    /// so the user knows the dollar figure may be slightly under-reported.
    let unknownModels: [String]
}

enum CostCalculator {

    /// Cost of a single-model token block. Returns nil if `Pricing.lookup`
    /// doesn't know the model — caller decides how to surface that
    /// (typically "$?" with a tooltip).
    static func cost(
        of usage: TokenUsage,
        model: String,
        cacheTTL: CacheTTL = .fiveMin
    ) -> Decimal? {
        guard let price = Pricing.lookup(model) else { return nil }
        return cost(of: usage, price: price, cacheTTL: cacheTTL)
    }

    /// Cost of a `TokenUsage` that carries `byModel` attribution. Sums each
    /// per-model bucket independently using its model's prices; collects
    /// unresolvable models in `unknownModels` and excludes them from the
    /// total (they contribute $0 by convention).
    ///
    /// Note: if `byModel` is empty (legacy data with no model attribution),
    /// every token row lands in `unknownModels` as `""`. UI should show
    /// "$? (no model info)" in that case.
    static func cost(
        of usage: TokenUsage,
        cacheTTL: CacheTTL = .fiveMin
    ) -> CostBreakdown {
        // No model attribution at all → entire usage is unknown.
        guard !usage.byModel.isEmpty else {
            return CostBreakdown(total: 0, byModel: [:], unknownModels: usage.total > 0 ? [""] : [])
        }

        var total: Decimal = 0
        var byModel: [String: Decimal] = [:]
        var unknown: [String] = []

        for (model, perModelUsage) in usage.byModel {
            guard let price = Pricing.lookup(model) else {
                unknown.append(model)
                continue
            }
            let c = cost(of: perModelUsage, price: price, cacheTTL: cacheTTL)
            byModel[model] = c
            total += c
        }

        return CostBreakdown(total: total, byModel: byModel, unknownModels: unknown.sorted())
    }

    /// Internal helper: raw math given an already-resolved `ModelPrice`.
    ///
    /// Cache-write cost is split using the usage's ACTUAL 1h/5m breakdown
    /// (TokenUsage.cacheCreation1hTokens, parsed from the real per-message
    /// `cache_creation` object) rather than a single blanket rate for the
    /// whole bucket — a 1h write costs ~1.6x a 5m one, and real sessions
    /// mix both or lean entirely 1h depending on request parameters.
    /// `cacheTTL` only decides the rate for the REMAINDER after subtracting
    /// the known-1h portion, i.e. it's purely the fallback for rows that
    /// predate per-record tracking (cacheCreation1hTokens == 0 there because
    /// the field never existed, not because those writes were verified 5m).
    private static func cost(
        of usage: TokenUsage,
        price: ModelPrice,
        cacheTTL: CacheTTL
    ) -> Decimal {
        let perMillion = Decimal(1_000_000)
        let inputCost  = Decimal(usage.inputTokens)  * price.inputPerMTok  / perMillion
        let outputCost = Decimal(usage.outputTokens) * price.outputPerMTok / perMillion

        let oneHourTokens = min(usage.cacheCreation1hTokens, usage.cacheCreationTokens)
        let remainderTokens = usage.cacheCreationTokens - oneHourTokens
        let remainderPrice = (cacheTTL == .fiveMin) ? price.cacheWrite5mPerMTok : price.cacheWrite1hPerMTok
        let cacheWriteCost = Decimal(oneHourTokens) * price.cacheWrite1hPerMTok / perMillion
            + Decimal(remainderTokens) * remainderPrice / perMillion

        let cacheReadCost  = Decimal(usage.cacheReadTokens)     * price.cacheReadPerMTok / perMillion
        return inputCost + outputCost + cacheWriteCost + cacheReadCost
    }

    /// Format a `Decimal` dollar amount as a display string. Always en_US_POSIX
    /// formatting so Sarah and Tom both see "$47.30", not localised "R47,30".
    /// - 0 → "$0.00"
    /// - < $10,000 → "$X.XX" (two-decimal cents)
    /// - >= $10,000 → "$X.XK" (compact, since cents are noise at that scale)
    static func formatDollars(_ amount: Decimal) -> String {
        // `Decimal` → `NSDecimalNumber` for NumberFormatter compatibility.
        let nsDecimal = NSDecimalNumber(decimal: amount)
        let doubleValue = nsDecimal.doubleValue
        if doubleValue >= 10_000 {
            return String(format: "$%.1fK", doubleValue / 1_000)
        }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: nsDecimal) ?? String(format: "$%.2f", doubleValue)
    }
}
