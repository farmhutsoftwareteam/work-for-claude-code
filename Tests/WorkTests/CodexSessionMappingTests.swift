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
