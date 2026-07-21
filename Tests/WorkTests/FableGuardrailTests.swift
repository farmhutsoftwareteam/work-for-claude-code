import XCTest
@testable import Work

/// User-reported (2026-07-21): a chat appeared to have auto-switched to
/// fable mid-conversation. Investigation proved that specific case was an
/// external cloud product, not Atelier — but Atelier still needed a real,
/// enforced guarantee (not just an audit finding) that it can never trigger
/// an automatic model reroute itself, plus visible warnings wherever fable
/// is selected or active, since that tier draws down plan usage limits
/// faster.
@MainActor
final class FableGuardrailTests: XCTestCase {

    // MARK: - assertNeverAutoFallback

    func testLeavesArgsUntouchedWhenFlagAbsent() {
        var args = ["-p", "--output-format", "stream-json", "--model", "claude-opus-4-8"]
        let before = args
        StreamSession.assertNeverAutoFallback(&args)
        XCTAssertEqual(args, before)
    }

    func testStripsFlagAndItsValue() {
        var args = ["-p", "--fallback-model", "claude-sonnet-5", "--model", "claude-opus-4-8"]
        StreamSession.assertNeverAutoFallback(&args)
        XCTAssertEqual(args, ["-p", "--model", "claude-opus-4-8"])
    }

    func testStripsFlagWhenItIsTheLastArgumentWithNoValue() {
        var args = ["-p", "--model", "claude-opus-4-8", "--fallback-model"]
        StreamSession.assertNeverAutoFallback(&args)
        XCTAssertEqual(args, ["-p", "--model", "claude-opus-4-8"])
    }

    // MARK: - fallbackNote

    func testPlainWordingWhenLandingModelIsNotFable() {
        let note = StreamSession.fallbackNote(from: "claude-opus-4-8", to: "claude-sonnet-5")
        guard case .systemNote(let kind, let text) = note else {
            return XCTFail("expected .systemNote")
        }
        XCTAssertEqual(kind, .info)
        XCTAssertTrue(text.contains("claude-opus-4-8"))
        XCTAssertTrue(text.contains("claude-sonnet-5"))
        XCTAssertFalse(text.contains(V2DiscoveredModel.usageWarning))
    }

    func testEscalatedWordingWhenLandingModelIsFable() {
        let note = StreamSession.fallbackNote(from: "claude-opus-4-8", to: "claude-fable-5")
        guard case .systemNote(let kind, let text) = note else {
            return XCTFail("expected .systemNote")
        }
        // .info, not .error — nothing failed, the turn just landed on a
        // costlier model. Escalation lives in the text, not the icon/color.
        XCTAssertEqual(kind, .info)
        XCTAssertTrue(text.contains(V2DiscoveredModel.usageWarning))
    }

    func testHandlesMissingFromAndTo() {
        let note = StreamSession.fallbackNote(from: nil, to: nil)
        guard case .systemNote(let kind, let text) = note else {
            return XCTFail("expected .systemNote")
        }
        XCTAssertEqual(kind, .info)
        XCTAssertFalse(text.isEmpty)
    }
}
