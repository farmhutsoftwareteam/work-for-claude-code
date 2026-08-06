import XCTest
@testable import Work

/// #41 — the session changeset accumulates the agent's successful edits, merges
/// by path (MultiEdit counts its nested edits), excludes failed calls, and flags
/// out-of-tree writes. Driven through the same `handle(event:)` seam the
/// conformance tests use — no process spawned.
@MainActor
final class SessionChangesetTests: XCTestCase {
    private let decoder = JSONDecoder()

    private func feed(_ session: StreamSession, _ json: String) throws {
        session.handle(event: try decoder.decode(StreamEvent.self, from: Data(json.utf8)))
    }

    private func toolUse(_ id: String, _ name: String, input: String) -> String {
        #"{"type":"assistant","message":{"id":"m-\#(id)","role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":\#(input)}]}}"#
    }
    private func toolResult(_ id: String, isError: Bool) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"done","is_error":\#(isError)}]}}"#
    }

    func test_changeset_accumulates_merges_excludesFailures_flagsOutOfTree() throws {
        let session = StreamSession()
        let cwd = FileManager.default.temporaryDirectory
            .appendingPathComponent("proj-\(UUID().uuidString)").path
        try feed(session, #"{"type":"system","subtype":"init","cwd":"\#(cwd)","session_id":"s1"}"#)

        let inTree = cwd + "/Sources/A.swift"
        let outTree = "/tmp/outside-\(UUID().uuidString).txt"

        // Edit ok (in-tree)
        try feed(session, toolUse("e1", "Edit", input: #"{"file_path":"\#(inTree)"}"#))
        try feed(session, toolResult("e1", isError: false))
        // MultiEdit ok on the SAME file — 3 nested edits, merged by path
        try feed(session, toolUse("e2", "MultiEdit", input: #"{"file_path":"\#(inTree)","edits":[{},{},{}]}"#))
        try feed(session, toolResult("e2", isError: false))
        // Edit FAILED — must be excluded
        try feed(session, toolUse("e3", "Edit", input: #"{"file_path":"\#(cwd)/Failed.swift"}"#))
        try feed(session, toolResult("e3", isError: true))
        // Edit out-of-tree — flagged
        try feed(session, toolUse("e4", "Edit", input: #"{"file_path":"\#(outTree)"}"#))
        try feed(session, toolResult("e4", isError: false))

        let cs = session.sessionChangeset
        XCTAssertEqual(cs.count, 2, "one in-tree file (Edit+MultiEdit merged) + one out-of-tree; failed excluded")

        let inEntry = cs.first { $0.path.hasSuffix("Sources/A.swift") }
        XCTAssertNotNil(inEntry, "in-tree edit recorded")
        XCTAssertEqual(inEntry?.edits, 4, "1 Edit + 3 MultiEdit edits summed by path")
        XCTAssertEqual(inEntry?.outOfTree, false)

        XCTAssertTrue(cs.contains { $0.outOfTree }, "out-of-tree write flagged")
        XCTAssertFalse(cs.contains { $0.path.hasSuffix("Failed.swift") }, "failed edit excluded")
    }

    func test_changeset_resetsOnClear() throws {
        let session = StreamSession()
        try feed(session, toolUse("w1", "Write", input: #"{"file_path":"/tmp/new-\#(UUID().uuidString).txt"}"#))
        try feed(session, toolResult("w1", isError: false))
        XCTAssertEqual(session.sessionChangeset.count, 1)

        session.resetTranscript()
        XCTAssertTrue(session.sessionChangeset.isEmpty, "/clear resets the changeset")
    }
}
