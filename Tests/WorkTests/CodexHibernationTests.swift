import XCTest
@testable import Work

/// Hibernation is what makes a restored Codex tab show its conversation
/// instead of a "Start session" button, and it must do that WITHOUT owning a
/// process. Fixtures here are the real `thread/read` wire shape captured from
/// codex-cli 0.144.4 (2026-07-19) against a live Atelier-created thread —
/// free text redacted, structure verbatim, including the fields that turned
/// out to exist (`content[].text_elements`, `phase`, `itemsView`) and the one
/// that turned out NOT to (there is no `modelContextWindow` on a thread).
@MainActor
final class CodexHibernationTests: XCTestCase {

    /// A binary path that cannot spawn. Hibernation must degrade to "no
    /// history, still hibernated" rather than spawning anything in tests.
    private let unspawnable = URL(fileURLWithPath: "/nonexistent/codex-does-not-exist")

    // MARK: - thread/read → transcript

    func testRealThreadReadTurnsMapThroughTheSamePathLiveResumeUses() {
        // Verbatim structure from the captured fixture.
        let turns: [[String: Any]] = [[
            "id": "019f6f7f-3023-7e31-b8dd-720218de3bb2",
            "itemsView": "full",
            "status": "completed",
            "items": [
                ["type": "userMessage", "id": "item-1", "clientId": NSNull(),
                 "content": [["type": "text", "text": "is staging up to date?", "text_elements": []]]],
                ["type": "agentMessage", "id": "item-2", "text": "Checking now.",
                 "phase": "commentary", "memoryCitation": NSNull()],
                ["type": "mcpToolCall", "id": "exec-40b1", "server": "codex_apps",
                 "tool": "github.compare_commits", "status": "failed",
                 "arguments": ["repo_full_name": "acme/app", "base": "staging", "head": "main"],
                 "durationMs": 3250]
            ]
        ]]

        let items = CodexSession.transcript(from: turns)
        // userMessage + agentMessage + mcpToolCall(call + result) = 4 rows.
        XCTAssertEqual(items.count, 4, "every fixture item must produce a row — a silently dropped type is a blank restored tab")
        guard case .userText(let text) = items[0] else {
            return XCTFail("first row should be the user message")
        }
        XCTAssertEqual(text, "is staging up to date?")
        guard case .assistantBlock(.text("Checking now.")) = items[1] else {
            return XCTFail("second row should be the agent message")
        }
        guard case .assistantBlock(.toolUse(let id, _, _)) = items[2] else {
            return XCTFail("third row should be the MCP tool call")
        }
        XCTAssertEqual(id, "exec-40b1")
    }

    func testMultipleTurnsFlattenInOrder() {
        let turns: [[String: Any]] = [
            ["items": [["type": "userMessage", "content": [["type": "text", "text": "first"]]]]],
            ["items": [["type": "userMessage", "content": [["type": "text", "text": "second"]]]]]
        ]
        let items = CodexSession.transcript(from: turns)
        XCTAssertEqual(items.count, 2)
        guard case .userText("first") = items[0], case .userText("second") = items[1] else {
            return XCTFail("turns must flatten in chronological order, not reversed or interleaved")
        }
    }

    func testEmptyTurnsProduceNoRowsRatherThanAPlaceholder() {
        XCTAssertTrue(CodexSession.transcript(from: []).isEmpty)
        XCTAssertTrue(CodexSession.transcript(from: [["items": []]]).isEmpty)
    }

    // MARK: - Restore lifecycle

    func testRestoreSetsTheResumingLatchSynchronouslySoNoStartButtonFlashes() {
        let session = CodexSession()
        XCTAssertFalse(session.isResuming)

        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)

        // Synchronous, before any await: the UI checks this on the very next
        // render pass, and if it isn't set yet the Start CTA flashes.
        XCTAssertTrue(session.isResuming, "isResuming must latch before the async read starts")
        XCTAssertEqual(session.sessionId, "thread-abc", "wake() resumes self.threadId, so it must be set eagerly")
    }

    func testDoubleRestoreIsRejectedByTheLatch() {
        let session = CodexSession()
        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)
        // A second call (double-click, a re-entrant restore pass) must not
        // start a second read — two reads would append the transcript twice.
        session.restoreHibernated(threadId: "thread-other", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)
        XCTAssertEqual(session.sessionId, "thread-abc", "the second restore must be rejected outright, not overwrite the first")
    }

    func testAFailedHistoryReadStillLandsHibernatedRatherThanBackOnTheStartButton() async throws {
        let session = CodexSession()
        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)

        try await waitFor("hibernated") { session.state == .hibernated }

        XCTAssertEqual(session.state, .hibernated)
        XCTAssertFalse(session.isResuming, "the loading latch must clear once the read settles")
        // The thread id is still valid even though the read failed — waking
        // resumes it and the app-server returns the history then. Falling
        // back to .idle would put the Start button back, which is the whole
        // bug this removes.
        XCTAssertEqual(session.sessionId, "thread-abc")
    }

    // MARK: - Wake

    func testWhitespaceIntoAHibernatedTabDoesNotSpawnAnything() async throws {
        let session = CodexSession()
        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)
        try await waitFor("hibernated") { session.state == .hibernated }

        session.send(text: "   \n  ")

        // Waking costs a process spawn and a thread resume. An empty send
        // must not buy that just to discard the message on the far side.
        XCTAssertEqual(session.state, .hibernated, "whitespace must not trigger a wake")
    }

    func testARealMessageIntoAHibernatedTabActuallyWakesIt() async throws {
        let session = CodexSession()
        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)
        try await waitFor("hibernated") { session.state == .hibernated }

        session.send(text: "carry on")

        // The wake must leave .hibernated immediately and synchronously —
        // this is the whole feature. (It then fails to spawn, because the
        // test binary doesn't exist; that path is asserted below.)
        XCTAssertNotEqual(session.state, .hibernated, "a real message must trigger the wake, not sit in a dead tab")
    }

    func testAWakeThatCannotSpawnHandsTheTypedMessageBackInsteadOfEatingIt() async throws {
        let session = CodexSession()
        session.restoreHibernated(threadId: "thread-abc", cwd: URL(fileURLWithPath: "/tmp"), codexURL: unspawnable)
        try await waitFor("hibernated") { session.state == .hibernated }

        session.send(text: "please don't lose this")
        try await waitFor("spawn failure") {
            if case .terminated = session.state { return true }
            return false
        }

        // StreamSession's equivalent strands this text in memory — invisible
        // in the UI, but live enough for a later successful spawn to flush
        // it as a user turn nobody typed. It belongs back in the composer.
        XCTAssertTrue(
            session.composerDraft.contains("please don't lose this"),
            "a failed wake must return the message to the composer, not silently swallow it"
        )
    }

    func testHibernateIsRejectedFromIdleAndWithoutAThreadId() {
        let session = CodexSession()
        // .idle has no process to reclaim and no thread to resume — the
        // guard is what guarantees wake() always has a resumable id.
        session.hibernate()
        XCTAssertEqual(session.state, .idle, "hibernate() must be a no-op unless the session is .ready with a thread")
    }

    // MARK: - Helper

    private func waitFor(
        _ what: String,
        timeout: TimeInterval = 5,
        _ condition: @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("timed out waiting for \(what)")
    }
}
