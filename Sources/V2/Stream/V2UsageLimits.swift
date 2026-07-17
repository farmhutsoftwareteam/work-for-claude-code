// Provider-neutral plan-usage/rate-limit snapshot — the quota meters
// claude.ai and the ChatGPT apps show, reconstructed from each provider's
// real, confirmed local surface (research 2026-07-17, all probed live):
//
//   Claude — `get_usage` control_request over the already-open stream-json
//   stdin returns typed JSON: rate_limits.limits[] with kind/percent/
//   severity/resets_at/is_active (+ model-scoped weekly entries), plus
//   subscription_type. Zero cost: num_turns 0, no API call. The passive
//   rate_limit_event push (status + reset, no percent) arrives on every
//   session as the refresh trigger.
//
//   Codex — app-server `account/rateLimits/read` (+ `account/rateLimits/
//   updated` push) returns RateLimitSnapshot: primary/secondary
//   RateLimitWindow {usedPercent, resetsAt, windowDurationMins} + planType.

import Foundation

struct V2UsageLimits: Equatable {
    enum Severity: Equatable {
        case normal
        case warning
        case exceeded
    }

    struct Window: Equatable, Identifiable {
        /// Short user-facing label: "5h", "week", "week · Fable".
        let label: String
        /// 0–100+ (a just-over-limit window can report >100).
        let percent: Int
        let resetsAt: Date?
        let severity: Severity
        /// The window currently governing (Claude's is_active).
        let isActive: Bool
        var id: String { label }
    }

    var windows: [Window]
    /// "max" / "pro" (Claude) or "plus" / "pro" / "team"… (Codex).
    var planLabel: String?
    var updatedAt: Date

    /// The single window worth showing when there's room for only one:
    /// the active one, else the worst by severity-then-percent.
    var headline: Window? {
        windows.first(where: \.isActive) ?? windows.max { a, b in
            (a.severity.rank, a.percent) < (b.severity.rank, b.percent)
        }
    }
}

extension V2UsageLimits.Severity {
    var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .exceeded: return 2
        }
    }
}

// MARK: - Claude parse (get_usage control_response payload)

extension V2UsageLimits {
    /// Real captured shape (probe 2026-07-17):
    /// {"session": {...}, "subscription_type": "max",
    ///  "rate_limits_available": true,
    ///  "rate_limits": {"five_hour": {...}, "seven_day": {...},
    ///    "limits": [{"kind":"session","percent":16,"severity":"normal",
    ///                "resets_at":"2026-07-17T16:50:00.464131+00:00",
    ///                "is_active":false,"scope":null}, …]}}
    static func fromClaude(_ payload: JSONValue?) -> V2UsageLimits? {
        guard let payload,
              payload.dig("rate_limits_available")?.asBool != false,
              let limits = payload.dig("rate_limits")?.dig("limits")?.asArray,
              !limits.isEmpty
        else { return nil }

        let windows: [Window] = limits.compactMap { entry in
            guard let kind = entry.dig("kind")?.asString,
                  let percent = entry.dig("percent")?.asDouble
            else { return nil }
            let scopeModel = entry.dig("scope")?.dig("model")?.dig("display_name")?.asString
            let label: String
            switch kind {
            case "session":       label = "5h"
            case "weekly_all":    label = "week"
            case "weekly_scoped": label = scopeModel.map { "week · \($0)" } ?? "week"
            default:              label = scopeModel.map { "\(kind) · \($0)" } ?? kind
            }
            return Window(
                label: label,
                percent: Int(percent.rounded()),
                resetsAt: parseISO(entry.dig("resets_at")?.asString),
                severity: severity(entry.dig("severity")?.asString, percent: Int(percent.rounded())),
                isActive: entry.dig("is_active")?.asBool ?? false
            )
        }
        guard !windows.isEmpty else { return nil }
        return V2UsageLimits(
            windows: windows,
            planLabel: payload.dig("subscription_type")?.asString,
            updatedAt: Date()
        )
    }

    private static func severity(_ raw: String?, percent: Int) -> Severity {
        switch raw {
        case "normal", nil: return percent >= 100 ? .exceeded : .normal
        case let s? where s.contains("warn"): return .warning
        case "exceeded", "rejected", "critical": return .exceeded
        default: return percent >= 100 ? .exceeded : .warning
        }
    }

    /// Claude's resets_at carries MICROsecond fractions
    /// ("2026-07-17T16:50:00.464131+00:00") — ISO8601DateFormatter's
    /// .withFractionalSeconds only tolerates milliseconds, so fall back to
    /// stripping the fraction rather than dropping the date.
    private static func parseISO(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = isoFractional.date(from: s) { return d }
        let stripped = s.replacingOccurrences(
            of: #"\.\d+"#, with: "", options: .regularExpression)
        return isoPlain.date(from: stripped)
    }

    // Formatter configuration is immutable after init and reads are
    // thread-safe in practice; nonisolated(unsafe) matches how the rest of
    // the codebase hoists its formatters (UsageView, V2RichText).
    nonisolated(unsafe) private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Codex parse (RateLimitSnapshot from read response / updated push)

extension V2UsageLimits {
    /// Schema (codex-cli 0.144.4, generate-json-schema): RateLimitSnapshot
    /// {primary: RateLimitWindow?, secondary: RateLimitWindow?, planType?,
    ///  rateLimitReachedType?} where RateLimitWindow {usedPercent,
    ///  resetsAt (epoch s), windowDurationMins}. No severity field —
    ///  derived from percent + the reached flag.
    static func fromCodex(_ snapshot: [String: Any]?) -> V2UsageLimits? {
        guard let snapshot else { return nil }
        let reached = snapshot["rateLimitReachedType"] as? String

        func window(_ raw: Any?, fallbackLabel: String) -> Window? {
            guard let raw = raw as? [String: Any],
                  let percent = (raw["usedPercent"] as? NSNumber)?.intValue
            else { return nil }
            let mins = (raw["windowDurationMins"] as? NSNumber)?.intValue
            let label: String
            switch mins {
            case .some(let m) where m <= 720: label = "\(max(1, m / 60))h"
            case .some(let m) where m >= 10080: label = "week"
            case .some(let m): label = "\(m / 1440)d"
            case nil: label = fallbackLabel
            }
            let resets = (raw["resetsAt"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            let severity: Severity =
                reached != nil || percent >= 100 ? .exceeded
                : percent >= 80 ? .warning
                : .normal
            return Window(
                label: label, percent: percent, resetsAt: resets,
                severity: severity, isActive: false
            )
        }

        let windows = [
            window(snapshot["primary"], fallbackLabel: "5h"),
            window(snapshot["secondary"], fallbackLabel: "week"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return V2UsageLimits(
            windows: windows,
            planLabel: snapshot["planType"] as? String,
            updatedAt: Date()
        )
    }
}
