import XCTest
@testable import Work

/// Parsers verified against REAL captured payloads — the Claude fixture is
/// the verbatim get_usage control_response from a live probe (2026-07-17),
/// the Codex fixture matches codex-cli 0.144.4's generated RateLimitSnapshot
/// schema. If a provider changes shape, these fail before the meter lies.
final class UsageLimitsTests: XCTestCase {
    func testClaudeGetUsagePayloadParsesAllThreeLimitWindows() throws {
        let json = """
        {"subscription_type": "max", "rate_limits_available": true,
         "rate_limits": {
           "limits": [
             {"kind": "session", "group": "session", "percent": 16, "severity": "normal",
              "resets_at": "2026-07-17T16:50:00.464131+00:00", "scope": null, "is_active": false},
             {"kind": "weekly_all", "group": "weekly", "percent": 39, "severity": "normal",
              "resets_at": "2026-07-20T06:00:00.464153+00:00", "scope": null, "is_active": false},
             {"kind": "weekly_scoped", "group": "weekly", "percent": 43, "severity": "normal",
              "resets_at": "2026-07-20T06:00:00.464460+00:00",
              "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}, "is_active": true}
           ]}}
        """
        let payload = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let limits = try XCTUnwrap(V2UsageLimits.fromClaude(payload))

        XCTAssertEqual(limits.planLabel, "max")
        XCTAssertEqual(limits.windows.map(\.label), ["5h", "week", "week · Fable"])
        XCTAssertEqual(limits.windows.map(\.percent), [16, 39, 43])
        XCTAssertEqual(limits.windows.map(\.severity), [.normal, .normal, .normal])
        // resets_at carries MICROsecond fractions — the parse must not drop
        // the date on the fallback path.
        for window in limits.windows {
            XCTAssertNotNil(window.resetsAt, "\(window.label) lost its reset date")
        }
        // The active scoped window wins the headline slot.
        XCTAssertEqual(limits.headline?.label, "week · Fable")
    }

    func testClaudePayloadWithoutRateLimitsReturnsNilRatherThanAnEmptyMeter() throws {
        let payload = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"rate_limits_available": false, "session": {}}"#.utf8)
        )
        XCTAssertNil(V2UsageLimits.fromClaude(payload))
    }

    func testCodexSnapshotParsesPrimaryAndSecondaryWindows() throws {
        let snapshot: [String: Any] = [
            "planType": "plus",
            "primary": ["usedPercent": 22, "resetsAt": 1_784_289_000, "windowDurationMins": 300],
            "secondary": ["usedPercent": 61, "resetsAt": 1_784_500_000, "windowDurationMins": 10_080],
        ]
        let limits = try XCTUnwrap(V2UsageLimits.fromCodex(snapshot))
        XCTAssertEqual(limits.planLabel, "plus")
        XCTAssertEqual(limits.windows.map(\.label), ["5h", "week"])
        XCTAssertEqual(limits.windows.map(\.percent), [22, 61])
        XCTAssertEqual(limits.windows.map(\.severity), [.normal, .normal])
    }

    func testCodexReachedLimitMarksWindowsExceeded() throws {
        let snapshot: [String: Any] = [
            "rateLimitReachedType": "rate_limit_reached",
            "primary": ["usedPercent": 100, "resetsAt": 1_784_289_000, "windowDurationMins": 300],
        ]
        let limits = try XCTUnwrap(V2UsageLimits.fromCodex(snapshot))
        XCTAssertEqual(limits.windows.first?.severity, .exceeded)
    }

    func testCodexEmptySnapshotReturnsNil() {
        XCTAssertNil(V2UsageLimits.fromCodex([:]))
        XCTAssertNil(V2UsageLimits.fromCodex(nil))
    }
}
