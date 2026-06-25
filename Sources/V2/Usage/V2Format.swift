// Compact number formatting for the v2 surfaces. Everywhere we show a raw
// count of anything — tokens, sessions, requests, cache hits — funnels
// through here so the units (k / M / B / T) are consistent across the app.
//
// Examples:
//   1               →  1
//   42              →  42
//   999             →  999
//   1_234           →  1.2k
//   42_000          →  42k
//   123_456         →  123k       (no decimal once we're past 100k)
//   1_234_567       →  1.23M
//   12_345_678      →  12.3M
//   123_456_789     →  123M
//   1_234_567_890   →  1.23B
//   1_234_567_890_123 → 1.23T
//
// Dollars get their own pair of formatters — small amounts keep the cents
// precision (so $0.04 doesn't round to $0), large amounts collapse to k/M
// like the count formatter.

import Foundation

enum V2Format {

    /// Compact integer with k/M/B/T suffixes. Returns the bare number under
    /// 1,000 since "1k" reads weird for "994" tokens.
    static func count(_ n: Int) -> String {
        let abs = Swift.abs(n)
        let sign = n < 0 ? "-" : ""
        switch abs {
        case 0..<1_000:
            return "\(sign)\(abs)"
        case 1_000..<1_000_000:
            return "\(sign)\(format(Double(abs) / 1_000))k"
        case 1_000_000..<1_000_000_000:
            return "\(sign)\(format(Double(abs) / 1_000_000))M"
        case 1_000_000_000..<1_000_000_000_000:
            return "\(sign)\(format(Double(abs) / 1_000_000_000))B"
        default:
            return "\(sign)\(format(Double(abs) / 1_000_000_000_000))T"
        }
    }

    /// Compact USD. Sub-dollar keeps 3-4 decimals (so $0.041 round-trips),
    /// hundreds to thousands round to 2 decimals ("$4.82"), beyond ~$10k
    /// it switches to k/M to keep the column tidy.
    static func usd(_ value: Double) -> String {
        let abs = Swift.abs(value)
        let sign = value < 0 ? "-" : ""
        switch abs {
        case 0..<0.01:
            return "\(sign)$\(String(format: "%.4f", abs))"
        case 0.01..<1:
            return "\(sign)$\(String(format: "%.3f", abs))"
        case 1..<10_000:
            return "\(sign)$\(String(format: "%.2f", abs))"
        case 10_000..<1_000_000:
            return "\(sign)$\(format(abs / 1_000))k"
        case 1_000_000..<1_000_000_000:
            return "\(sign)$\(format(abs / 1_000_000))M"
        default:
            return "\(sign)$\(format(abs / 1_000_000_000))B"
        }
    }

    /// Trim trailing decimals based on magnitude. 1.23 stays as "1.23",
    /// 12.3 stays as "12.3", 123 stays as "123" — keeps the textual width
    /// roughly constant across scales.
    private static func format(_ v: Double) -> String {
        if v >= 100 {
            return String(Int(v.rounded()))
        }
        if v >= 10 {
            return String(format: "%.1f", v)
        }
        return String(format: "%.2f", v)
    }
}
