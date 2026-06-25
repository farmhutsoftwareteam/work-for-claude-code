// Per-model token pricing — the ONLY place in the app where pricing
// constants live. There is no public API to discover these at runtime, so
// this file is reference data we update manually when Anthropic publishes
// changes.
//
// Source: https://www.anthropic.com/api  (pricing tab, June 2026)
// Format: USD per 1M tokens, by tier (input / output / cache-read / cache-write).
//
// When updating: bump `lastReviewed`, update the matching family entry,
// commit with a link to the announcement post or pricing-page snapshot.
// Anything that wants to multiply tokens by dollars must funnel through
// `AnthropicPricing.cost(for:tokens:)` so a single review covers every
// surface that shows $.

import Foundation

struct AnthropicPricing {

    /// Last manual review. Bump this when you touch rates so reviewers can
    /// see at a glance whether the table needs another pass.
    static let lastReviewed = "2026-06-25"

    /// USD per 1,000,000 tokens.
    struct Rate: Equatable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double
    }

    /// Keyed by family substring; we match a model id against these in
    /// order, longest key first, so `claude-opus-4-8` falls through to the
    /// `opus` rate without needing per-version entries.
    static let rates: [(matches: String, rate: Rate)] = [
        ("opus",   Rate(input: 15.00, output: 75.00, cacheRead: 1.50, cacheWrite: 18.75)),
        ("sonnet", Rate(input: 3.00,  output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)),
        ("haiku",  Rate(input: 0.80,  output: 4.00,  cacheRead: 0.08, cacheWrite: 1.00)),
        ("fable",  Rate(input: 3.00,  output: 15.00, cacheRead: 0.30, cacheWrite: 3.75)),
    ]

    /// Return USD cost for a TokenUsage at the given model's rate.
    /// Returns nil when the model family isn't in the table (so callers
    /// can render "—" instead of a fake zero).
    static func cost(for modelId: String, tokens: TokenUsage) -> Double? {
        guard let rate = rate(for: modelId) else { return nil }
        let perToken = 1.0 / 1_000_000.0
        return Double(tokens.inputTokens)         * rate.input       * perToken
             + Double(tokens.outputTokens)        * rate.output      * perToken
             + Double(tokens.cacheReadTokens)     * rate.cacheRead   * perToken
             + Double(tokens.cacheCreationTokens) * rate.cacheWrite  * perToken
    }

    /// Sum cost across a TokenUsage's per-model breakdown. Falls back to
    /// the aggregate at sonnet rates when byModel is empty — labelled
    /// clearly at the call site as an estimate.
    static func totalCost(_ usage: TokenUsage) -> Double {
        if usage.byModel.isEmpty {
            // Older sessions don't carry byModel; assume sonnet so we don't
            // double-charge. Caller surfaces this as "estimated".
            return cost(for: "claude-sonnet", tokens: usage) ?? 0
        }
        return usage.byModel.reduce(0) { acc, pair in
            acc + (cost(for: pair.key, tokens: pair.value) ?? 0)
        }
    }

    /// Format as `$0.04` / `$1.84` / `$24.31`. Three decimals when small,
    /// two when bigger — matches the design's mixed precision.
    static func formatUSD(_ value: Double) -> String {
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1    { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }

    private static func rate(for modelId: String) -> Rate? {
        let lower = modelId.lowercased()
        for (key, rate) in rates where lower.contains(key) {
            return rate
        }
        return nil
    }
}
