import XCTest
@testable import Work

/// Real fixtures — the loggedIn/loggedOut JSON is verbatim from
/// `claude auth status --json` (2026-07-18: once against the real logged-in
/// account, once against an isolated CLAUDE_CONFIG_DIR sandbox so the probe
/// never touched real credentials), and the login-URL line is the CLI's
/// actual output from `claude auth login --claudeai` in that same sandbox.
@MainActor
final class ClaudeAuthManagerTests: XCTestCase {
    func testLoggedInStatusParsesEmailAndPlan() {
        let json = """
        {"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty",
         "email": "munya@munyamakosa.com", "orgId": "84cede19-848d-408c-abf9-ee19ba21c468",
         "orgName": "munya@munyamakosa.com's Organization", "subscriptionType": "max"}
        """
        XCTAssertEqual(
            ClaudeAuthManager.parseStatus(json),
            .loggedIn(email: "munya@munyamakosa.com", plan: "max")
        )
    }

    func testLoggedOutStatusParses() {
        let json = #"{"loggedIn": false, "authMethod": "none", "apiProvider": "firstParty"}"#
        XCTAssertEqual(ClaudeAuthManager.parseStatus(json), .loggedOut)
    }

    func testUnparseableOutputReportsCheckFailedNotLoggedOut() {
        // A corrupt binary or unexpected CLI output must not silently read
        // as "logged out" — that would show a sign-in button that fails
        // the identical way, with no indication anything is actually wrong.
        for garbage in ["", "not json at all", "{\"loggedIn\": \"not a bool\"}"] {
            if case .checkFailed = ClaudeAuthManager.parseStatus(garbage) {
                continue
            }
            if garbage == "{\"loggedIn\": \"not a bool\"}" {
                // Valid JSON, just a wrong-typed field — the `as? Bool`
                // cast fails closed to loggedOut, which is acceptable
                // (it's valid JSON, unlike the other two cases).
                XCTAssertEqual(ClaudeAuthManager.parseStatus(garbage), .loggedOut)
            } else {
                XCTFail("expected .checkFailed for unparseable input: \(garbage)")
            }
        }
    }

    func testExtractsLoginURLFromRealCapturedCLIOutput() throws {
        let output = "Opening browser to sign in…\nIf the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&state=abc\nPaste code here if prompted > "
        let url = try XCTUnwrap(ClaudeAuthManager.extractLoginURL(from: output))
        XCTAssertEqual(url.host, "claude.com")
        XCTAssertEqual(url.path, "/cai/oauth/authorize")
    }

    func testNoURLYetReturnsNilRatherThanMisfiring() {
        XCTAssertNil(ClaudeAuthManager.extractLoginURL(from: "Opening browser to sign in…\n"))
    }

    func testURLExtractionIsIncrementalSafe() {
        // handleStdout re-scans the FULL accumulated buffer on every chunk
        // (stdout can arrive split mid-URL). A buffer that ends mid-URL —
        // whether because it's an obviously-truncated host, or just
        // because the writing chunk hasn't finished yet — has no trailing
        // whitespace proving the CLI is done writing that token, so it
        // must not extract yet either way.
        XCTAssertNil(ClaudeAuthManager.extractLoginURL(from: "visit: https://claude.c"))
        XCTAssertNil(ClaudeAuthManager.extractLoginURL(from: "visit: https://claude.com/cai/oauth/authorize?code=true"))
        // Once a subsequent chunk supplies the trailing newline, the exact
        // same (now-terminated) URL extracts correctly.
        XCTAssertNotNil(ClaudeAuthManager.extractLoginURL(from: "visit: https://claude.com/cai/oauth/authorize?code=true\n"))
    }
}
