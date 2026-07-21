import XCTest
@testable import Work

@MainActor
final class CodexSessionMappingTests: XCTestCase {
    func testProviderIdentityMapsToDistinctProductMarks() {
        XCTAssertEqual(V2AgentProvider.claude.logoAssetName, "LogoClaude")
        XCTAssertEqual(V2AgentProvider.codex.logoAssetName, "LogoChatGPT")
        XCTAssertNotEqual(V2AgentProvider.claude.logoAssetName, V2AgentProvider.codex.logoAssetName)
        XCTAssertEqual(V2AgentProvider.claude.displayName, "Claude")
        XCTAssertEqual(V2AgentProvider.codex.displayName, "Codex")
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

    // MARK: - Transcript parity (.agents/research/2026-07-16-bug-codex-transcript-parity.md)

    /// Fix design §4: "Test every app-server ThreadItem discriminator; no
    /// known type may silently return nil." All 18 variants from the
    /// installed codex-cli 0.144.4 schema (generated via
    /// `codex app-server generate-json-schema`), minimal-but-valid per their
    /// `required` fields.
    // MARK: - Multi-agent (collab) rows
    //
    // Shapes are the app-server's own schema (codex-cli 0.144.4):
    // agentsStates is a threadId → {status, message?} map documented "when
    // available", and agent paths are "/root" (the main thread, per
    // list_agents' own `"last_task_message":"Main thread"`) or "/root/<name>".

    func testCollabResultNamesAgentsInsteadOfPrintingThreadUUIDs() {
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c1", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["019f-aaaa"],
            "status": "completed",
            "agentsStates": ["019f-aaaa": ["status": "completed", "message": "audit finished"]]
        ]
        let text = CodexSession.collabResultText(item, agentNames: ["019f-aaaa": "/root/audit_measure_backend"])
        XCTAssertEqual(text, "audit_measure_backend — completed: audit finished")
    }

    func testCollabResultWithoutStateSaysWhatTheCallDidNotNoAgentState() {
        // agentsStates absent is NORMAL per the schema. The old code printed
        // the literal placeholder "(no agent state)" here, which read like a
        // bug and told the user nothing about a real spawn.
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c2", "tool": "spawnAgent",
            "senderThreadId": "t-root", "receiverThreadIds": ["019f-bbbb"],
            "status": "completed", "agentsStates": [String: Any]()
        ]
        let text = CodexSession.collabResultText(item, agentNames: ["019f-bbbb": "/root/fix_backend_billing"])
        XCTAssertEqual(text, "spawned fix_backend_billing")
        XCTAssertFalse(text.contains("no agent state"))
    }

    func testCollabResultFallsBackToAShortIdWhenTheNameIsNotKnownYet() {
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c3", "tool": "sendInput",
            "senderThreadId": "t-root", "receiverThreadIds": ["019f6f7e-fcb1-7800-a2b6-00f1c4942aa1"],
            "status": "completed", "agentsStates": [String: Any]()
        ]
        // SUFFIX of the id: UUIDv7 prefixes are timestamp bits, identical
        // for every agent spawned in the same ~65s window.
        XCTAssertEqual(CodexSession.collabResultText(item, agentNames: [:]), "sent input to c4942aa1")
    }

    func testCollabResultOrderIsStableAcrossRenders() {
        // Iterating a Swift dictionary is order-unstable, so the same call
        // could render its agents in a different order every re-render.
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c4", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": [],
            "status": "completed",
            "agentsStates": [
                "t-c": ["status": "running"], "t-a": ["status": "completed"], "t-b": ["status": "errored"]
            ]
        ]
        let names = ["t-a": "/root/alpha", "t-b": "/root/beta", "t-c": "/root/gamma"]
        let once = CodexSession.collabResultText(item, agentNames: names)
        for _ in 0..<25 {
            XCTAssertEqual(CodexSession.collabResultText(item, agentNames: names), once)
        }
        XCTAssertEqual(once, "alpha — completed\nbeta — errored\ngamma — running")
    }

    func testCollabResultWithNothingAtAllIsHonestRatherThanMysterious() {
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c5", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": [String](),
            "status": "completed", "agentsStates": [String: Any]()
        ]
        XCTAssertEqual(CodexSession.collabResultText(item, agentNames: [:]),
                       "no agent state reported for this call")
    }

    func testAgentDisplayNameTreatsRootAsTheMainThread() {
        XCTAssertEqual(CodexSession.agentDisplayName("/root"), "main thread")
        XCTAssertEqual(CodexSession.agentDisplayName("/root/context_transfer_verify"), "context_transfer_verify")
        // Trailing slash must not relabel the main thread as "root".
        XCTAssertEqual(CodexSession.agentDisplayName("/root/"), "main thread")
        XCTAssertEqual(CodexSession.agentDisplayName(""), "sub-agent")
    }

    func testCollabResultListsReceiversThatReportedNothing() {
        // A wait on three agents where one replied must not read as a
        // one-agent call.
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c8", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a", "t-b", "t-c"],
            "status": "completed",
            "agentsStates": ["t-a": ["status": "completed"]]
        ]
        let names = ["t-a": "/root/alpha", "t-b": "/root/beta", "t-c": "/root/gamma"]
        let text = CodexSession.collabResultText(item, agentNames: names)
        XCTAssertEqual(text, "alpha — completed\nbeta — no status reported\ngamma — no status reported")
    }

    func testMultiLineAgentMessagesStayOneRowPerAgent() {
        let item: [String: Any] = [
            "type": "collabAgentToolCall", "id": "c9", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"],
            "status": "completed",
            "agentsStates": ["t-a": ["status": "completed", "message": "Done.\nFound 3 issues."]]
        ]
        let text = CodexSession.collabResultText(item, agentNames: ["t-a": "/root/alpha"])
        XCTAssertEqual(text, "alpha — completed: Done. Found 3 issues.",
                       "interior newlines would render continuation text as malformed agent rows")
    }

    func testRespawnOfASettledThreadReopensTheRun() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
            "agentsStates": ["t-a": ["status": "completed"]]
        ], to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].state, .completed)
        // Re-spawning the same thread must bring the run back to life —
        // previously the spawn was skipped entirely and the new call's
        // card never resolved, and the second result could never land.
        CodexSession.applySubagentEvent(spawn(id: "c5"), to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs[0].state, .running)
        XCTAssertNil(runs[0].finishedAt)
    }

    func testASettledReportSurvivesALaterUnknownStatus() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
            "agentsStates": ["t-a": ["status": "completed", "message": "Found 3 races in CoTermRing.swift"]]
        ], to: &runs, names: [:], now: Date())
        // A status outside the known set, WITH a message — previously this
        // overwrote the agent's final report with a progress line.
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c3", "tool": "sendInput",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
            "agentsStates": ["t-a": ["status": "idle", "message": "waiting for input"]]
        ], to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].resultText, "Found 3 races in CoTermRing.swift",
                       "a settled run's final report must never be overwritten")
    }

    func testCRLFPromptsStillYieldAOneLineDescription() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(prompt: "first line\r\nsecond line"), to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].description, "first line",
                       "\\r\\n is one Character in Swift — splitting on \\n alone returns the whole string")
    }

    func testRunIdentityIsPerAgentNotPerSpawningCall() {
        let a = V2SubagentRun(toolUseId: "c1", description: "x", agentType: "a",
                              isBackground: true, startedAt: Date(), threadId: "t-a")
        let b = V2SubagentRun(toolUseId: "c1", description: "y", agentType: "b",
                              isBackground: true, startedAt: Date(), threadId: "t-b")
        XCTAssertNotEqual(a.id, b.id, "one spawn fanning out to N agents must yield N distinct rows")
    }

    func testSubAgentActivityReadsAsASentenceNotABarePath() {
        // This is the literal "/root interacted" line the transcript used
        // to show — indistinguishable from a stray filesystem path.
        let mapped = CodexSession.transcriptItem(from: [
            "type": "subAgentActivity", "id": "s1", "kind": "interacted",
            "agentPath": "/root", "agentThreadId": "t-root"
        ])
        guard case .systemNote(_, let text) = mapped.first else { return XCTFail("expected a system note") }
        XCTAssertEqual(text, "sub-agent main thread interacted")
    }

    func testSubAgentInterruptedReadsAsPastTense() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "subAgentActivity", "id": "s2", "kind": "interrupted",
            "agentPath": "/root/codex_send_trace", "agentThreadId": "t-x"
        ])
        guard case .systemNote(_, let text) = mapped.first else { return XCTFail("expected a system note") }
        XCTAssertEqual(text, "sub-agent codex_send_trace was interrupted")
    }

    func testHistoryIndexesAgentNamesBeforeMappingSoCollabRowsAreNamed() {
        // The naming subAgentActivity item lands AFTER the collab call that
        // targeted it — a single pass would render a raw id there.
        let turns: [[String: Any]] = [["items": [
            ["type": "collabAgentToolCall", "id": "c1", "tool": "wait",
             "senderThreadId": "t-root", "receiverThreadIds": ["t-late"], "status": "completed",
             "agentsStates": ["t-late": ["status": "completed"]]],
            ["type": "subAgentActivity", "id": "s1", "kind": "started",
             "agentPath": "/root/late_namer", "agentThreadId": "t-late"]
        ]]]
        let items = CodexSession.transcript(from: turns)
        let joined = items.compactMap { item -> String? in
            guard case .assistantBlock(.toolResult(_, let content, _)) = item,
                  case .text(let text) = content else { return nil }
            return text
        }.joined()
        XCTAssertTrue(joined.contains("late_namer"), "expected the collab row to resolve the name, got: \(joined)")
    }

    // MARK: - Sub-agent run registry
    //
    // CodexSession.subagentRuns was hardcoded `[]`, so Codex tabs had no
    // delegation cards and no runs strip while Claude tabs did.

    private func spawn(id: String = "c1", thread: String = "t-a", prompt: String = "Audit the billing backend") -> [String: Any] {
        ["type": "collabAgentToolCall", "id": id, "tool": "spawnAgent",
         "senderThreadId": "t-root", "receiverThreadIds": [thread],
         "status": "completed", "prompt": prompt, "agentsStates": [String: Any]()]
    }

    func testSpawnCreatesARunKeyedByTheCallSoTheInlineCardResolves() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs.count, 1)
        // The inline delegation card looks itself up by the tool_use id of
        // the block it renders — which is the collab call's own id.
        XCTAssertEqual(runs[0].toolUseId, "c1")
        XCTAssertEqual(runs[0].threadId, "t-a")
        XCTAssertEqual(runs[0].description, "Audit the billing backend")
        XCTAssertEqual(runs[0].state, .running)
    }

    func testSpawnIsNotDuplicatedIfTheSameCallIsSeenTwice() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs.count, 1)
    }

    func testLongPromptIsTruncatedToATaskLine() {
        var runs: [V2SubagentRun] = []
        let long = String(repeating: "verify the thing ", count: 20)
        CodexSession.applySubagentEvent(spawn(prompt: long + "\nsecond line"), to: &runs, names: [:], now: Date())
        XCTAssertLessThanOrEqual(runs[0].description.count, 90)
        XCTAssertFalse(runs[0].description.contains("\n"), "a card row is one line")
    }

    func testActivityBackfillsTheAgentNameOntoARunSpawnedBeforeItIdentified() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].agentType, "sub-agent")
        CodexSession.applySubagentEvent([
            "type": "subAgentActivity", "id": "s1", "kind": "started",
            "agentPath": "/root/audit_measure_backend", "agentThreadId": "t-a"
        ], to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].agentType, "audit_measure_backend")
    }

    func testCompletedStatusFinishesTheRunWithItsMessage() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
            "agentsStates": ["t-a": ["status": "completed", "message": "audit clean"]]
        ], to: &runs, names: [:], now: Date())
        XCTAssertEqual(runs[0].state, .completed)
        XCTAssertEqual(runs[0].resultText, "audit clean")
        XCTAssertNotNil(runs[0].finishedAt)
    }

    func testErroredAndInterruptedBothCountAsFailure() {
        for status in ["errored", "interrupted"] {
            var runs: [V2SubagentRun] = []
            CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
            CodexSession.applySubagentEvent([
                "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
                "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
                "agentsStates": ["t-a": ["status": status]]
            ], to: &runs, names: [:], now: Date())
            XCTAssertEqual(runs[0].state, .failed, "\(status) should read as failed")
        }
    }

    func testShutdownAgentIsOrphanedNotLeftClaimingToRun() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
            "agentsStates": ["t-a": ["status": "shutdown"]]
        ], to: &runs, names: [:], now: Date())
        // The agent is gone and can never report back — a strip row stuck
        // on "running" forever would be a lie.
        XCTAssertEqual(runs[0].state, .orphaned)
    }

    func testAFinishedRunIsNotReopenedByALaterStatus() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent(spawn(), to: &runs, names: [:], now: Date())
        for status in ["completed", "running"] {
            CodexSession.applySubagentEvent([
                "type": "collabAgentToolCall", "id": "c2", "tool": "wait",
                "senderThreadId": "t-root", "receiverThreadIds": ["t-a"], "status": "completed",
                "agentsStates": ["t-a": ["status": status]]
            ], to: &runs, names: [:], now: Date())
        }
        XCTAssertEqual(runs[0].state, .completed, "a settled run must stay settled")
    }

    func testStatusForAnUnknownThreadIsIgnored() {
        var runs: [V2SubagentRun] = []
        CodexSession.applySubagentEvent([
            "type": "collabAgentToolCall", "id": "c9", "tool": "wait",
            "senderThreadId": "t-root", "receiverThreadIds": ["t-ghost"], "status": "completed",
            "agentsStates": ["t-ghost": ["status": "completed"]]
        ], to: &runs, names: [:], now: Date())
        XCTAssertTrue(runs.isEmpty, "a status for an agent we never saw spawn must not invent a run")
    }

    func testCodexSpawnRendersAsADelegationCardLikeClaudes() {
        XCTAssertTrue(V2SubagentParser.isAgentSpawn(toolName: "collab.spawnAgent"))
        XCTAssertTrue(V2SubagentParser.isAgentSpawn(toolName: "Task"))
        XCTAssertFalse(V2SubagentParser.isAgentSpawn(toolName: "collab.wait"))
    }

    func testPeekFeedFlattensAThreadIntoActionLines() {
        let feed = V2SubagentTail.activity(items: [
            .userText("Audit the billing backend"),
            .assistantBlock(.text("Starting the audit.")),
            .assistantBlock(.toolUse(id: "t1", name: "Bash", input: .object(["command": .string("npm test")]))),
        ])
        XCTAssertEqual(feed, [
            "› task — Audit the billing backend",
            "Starting the audit.",
            "› Bash — npm test",
        ])
    }

    func testServerEchoOfTheSentUserMessageDoesNotDoubleRender() {
        let session = CodexSession()
        // send() appends the user's text the moment they hit return AND
        // records it as a pending echo; the app-server then echoes the
        // same message back as a completed userMessage item. The live path
        // must swallow exactly that echo — it painted every sent sentence
        // twice in the transcript.
        session.noteLocalUserEcho("hello there")
        session.handleNotification(method: "item/completed", params: [
            "item": ["type": "userMessage", "id": "u-echo-1",
                     "content": [["type": "text", "text": "hello there"]]]
        ])
        XCTAssertTrue(session.transcript.isEmpty,
                      "the composer's own append is the render; the server echo must not add a second bubble")
    }

    func testAUserRowFromAnotherSourceStillRenders() {
        // The skip is correlated with what THIS composer sent. A user row
        // arriving from anywhere else — a second client on the shared
        // thread, collab sendInput — must render, or the assistant's next
        // reply answers a question nobody can see.
        let session = CodexSession()
        session.handleNotification(method: "item/completed", params: [
            "item": ["type": "userMessage", "id": "u-other-1",
                     "content": [["type": "text", "text": "message from the CLI"]]]
        ])
        guard case .userText("message from the CLI") = session.transcript.first else {
            return XCTFail("an uncorrelated user row must render, got \(session.transcript)")
        }
    }

    func testTheEchoLedgerConsumesOneEntryPerEcho() {
        // Two identical sends → two echoes → both swallowed; a third
        // identical row (someone else typing the same text) renders.
        let session = CodexSession()
        session.noteLocalUserEcho("same")
        session.noteLocalUserEcho("same")
        for i in 0..<3 {
            session.handleNotification(method: "item/completed", params: [
                "item": ["type": "userMessage", "id": "u-\(i)",
                         "content": [["type": "text", "text": "same"]]]
            ])
        }
        XCTAssertEqual(session.transcript.count, 1, "two echoes consumed, the third row is real")
    }

    func testHistoryMappingStillRendersUserMessages() {
        // The echo skip is live-path only — a restored transcript's user
        // rows come through transcriptItem and must keep rendering.
        let mapped = CodexSession.transcriptItem(from: [
            "type": "userMessage", "id": "u1",
            "content": [["type": "text", "text": "from history"]]
        ])
        guard case .userText("from history") = mapped.first else {
            return XCTFail("history userMessage must still map to a user row")
        }
    }

    // Shape verified against a live codex-cli 0.144.4 config/read response
    // (2026-07-20): snake_case keys, table absent until something writes it.
    func testSandboxNetworkParsesEnabledFromConfigRead() {
        let response: [String: Any] = ["config": ["sandbox_workspace_write": ["network_access": true]], "origins": [:]]
        XCTAssertEqual(CodexSession.sandboxNetworkAccess(fromConfigRead: response), true)
    }

    func testSandboxNetworkDefaultsToOffWhenTableAbsent() {
        // No [sandbox_workspace_write] table is codex's default state, and
        // that default is network OFF — reporting nil here would hide the
        // toggle from exactly the users who need it most.
        let response: [String: Any] = ["config": ["model": "gpt-5.6-sol"], "origins": [:]]
        XCTAssertEqual(CodexSession.sandboxNetworkAccess(fromConfigRead: response), false)
    }

    func testSandboxNetworkIsUnknownWhenConfigMissingEntirely() {
        XCTAssertNil(CodexSession.sandboxNetworkAccess(fromConfigRead: [:]),
                     "a malformed response must read as unknown, not as a confident off")
    }

    func testSandboxNetworkUnparseableValueIsUnknownNotOff() {
        // For a security control, unknown collapsing to "off" is the
        // dangerous direction: the chip would claim the sandbox is closed
        // while it's actually open.
        let response: [String: Any] = ["config": ["sandbox_workspace_write": ["network_access": "yes"]], "origins": [:]]
        XCTAssertNil(CodexSession.sandboxNetworkAccess(fromConfigRead: response))
    }

    func testAllEighteenThreadItemDiscriminatorsMapToNonEmptyRows() {
        let fixtures: [String: [String: Any]] = [
            "userMessage": ["type": "userMessage", "id": "1", "content": [["type": "text", "text": "hi"]]],
            "hookPrompt": ["type": "hookPrompt", "id": "2", "fragments": [["text": "note"]]],
            "agentMessage": ["type": "agentMessage", "id": "3", "text": "hello"],
            "plan": ["type": "plan", "id": "4", "text": "the plan"],
            "reasoning": ["type": "reasoning", "id": "5", "summary": ["thinking…"]],
            "commandExecution": ["type": "commandExecution", "id": "6", "command": "ls", "commandActions": [], "cwd": "/tmp", "status": "inProgress"],
            "fileChange": ["type": "fileChange", "id": "7", "changes": [["path": "a.txt", "kind": ["type": "update"], "diff": "+x"]], "status": "inProgress"],
            "mcpToolCall": ["type": "mcpToolCall", "id": "8", "server": "s", "tool": "t", "arguments": [String: Any](), "status": "inProgress"],
            "dynamicToolCall": ["type": "dynamicToolCall", "id": "9", "tool": "t", "arguments": [String: Any](), "status": "inProgress"],
            "collabAgentToolCall": ["type": "collabAgentToolCall", "id": "10", "agentsStates": [String: Any](), "receiverThreadIds": [String](), "senderThreadId": "t1", "status": "inProgress", "tool": "spawnAgent"],
            "subAgentActivity": ["type": "subAgentActivity", "id": "11", "agentPath": "a/b", "agentThreadId": "t1", "kind": "started"],
            "webSearch": ["type": "webSearch", "id": "12", "query": "swift concurrency"],
            "imageView": ["type": "imageView", "id": "13", "path": "/tmp/img.png"],
            "sleep": ["type": "sleep", "id": "14", "durationMs": 500],
            "imageGeneration": ["type": "imageGeneration", "id": "15", "result": "ok", "status": "completed"],
            "enteredReviewMode": ["type": "enteredReviewMode", "id": "16", "review": "security"],
            "exitedReviewMode": ["type": "exitedReviewMode", "id": "17", "review": "security"],
            "contextCompaction": ["type": "contextCompaction", "id": "18"],
        ]
        for (type, item) in fixtures {
            let mapped = CodexSession.transcriptItem(from: item)
            XCTAssertFalse(mapped.isEmpty, "ThreadItem type '\(type)' mapped to zero rows — silently dropped")
        }
    }

    func testCommandExecutionWithoutTerminalStatusOnlyEmitsTheCall() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "commandExecution", "id": "cmd-1", "command": "pwd", "cwd": "/tmp", "status": "inProgress",
        ])
        XCTAssertEqual(mapped.count, 1)
        guard case .assistantBlock(.toolUse(let id, let name, _)) = mapped[0] else {
            return XCTFail("Expected a single toolUse row for an in-progress command")
        }
        XCTAssertEqual(id, "cmd-1")
        XCTAssertEqual(name, "Bash")
    }

    func testCommandExecutionCompletedPairsCallWithNonErrorResult() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "commandExecution", "id": "cmd-2", "command": "ls", "cwd": "/tmp",
            "status": "completed", "aggregatedOutput": "a.txt\nb.txt", "exitCode": 0,
        ])
        XCTAssertEqual(mapped.count, 2)
        guard case .assistantBlock(.toolUse(let callId, "Bash", _)) = mapped[0] else {
            return XCTFail("Expected the call row first")
        }
        guard case .assistantBlock(.toolResult(let resultId, let content, let isError)) = mapped[1] else {
            return XCTFail("Expected a paired result row")
        }
        XCTAssertEqual(callId, "cmd-2")
        XCTAssertEqual(resultId, "cmd-2", "toolResult.toolUseId must match the call's id for V2AssistantBlock's outcome lookup")
        XCTAssertEqual(isError, false)
        XCTAssertTrue(content.asString.contains("a.txt"))
        XCTAssertTrue(content.asString.contains("exit code 0"))
    }

    func testCommandExecutionFailedMarksResultAsError() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "commandExecution", "id": "cmd-3", "command": "false", "cwd": "/tmp",
            "status": "failed", "aggregatedOutput": "", "exitCode": 1,
        ])
        guard mapped.count == 2, case .assistantBlock(.toolResult(_, _, let isError)) = mapped[1] else {
            return XCTFail("Expected a paired error result")
        }
        XCTAssertEqual(isError, true)
    }

    func testFileChangeCompletedResultIncludesPathAndDiff() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "fileChange", "id": "fc-1",
            "changes": [["path": "src/a.swift", "kind": ["type": "update"], "diff": "+added line"]],
            "status": "completed",
        ])
        XCTAssertEqual(mapped.count, 2)
        guard case .assistantBlock(.toolUse(_, "Edit", _)) = mapped[0] else {
            return XCTFail("Expected an Edit call row")
        }
        guard case .assistantBlock(.toolResult(_, let content, let isError)) = mapped[1] else {
            return XCTFail("Expected a paired result row")
        }
        XCTAssertEqual(isError, false)
        XCTAssertTrue(content.asString.contains("src/a.swift"))
        XCTAssertTrue(content.asString.contains("+added line"))
    }

    /// Claude's own MCP tool names arrive as `mcp__server__tool` — Codex's
    /// mapping must match that exact convention so V2LiveToolWidget's
    /// `name.hasPrefix("mcp__")` dispatch (the "server · tool" split view)
    /// fires for Codex calls too, not just the generic fallback card.
    func testMcpToolCallUsesClaudesDoubleUnderscoreNamingConvention() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "mcpToolCall", "id": "mcp-1", "server": "supabase", "tool": "list_tables",
            "arguments": [String: Any](), "status": "completed",
            "result": ["content": [["type": "text", "text": "table_a\ntable_b"]]],
        ])
        guard case .assistantBlock(.toolUse(_, let name, _)) = mapped[0] else {
            return XCTFail("Expected an MCP call row")
        }
        XCTAssertEqual(name, "mcp__supabase__list_tables")
        guard case .assistantBlock(.toolResult(_, let content, let isError)) = mapped[1] else {
            return XCTFail("Expected a paired result row")
        }
        XCTAssertEqual(isError, false)
        XCTAssertTrue(content.asString.contains("table_a"))
    }

    func testMcpToolCallErrorSurfacesErrorMessageAsResult() {
        let mapped = CodexSession.transcriptItem(from: [
            "type": "mcpToolCall", "id": "mcp-2", "server": "supabase", "tool": "execute_sql",
            "arguments": [String: Any](), "status": "failed",
            "error": ["message": "permission denied for table users"],
        ])
        guard mapped.count == 2, case .assistantBlock(.toolResult(_, let content, let isError)) = mapped[1] else {
            return XCTFail("Expected a paired error result")
        }
        XCTAssertEqual(isError, true)
        XCTAssertEqual(content.asString, "permission denied for table users")
    }

    func testAlreadyStartedItemOnlyEmitsTheResultNotADuplicateCall() {
        let mapped = CodexSession.transcriptItem(
            from: [
                "type": "commandExecution", "id": "cmd-4", "command": "echo hi", "cwd": "/tmp",
                "status": "completed", "aggregatedOutput": "hi", "exitCode": 0,
            ],
            alreadyStarted: true
        )
        XCTAssertEqual(mapped.count, 1, "item/started already rendered the call — item/completed must not duplicate it")
        guard case .assistantBlock(.toolResult) = mapped[0] else {
            return XCTFail("Expected only the result row")
        }
    }

    func testContextCompactionMapsToTheSameCompactBoundaryClaudeUses() {
        let mapped = CodexSession.transcriptItem(from: ["type": "contextCompaction", "id": "cc-1"])
        XCTAssertEqual(mapped.count, 1)
        guard case .compactBoundary = mapped[0] else {
            return XCTFail("Expected contextCompaction to map to .compactBoundary")
        }
    }

    // MARK: - Live notification path (handleNotification, not just the pure mapper)

    func testReasoningTextDeltaStreamsIntoALiveThinkingBlock() {
        let session = CodexSession()
        session.handleNotification(method: "item/reasoning/textDelta", params: [
            "itemId": "r-1", "delta": "considering the ", "contentIndex": 0, "threadId": "t", "turnId": "u",
        ])
        session.handleNotification(method: "item/reasoning/textDelta", params: [
            "itemId": "r-1", "delta": "options", "contentIndex": 0, "threadId": "t", "turnId": "u",
        ])
        XCTAssertEqual(session.transcript.count, 1)
        guard case .assistantBlock(.thinking(let text, _)) = session.transcript[0] else {
            return XCTFail("Expected reasoning deltas to accumulate into one .thinking block")
        }
        XCTAssertEqual(text, "considering the options")
    }

    func testItemStartedShowsTheCallImmediatelyThenCompletedAppendsOnlyTheResult() {
        let session = CodexSession()
        session.handleNotification(method: "item/started", params: [
            "threadId": "t", "turnId": "u", "startedAtMs": 0,
            "item": ["type": "commandExecution", "id": "cmd-5", "command": "sleep 1", "cwd": "/tmp", "status": "inProgress"],
        ])
        XCTAssertEqual(session.transcript.count, 1, "item/started should show the call before the tool finishes")
        XCTAssertNotNil(session.toolStartTimes["cmd-5"])

        session.handleNotification(method: "item/completed", params: [
            "item": [
                "type": "commandExecution", "id": "cmd-5", "command": "sleep 1", "cwd": "/tmp",
                "status": "completed", "aggregatedOutput": "", "exitCode": 0,
            ],
        ])
        XCTAssertEqual(session.transcript.count, 2, "completion should append only the paired result, not a second call")
        XCTAssertEqual(session.toolOutcomes["cmd-5"], false)
    }

    func testTurnPlanUpdatedDrivesALiveTaskChecklistViaOneSyntheticAnchorRow() {
        let session = CodexSession()
        session.handleNotification(method: "turn/plan/updated", params: [
            "threadId": "t", "turnId": "u",
            "plan": [["step": "read the schema", "status": "completed"], ["step": "write the mapper", "status": "inProgress"]],
        ])
        XCTAssertEqual(session.taskItems.map(\.subject), ["read the schema", "write the mapper"])
        XCTAssertEqual(session.taskItems.map(\.status), ["completed", "in_progress"], "Codex's camelCase inProgress must map to Claude's snake_case in_progress")
        XCTAssertEqual(session.transcript.count, 1, "exactly one synthetic anchor row, even before any further update")

        session.handleNotification(method: "turn/plan/updated", params: [
            "threadId": "t", "turnId": "u",
            "plan": [["step": "read the schema", "status": "completed"], ["step": "write the mapper", "status": "completed"]],
        ])
        XCTAssertEqual(session.taskItems.map(\.status), ["completed", "completed"])
        XCTAssertEqual(session.transcript.count, 1, "later updates refresh taskItems in place, not a second anchor row")
    }

    func testStructuredWarningNotificationsSurfaceAsSystemNotes() {
        let session = CodexSession()
        session.handleNotification(method: "warning", params: ["message": "sandbox escalated to workspace-write"])
        session.handleNotification(method: "configWarning", params: ["summary": "unknown key in config.toml", "details": "ignored"])
        XCTAssertEqual(session.transcript.count, 2)
        for item in session.transcript {
            guard case .systemNote = item else { return XCTFail("Expected every warning to surface, not be silently logged") }
        }
    }

    func testTurnErrorNotificationSurfacesAndNotesRetry() {
        let session = CodexSession()
        session.handleNotification(method: "error", params: [
            "threadId": "t", "turnId": "u", "willRetry": true,
            "error": ["message": "rate limited"],
        ])
        guard case .systemNote(.error, let text) = session.transcript.last else {
            return XCTFail("Expected the turn error to surface as an error system note")
        }
        XCTAssertTrue(text.contains("rate limited"))
        XCTAssertTrue(text.contains("retrying"))
    }

    // MARK: - Concurrent approval requests (same bug class as #49 — StreamSession.permissionQueue)

    /// The real bug this guards against: Codex's app-server can fire two
    /// approval requests for one turn's parallel tool calls before the user
    /// answers the first. Pre-fix, the second's assignment to
    /// pendingPermission silently overwrote the first — orphaning its
    /// requestId forever, identical to the real munga-ai deadlock.
    func testSecondConcurrentApprovalRequestQueuesRatherThanClobberingTheFirst() {
        let session = CodexSession()
        session.handleServerRequest(id: "req-1", method: "item/commandExecution/requestApproval", params: [
            "command": "rm -rf build/",
        ])
        session.handleServerRequest(id: "req-2", method: "item/fileChange/requestApproval", params: [
            "reason": "apply patch",
        ])

        XCTAssertEqual(session.pendingPermission?.requestId, "req-1", "the first request must still be the one shown")
        XCTAssertEqual(session.queuedRequestCount, 1, "the second must queue, not vanish")
    }

    func testThirdConcurrentRequestAcrossBothKindsAlsoQueues() {
        let session = CodexSession()
        session.handleServerRequest(id: "req-1", method: "item/commandExecution/requestApproval", params: ["command": "ls"])
        session.handleServerRequest(id: "req-2", method: "item/tool/requestUserInput", params: [
            "questions": [["id": "q1", "question": "Which environment?"]],
        ])

        XCTAssertEqual(session.pendingPermission?.requestId, "req-1")
        XCTAssertNil(session.pendingUserInput, "a second kind of request must queue behind the first too, not show alongside it")
        XCTAssertEqual(session.queuedRequestCount, 1)
    }

    // MARK: - Auth-check fail-open + stuck login-in-progress

    /// Without a live client, refreshAccount cannot know the real auth
    /// state — it must say so (false) rather than silently leaving
    /// requiresChatGPTLogin at its default `false`, which start() would
    /// otherwise read as "confirmed authenticated" and wrongly proceed to
    /// openThreadIfNeeded().
    func testRefreshAccountReportsFailureWithoutALiveClient() async {
        let ok = await CodexSession().refreshAccount()
        XCTAssertFalse(ok)
    }

    func testCancelChatGPTLoginIsSafeAsANoOpWhenNothingIsInProgress() {
        let session = CodexSession()
        session.cancelChatGPTLogin()
        XCTAssertFalse(session.loginInProgress)
    }
}
