// Replays captured NDJSON fixtures through the StreamEvent decoder. Catches
// regressions in the parser when claude's wire protocol evolves between
// versions — Anthropic does not commit to documenting it
// (https://github.com/anthropics/claude-code/issues/24612), so the fixtures
// are our spec.

import XCTest
@testable import Work

final class ConformanceTests: XCTestCase {

    // MARK: - Fixture loading

    private func loadFixture(_ name: String, version: String) throws -> [Data] {
        let bundle = Bundle(for: ConformanceTests.self)
        // xcodegen `type: folder` adds the fixtures dir as a folder reference,
        // so the bundle resource path mirrors the on-disk structure.
        guard let url = bundle.url(
            forResource: name,
            withExtension: "ndjson",
            subdirectory: "fixtures/\(version)"
        ) else {
            throw XCTSkip("fixture fixtures/\(version)/\(name).ndjson not in test bundle")
        }
        let blob = try String(contentsOf: url, encoding: .utf8)
        return blob
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { Data($0.utf8) }
    }

    private func decodeAll(_ lines: [Data]) throws -> [StreamEvent] {
        let decoder = JSONDecoder()
        return try lines.map { try decoder.decode(StreamEvent.self, from: $0) }
    }

    // MARK: - Happy-path fixture (v2.1.187)

    func test_v2_1_187_happyPath_parsesEveryLineWithoutThrowing() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        XCTAssertGreaterThanOrEqual(lines.count, 10, "fixture too small to exercise the parser")

        let events = try decodeAll(lines)
        XCTAssertEqual(events.count, lines.count, "every line should decode")
    }

    func test_v2_1_187_firstEventIsSystemInit() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        let events = try decodeAll(lines)

        guard case .system(let sys) = events.first else {
            XCTFail("expected first event to be .system, got \(String(describing: events.first))")
            return
        }
        XCTAssertEqual(sys.subtype, "init")
        XCTAssertNotNil(sys.sessionId)
        XCTAssertNotNil(sys.model)
        XCTAssertNotNil(sys.cwd)
        XCTAssertNotNil(sys.tools, "tools array must be present on init")
        XCTAssertFalse(sys.tools?.isEmpty ?? true, "tools array must be non-empty")
        XCTAssertNotNil(sys.mcpServers, "mcp_servers array must be present (may be empty)")
        XCTAssertNotNil(sys.permissionMode)
    }

    func test_v2_1_187_unknownEventTypesFallThroughToUnknown() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        let events = try decodeAll(lines)

        // The capture includes `system/status` (unknown subtype, handled as
        // .system but with unrecognized subtype) and `rate_limit_event`
        // (unknown top-level type, must fall through to .unknown).
        let unknownTypes = events.compactMap { event -> String? in
            if case .unknown(let t) = event { return t }
            return nil
        }
        XCTAssertTrue(
            unknownTypes.contains("rate_limit_event"),
            "rate_limit_event should fall through to .unknown for forward compat"
        )
    }

    func test_v2_1_187_streamEventsCarryTextDelta() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        let events = try decodeAll(lines)

        let textDeltas = events.compactMap { event -> String? in
            if case .streamEvent(let s) = event,
               let delta = s.event.delta,
               delta.type == "text_delta" {
                return delta.text
            }
            return nil
        }
        XCTAssertFalse(textDeltas.isEmpty, "happy-path fixture must include at least one text_delta")
    }

    func test_v2_1_187_assistantMessageHasTextContent() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        let events = try decodeAll(lines)

        let assistantTexts = events.compactMap { event -> String? in
            guard case .assistant(let msg) = event else { return nil }
            for block in msg.message.content {
                if case .text(let t) = block { return t }
            }
            return nil
        }
        XCTAssertFalse(assistantTexts.isEmpty, "happy-path fixture should include an assistant text block")
    }

    func test_v2_1_187_finalResultIsSuccessWithMetadata() throws {
        let lines = try loadFixture("happy-path", version: "v2-1-187")
        let events = try decodeAll(lines)

        guard case .result(let r) = events.last else {
            XCTFail("expected last event to be .result, got \(String(describing: events.last))")
            return
        }
        XCTAssertEqual(r.subtype, "success")
        XCTAssertEqual(r.isError, false)
        XCTAssertNotNil(r.numTurns)
        XCTAssertNotNil(r.durationMs)
        XCTAssertNotNil(r.sessionId)
    }

    // MARK: - Decoder unit tests (synthetic envelopes)

    func test_polymorphicToolResultContent_acceptsStringForm() throws {
        let json = #"""
        {"type":"tool_result","tool_use_id":"u1","content":"file written","is_error":false}
        """#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        guard case .toolResult(_, let content, let isError) = block else {
            XCTFail("expected .toolResult, got \(block)")
            return
        }
        XCTAssertEqual(isError, false)
        if case .text(let s) = content {
            XCTAssertEqual(s, "file written")
        } else {
            XCTFail("expected .text content")
        }
    }

    func test_polymorphicToolResultContent_acceptsBlocksForm() throws {
        let json = #"""
        {"type":"tool_result","tool_use_id":"u1","content":[{"type":"text","text":"line 1"},{"type":"text","text":"line 2"}]}
        """#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        guard case .toolResult(_, let content, _) = block else {
            XCTFail("expected .toolResult, got \(block)")
            return
        }
        if case .blocks(let arr) = content {
            XCTAssertEqual(arr.count, 2)
        } else {
            XCTFail("expected .blocks content")
        }
    }

    func test_controlRequest_canUseToolPayloadDecodes() throws {
        let json = #"""
        {"type":"control_request","request_id":"req_42","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls /tmp"}}}
        """#
        let event = try JSONDecoder().decode(StreamEvent.self, from: Data(json.utf8))
        guard case .controlRequest(let req) = event else {
            XCTFail("expected .controlRequest, got \(event)")
            return
        }
        XCTAssertEqual(req.requestId, "req_42")
        XCTAssertEqual(req.request.subtype, "can_use_tool")
        XCTAssertEqual(req.request.toolName, "Bash")
        XCTAssertEqual(req.request.input?.dig("command")?.asString, "ls /tmp")
    }

    func test_jsonValueDigsNestedFields() throws {
        let json = #"""
        {"a":{"b":{"c":"deep"}}}
        """#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        XCTAssertEqual(value.dig("a", "b", "c")?.asString, "deep")
        XCTAssertNil(value.dig("a", "b", "missing"))
    }

    // MARK: - Version guard

    func test_semVerParseExtractsMajorMinorPatch() {
        XCTAssertEqual(
            SemVer.parse("claude-code v2.1.187 (build deadbeef)"),
            SemVer(major: 2, minor: 1, patch: 187)
        )
        XCTAssertEqual(SemVer.parse("v0.0.1"), SemVer(major: 0, minor: 0, patch: 1))
        XCTAssertNil(SemVer.parse("not a version"))
    }

    func test_semVerOrdering() {
        XCTAssertLessThan(
            SemVer(major: 2, minor: 1, patch: 127),
            SemVer(major: 2, minor: 1, patch: 128)
        )
        XCTAssertLessThan(
            SemVer(major: 2, minor: 0, patch: 999),
            SemVer(major: 2, minor: 1, patch: 0)
        )
    }
}
