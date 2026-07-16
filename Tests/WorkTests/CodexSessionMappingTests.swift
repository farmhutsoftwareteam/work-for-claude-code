import XCTest
@testable import Work

@MainActor
final class CodexSessionMappingTests: XCTestCase {
    func testDynamicModelCatalogPreservesSolAndReasoningOptions() throws {
        let model = try XCTUnwrap(CodexSession.decodeModel([
            "id": "gpt-5.6-sol",
            "model": "gpt-5.6-sol",
            "displayName": "GPT-5.6 Sol",
            "description": "Low-latency coding model",
            "isDefault": true,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                ["reasoningEffort": "low", "description": "Fast"],
                ["reasoningEffort": "medium", "description": "Balanced"]
            ],
            "inputModalities": ["text", "image"]
        ]))

        XCTAssertEqual(model.id, "gpt-5.6-sol")
        XCTAssertEqual(model.model, "gpt-5.6-sol")
        XCTAssertTrue(model.isDefault)
        XCTAssertEqual(model.defaultReasoningEffort, "medium")
        XCTAssertEqual(model.supportedReasoningEfforts.map(\.id), ["low", "medium"])
        XCTAssertEqual(model.inputModalities, ["text", "image"])
    }

    func testHistoryMapsUserAgentAndCommandItemsInOrder() {
        let items = CodexSession.transcript(from: [[
            "items": [
                ["type": "userMessage", "content": [["type": "text", "text": "hello"]]],
                ["type": "agentMessage", "text": "hi"],
                ["type": "commandExecution", "id": "cmd-1", "command": "pwd", "cwd": "/tmp"]
            ]
        ]])

        XCTAssertEqual(items.count, 3)
        guard case .userText("hello") = items[0] else {
            return XCTFail("Expected the first history item to be the user message")
        }
        guard case .assistantBlock(.text("hi")) = items[1] else {
            return XCTFail("Expected the second history item to be the agent message")
        }
        guard case .assistantBlock(.toolUse(let id, let name, let input)) = items[2] else {
            return XCTFail("Expected the third history item to be a command tool call")
        }
        XCTAssertEqual(id, "cmd-1")
        XCTAssertEqual(name, "Bash")
        XCTAssertEqual(input, .object(["command": .string("pwd"), "cwd": .string("/tmp")]))
    }

    func testUnknownModelShapeIsIgnored() {
        XCTAssertNil(CodexSession.decodeModel(["displayName": "Missing id"]))
    }
}
