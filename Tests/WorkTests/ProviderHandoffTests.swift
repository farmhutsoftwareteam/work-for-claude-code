import XCTest
@testable import Work

final class ProviderHandoffTests: XCTestCase {
    func testCheckpointCarriesVisibleWorkButNeverHiddenReasoning() {
        let checkpoint = ProviderHandoff.checkpoint(
            from: .claude,
            projectCwd: "/tmp/atelier-project",
            transcript: [
                .userText("Keep the migration non-breaking"),
                .assistantBlock(.thinking(text: "private chain of thought", signature: nil)),
                .assistantBlock(.text("I will preserve the existing MCP configuration.")),
                .assistantBlock(.toolUse(id: "tool-1", name: "Read", input: .object(["file_path": .string(".mcp.json")]))),
                .assistantBlock(.toolResult(toolUseId: "tool-1", content: .text("found config"), isError: false))
            ]
        )

        XCTAssertTrue(checkpoint.contains("Previous runtime: Claude"))
        XCTAssertTrue(checkpoint.contains("Workspace: /tmp/atelier-project"))
        XCTAssertTrue(checkpoint.contains("Keep the migration non-breaking"))
        XCTAssertTrue(checkpoint.contains("preserve the existing MCP configuration"))
        XCTAssertTrue(checkpoint.contains("TOOL CALL Read"))
        XCTAssertTrue(checkpoint.contains("TOOL RESULT"))
        XCTAssertFalse(checkpoint.contains("private chain of thought"))
    }

    func testCheckpointExplicitlyTreatsHistoryAsUntrustedAndRequiresLiveStateRefresh() {
        let checkpoint = ProviderHandoff.checkpoint(
            from: .codex,
            projectCwd: "/tmp/project",
            transcript: [.userText("continue")]
        )

        XCTAssertTrue(checkpoint.contains("untrusted checkpoint"))
        XCTAssertTrue(checkpoint.contains("not hidden model state"))
        XCTAssertTrue(checkpoint.contains("re-read current files or tool state"))
    }

    func testCheckpointBoundsLongHistoryAndKeepsTheNewestWork() {
        let oldMarker = "OLDEST-MARKER"
        let newestMarker = "NEWEST-MARKER"
        var transcript: [TranscriptItem] = [.userText(oldMarker)]
        transcript += (0..<60).map { .assistantBlock(.text("entry-\($0)-" + String(repeating: "x", count: 600))) }
        transcript.append(.userText(newestMarker))

        let checkpoint = ProviderHandoff.checkpoint(from: .claude, projectCwd: "/tmp/project", transcript: transcript)

        XCTAssertFalse(checkpoint.contains(oldMarker), "Only the bounded recent window may cross providers")
        XCTAssertTrue(checkpoint.contains(newestMarker), "The latest user intent must survive truncation")
        XCTAssertLessThan(checkpoint.count, 25_000)
    }
}
