import XCTest
@testable import Work

@MainActor
final class CodexSessionMappingTests: XCTestCase {
    func testProviderBadgeLabelsRemainDistinctAtEveryDensity() {
        XCTAssertEqual(V2AgentProvider.claude.badgeLabel(density: .full), "CLAUDE")
        XCTAssertEqual(V2AgentProvider.codex.badgeLabel(density: .full), "CODEX")
        XCTAssertEqual(V2AgentProvider.claude.badgeLabel(density: .compact), "CLD")
        XCTAssertEqual(V2AgentProvider.codex.badgeLabel(density: .compact), "CDX")
    }

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

    func testCodexThreadSummaryMapsOfficialHistoryShape() throws {
        let updated = 1_752_688_800
        let summary = try XCTUnwrap(CodexSession.decodeThreadSummary([
            "id": "0198-thread",
            "cwd": "/tmp/atelier-project",
            "name": NSNull(),
            "preview": "Fix provider continuity\nwith a second line",
            "createdAt": updated - 10,
            "updatedAt": updated
        ]))

        XCTAssertEqual(summary.id, "0198-thread")
        XCTAssertEqual(summary.cwd, "/tmp/atelier-project")
        XCTAssertEqual(summary.title, "Fix provider continuity")
        XCTAssertEqual(summary.updatedAt, Date(timeIntervalSince1970: TimeInterval(updated)))

        let entry = V2HistoryEntry(summary)
        XCTAssertEqual(entry.provider, .codex)
        XCTAssertEqual(entry.id, "codex:0198-thread")
    }

    func testCodexThreadSummaryRejectsMissingNativeIdentity() {
        XCTAssertNil(CodexSession.decodeThreadSummary(["cwd": "/tmp/project"]))
        XCTAssertNil(CodexSession.decodeThreadSummary(["id": "thread-only"]))
    }

    func testProviderHandoffUsesKeyedAdditionalContextMap() throws {
        let params = CodexSession.turnStartParams(
            threadId: "thread-1",
            input: [["type": "text", "text": "continue"]],
            model: "gpt-test",
            approvalPolicy: "on-request",
            effort: "medium",
            handoffContext: "bounded checkpoint"
        )

        // Round-trip through JSONSerialization so this verifies the actual
        // JSON wire shape rather than Swift dictionary generic types.
        let data = try JSONSerialization.data(withJSONObject: params)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contexts = try XCTUnwrap(wire["additionalContext"] as? [String: Any])
        XCTAssertNil(wire["additionalContext"] as? [[String: Any]], "Codex rejects an array here")
        let entry = try XCTUnwrap(contexts["atelier-provider-handoff"] as? [String: Any])
        XCTAssertEqual(entry["kind"] as? String, "untrusted")
        XCTAssertEqual(entry["value"] as? String, "bounded checkpoint")
    }

    func testTurnWithoutHandoffOmitsExperimentalField() {
        let params = CodexSession.turnStartParams(
            threadId: "thread-1",
            input: [["type": "text", "text": "hello"]],
            model: "gpt-test",
            approvalPolicy: "on-request",
            effort: "",
            handoffContext: nil
        )

        XCTAssertNil(params["additionalContext"])
        XCTAssertNil(params["effort"])
    }

    func testProviderTimelineRemainsVisibleWhenCodexTakesOver() {
        let session = CodexSession()
        session.adoptProviderTimeline(
            [.userText("existing Claude work"), .assistantBlock(.text("still here"))],
            from: .claude
        )

        XCTAssertEqual(session.transcript.count, 3)
        guard case .userText("existing Claude work") = session.transcript[0] else {
            return XCTFail("Expected the prior visible timeline to remain")
        }
        guard case .systemNote(.info, let note) = session.transcript[2] else {
            return XCTFail("Expected a provider boundary note")
        }
        XCTAssertTrue(note.contains("Claude"))
    }

    func testTabRetainsBothProviderSlotsAcrossActivationChanges() throws {
        let terminals = TerminalsController()
        let id = terminals.openModeB(projectCwd: "/tmp/project", title: "project", provider: .claude)
        let originalClaude = try XCTUnwrap(terminals.tabs.first(where: { $0.id == id })?.streamSession)
        let codex = CodexSession()

        terminals.setCodexSession(codex, on: id)
        var tab = try XCTUnwrap(terminals.tabs.first(where: { $0.id == id }))
        XCTAssertEqual(tab.provider, .codex)
        XCTAssertTrue(tab.streamSession === originalClaude)
        XCTAssertTrue(tab.codexSession === codex)

        terminals.setClaudeSession(originalClaude, on: id)
        tab = try XCTUnwrap(terminals.tabs.first(where: { $0.id == id }))
        XCTAssertEqual(tab.provider, .claude)
        XCTAssertTrue(tab.streamSession === originalClaude)
        XCTAssertTrue(tab.codexSession === codex)
    }

    func testLegacyWorkspaceSnapshotDecodesAsSingleClaudeSlot() throws {
        let data = try XCTUnwrap("""
        {
          "tabs": [{
            "projectCwd": "/tmp/project",
            "title": "project",
            "sessionId": "claude-legacy",
            "provider": "claude",
            "draft": "keep me"
          }],
          "activeSessionId": "claude-legacy"
        }
        """.data(using: .utf8))

        let snapshot = try JSONDecoder().decode(V2AppState.WorkspaceSnapshot.self, from: data)
        let tab = try XCTUnwrap(snapshot.tabs.first)
        XCTAssertEqual(tab.sessionId, "claude-legacy")
        XCTAssertEqual(tab.provider, .claude)
        XCTAssertNil(tab.providerSlotsVersion)
        XCTAssertNil(tab.claudeSessionId)
        XCTAssertNil(tab.codexThreadId)
    }

    func testDualProviderWorkspaceSnapshotRoundTripsBothNativeIdsAndDrafts() throws {
        let source = V2AppState.WorkspaceSnapshot(
            tabs: [.init(
                projectCwd: "/tmp/project",
                title: "project",
                sessionId: "codex-active",
                provider: .codex,
                draft: "codex draft",
                claudeSessionId: "claude-retained",
                codexThreadId: "codex-active",
                claudeDraft: "claude draft",
                codexDraft: "codex draft",
                providerSlotsVersion: 1
            )],
            activeSessionId: "codex-active"
        )

        let restored = try JSONDecoder().decode(
            V2AppState.WorkspaceSnapshot.self,
            from: JSONEncoder().encode(source)
        )
        let tab = try XCTUnwrap(restored.tabs.first)
        XCTAssertEqual(tab.provider, .codex)
        XCTAssertEqual(tab.claudeSessionId, "claude-retained")
        XCTAssertEqual(tab.codexThreadId, "codex-active")
        XCTAssertEqual(tab.claudeDraft, "claude draft")
        XCTAssertEqual(tab.codexDraft, "codex draft")
        XCTAssertEqual(tab.providerSlotsVersion, 1)
    }

    func testWorkspaceRestoreFallsBackToClaudeWhenCodexIsUnavailable() {
        XCTAssertEqual(
            V2AppState.restoredProvider(
                preferred: .codex,
                claudeAvailable: true,
                codexAvailable: false
            ),
            .claude
        )
    }

    func testWorkspaceRestoreFallsBackToCodexWhenClaudeHistoryIsUnavailable() {
        XCTAssertEqual(
            V2AppState.restoredProvider(
                preferred: .claude,
                claudeAvailable: false,
                codexAvailable: true
            ),
            .codex
        )
    }

    func testWorkspaceRestoreDropsOnlyEntriesWithNoUsableProviderSlot() {
        XCTAssertNil(
            V2AppState.restoredProvider(
                preferred: .claude,
                claudeAvailable: false,
                codexAvailable: false
            )
        )
    }
}
