import Foundation
import AppKit
import Combine
import OSLog
import UniformTypeIdentifiers

struct PendingCodexApproval: Identifiable, Equatable {
    enum Kind: Equatable { case command, fileChange, permissions, mcp }
    let id = UUID()
    let requestId: String
    let kind: Kind
    let title: String
    let previewText: String
}

struct CodexInputQuestion: Identifiable, Equatable {
    enum ValueType: Equatable { case string, number, boolean }
    let id: String
    let header: String
    let prompt: String
    let options: [String]
    let isSecret: Bool
    let required: Bool
    let valueType: ValueType
}

struct PendingCodexUserInput: Identifiable, Equatable {
    enum Kind: Equatable { case tool, mcp }
    let id = UUID()
    let requestId: String
    let kind: Kind
    let title: String
    let questions: [CodexInputQuestion]
}

@MainActor
final class CodexSession: ObservableObject {
    private let log = Logger(subsystem: "com.munyamakosa.work", category: "codex-session")

    @Published private(set) var state: StreamSession.LifecycleState = .idle
    @Published private(set) var transcript: [TranscriptItem] = []
    @Published private(set) var model = ""
    @Published private(set) var effort = ""
    @Published private(set) var permissionMode = "on-request"
    @Published private(set) var availableModels: [CodexModel] = []
    @Published private(set) var account: CodexAccount?
    @Published private(set) var requiresChatGPTLogin = false
    @Published private(set) var pendingPermission: PendingCodexApproval?
    @Published private(set) var pendingUserInput: PendingCodexUserInput?
    @Published private(set) var mcpServers: [CodexMCPServer] = []
    @Published private(set) var endError: String?
    @Published private(set) var loginInProgress = false
    @Published private(set) var totalTokens = 0
    @Published private(set) var contextWindow: Int?

    private(set) var threadId: String?
    private(set) var turnId: String?
    /// Timestamp for the active model turn. Kept separate from process startup
    /// so the tab timer never counts account/model/MCP initialization time.
    private(set) var turnStartedAt: Date?
    private(set) var cwd: URL?
    var composerDraft = ""

    private var client: CodexAppServerClient?
    private var binary: URL?
    private var resumeThreadId: String?
    private var streamBuffer = ""
    private var streamingIndex: Int?
    private var streamingItemId: String?
    private var flushPending = false
    private let streamFlushInterval: TimeInterval = 0.033
    private var renderedItemIDs: Set<String> = []
    private var requestedPermissionGrant: [String: Any]?
    private var pendingProviderHandoffContext: String?
    private var mcpRefreshInFlight = false
    private var mcpRefreshQueued = false

    var selectedModel: CodexModel? {
        availableModels.first { $0.id == model || $0.model == model }
    }

    func start(
        cwd: URL,
        codexURL: URL,
        resumeId: String? = nil,
        model: String? = nil,
        permissionMode: String = "on-request",
        effort: String = ""
    ) {
        guard client == nil else { return }
        self.cwd = cwd
        self.binary = codexURL
        // A stopped CodexSession retains its native thread id. A fresh
        // app-server connection must explicitly resume that thread before it
        // can accept another turn; merely retaining `threadId` locally is not
        // enough for the new server process.
        let threadToResume = resumeId ?? threadId
        self.resumeThreadId = threadToResume
        if threadToResume != nil { self.threadId = nil }
        self.model = model ?? ""
        self.permissionMode = permissionMode
        self.effort = effort
        endError = nil
        state = .spawning

        let client = CodexAppServerClient(binary: codexURL)
        self.client = client
        client.onNotification = { [weak self] method, params in
            Task { @MainActor in self?.handleNotification(method: method, params: params.raw) }
        }
        client.onServerRequest = { [weak self] id, method, params in
            Task { @MainActor in self?.handleServerRequest(id: id, method: method, params: params.raw) }
        }
        client.onTermination = { [weak self] reason in
            Task { @MainActor in self?.handleTermination(reason) }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                try await client.start()
                self.state = .initializing
                await self.refreshAccount()
                await self.refreshModels()
                if !self.requiresChatGPTLogin { try await self.openThreadIfNeeded() }
                else { self.state = .idle }
                // MCP discovery must never gate thread creation or history
                // restore. Slow/startup-heavy servers update independently.
                Task { [weak self] in await self?.refreshMCPStatus() }
            } catch {
                client.stop()
                if self.client === client { self.client = nil }
                self.fail(error.localizedDescription)
            }
        }
    }

    func stop() {
        guard client != nil else { state = .terminated(reason: "Stopped"); return }
        state = .closing
        finalizeStreamingText()
        client?.stop()
        client = nil
        state = .terminated(reason: "Stopped")
    }

    /// Synchronous process teardown used during app termination/update, when
    /// an asynchronous cleanup task may never get another run-loop turn.
    func terminateNow() {
        finalizeStreamingText()
        client?.terminateNow()
        client = nil
        state = .terminated(reason: "Stopped")
    }

    func beginChatGPTLogin() {
        guard let client else { return }
        loginInProgress = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.request("account/login/start", params: [
                    "type": "chatgpt",
                    "appBrand": "codex",
                    "codexStreamlinedLogin": true,
                    "useHostedLoginSuccessPage": true
                ])
                guard let raw = result["authUrl"] as? String,
                      let url = URL(string: raw) else {
                    throw CodexAppServerError.invalidResponse
                }
                NSWorkspace.shared.open(url)
            } catch {
                self.loginInProgress = false
                self.fail(error.localizedDescription, terminal: false)
            }
        }
    }

    func refreshAccount() async {
        guard let client else { return }
        do {
            let response = try await client.request("account/read", params: ["refreshToken": false])
            let requires = response["requiresOpenaiAuth"] as? Bool ?? true
            if let raw = response["account"] as? [String: Any] {
                let type = raw["type"] as? String
                account = CodexAccount(
                    email: raw["email"] as? String,
                    planType: type == "apiKey" ? "API key" : raw["planType"] as? String
                )
            } else {
                account = nil
            }
            requiresChatGPTLogin = requires && account == nil
        } catch {
            log.error("account/read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshModels() async {
        guard let client else { return }
        do {
            var cursor: String?
            var collected: [CodexModel] = []
            repeat {
                var params: [String: Any] = ["includeHidden": false, "limit": 100]
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request("model/list", params: CodexJSONObject(params))
                let page = (response["data"] as? [[String: Any]] ?? []).compactMap(Self.decodeModel)
                collected.append(contentsOf: page)
                cursor = response["nextCursor"] as? String
            } while cursor != nil
            availableModels = collected
            if model.isEmpty {
                model = collected.first(where: \.isDefault)?.id ?? collected.first?.id ?? ""
            }
            if effort.isEmpty { effort = selectedModel?.defaultReasoningEffort ?? "" }
        } catch {
            log.error("model/list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func send(text: String, attachments: [URL] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!text.isEmpty || !attachments.isEmpty), state == .ready, let client, let threadId else { return }
        finalizeStreamingText()
        let attachmentNames = attachments.map(\.lastPathComponent)
        let displayText = text + (attachmentNames.isEmpty ? "" : "\n\nAttached: \(attachmentNames.joined(separator: ", "))")
        transcript.append(.userText(displayText))
        endError = nil
        turnStartedAt = Date()
        state = .working
        var input: [[String: Any]] = []
        if !text.isEmpty { input.append(["type": "text", "text": text]) }
        for url in attachments {
            let contentType = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
            if contentType?.conforms(to: .image) == true {
                input.append(["type": "localImage", "path": url.path])
            } else {
                input.append(["type": "mention", "name": url.lastPathComponent, "path": url.path])
            }
        }
        let handoffContext = pendingProviderHandoffContext
        let params = Self.turnStartParams(
            threadId: threadId,
            input: input,
            model: model,
            approvalPolicy: permissionMode,
            effort: effort,
            handoffContext: handoffContext
        )
        Task { [weak self] in
            do {
                let response = try await client.request("turn/start", params: CodexJSONObject(params))
                self?.turnId = (response["turn"] as? [String: Any])?["id"] as? String
                if self?.pendingProviderHandoffContext == handoffContext {
                    self?.pendingProviderHandoffContext = nil
                }
            } catch {
                self?.state = .ready
                self?.turnStartedAt = nil
                self?.log.error("turn/start failed: \(error.localizedDescription, privacy: .private)")
                self?.appendError("Send failed: \(error.localizedDescription)")
            }
        }
    }

    func setProviderHandoffContext(_ context: String) {
        pendingProviderHandoffContext = context
    }

    /// Keep the whole visible conversation on screen while the destination
    /// provider receives only the bounded ProviderHandoff checkpoint. This is
    /// display state, not an attempt to reuse another provider's native thread.
    func adoptProviderTimeline(_ items: [TranscriptItem], from provider: V2AgentProvider) {
        finalizeStreamingText()
        transcript = items
        transcript.append(.systemNote(kind: .info, text: "Continuing with Codex from \(provider.displayName)."))
        renderedItemIDs.removeAll()
    }

    /// Versioned app-server wire shape for a turn. Kept as a pure builder so
    /// tests can validate it against Codex's generated schema without starting
    /// a real paid turn.
    static func turnStartParams(
        threadId: String,
        input: [[String: Any]],
        model: String,
        approvalPolicy: String,
        effort: String,
        handoffContext: String?
    ) -> [String: Any] {
        var params: [String: Any] = [
            "threadId": threadId,
            "input": input,
            "model": model,
            "approvalPolicy": approvalPolicy
        ]
        if !effort.isEmpty { params["effort"] = effort }
        if let handoffContext {
            // Codex 0.144.4 TurnStartParams.additionalContext is a MAP keyed
            // by an opaque source id, not an array of entries.
            let entry: [String: Any] = ["kind": "untrusted", "value": handoffContext]
            params["additionalContext"] = ["atelier-provider-handoff": entry] as [String: Any]
        }
        return params
    }

    /// Read local Codex history through the same official app-server protocol
    /// used for live chats. This starts no model turn and consumes no tokens.
    static func listThreads(codexURL: URL) async throws -> [CodexThreadSummary] {
        let client = CodexAppServerClient(binary: codexURL)
        try await client.start()
        defer { client.stop() }

        var cursor: String?
        var threadsByID: [String: CodexThreadSummary] = [:]
        repeat {
            try Task.checkCancellation()
            var params: [String: Any] = [
                "limit": 100,
                "sortKey": "updated_at",
                "sortDirection": "desc"
            ]
            if let cursor { params["cursor"] = cursor }
            let response = try await client.request("thread/list", params: CodexJSONObject(params))
            for raw in response["data"] as? [[String: Any]] ?? [] {
                if let thread = decodeThreadSummary(raw) {
                    threadsByID[thread.id] = thread
                }
            }
            cursor = response["nextCursor"] as? String
        } while cursor != nil

        return threadsByID.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    static func decodeThreadSummary(_ raw: [String: Any]) -> CodexThreadSummary? {
        guard let id = raw["id"] as? String, !id.isEmpty,
              let cwd = raw["cwd"] as? String, !cwd.isEmpty else { return nil }
        let timestamp = (raw["updatedAt"] as? NSNumber)?.doubleValue
            ?? (raw["createdAt"] as? NSNumber)?.doubleValue
            ?? 0
        let explicitName = (raw["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = (raw["preview"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let title: String
        if let explicitName, !explicitName.isEmpty {
            title = explicitName
        } else if !preview.isEmpty {
            title = String(preview.split(whereSeparator: \.isNewline).first?.prefix(72) ?? Substring(preview.prefix(72)))
        } else {
            title = "thread \(String(id.prefix(8)))"
        }
        return CodexThreadSummary(
            id: id,
            cwd: cwd,
            title: title,
            updatedAt: Date(timeIntervalSince1970: timestamp)
        )
    }

    func interrupt() {
        Task { @MainActor [weak self] in
            guard let self, let client = self.client,
                  let threadId = self.threadId, let turnId = self.turnId else { return }
            _ = try? await client.request("turn/interrupt", params: ["threadId": threadId, "turnId": turnId])
        }
    }

    func respondToPermission(allow: Bool) {
        guard let pending = pendingPermission, let client else { return }
        pendingPermission = nil
        state = .working
        let result: [String: Any]
        switch pending.kind {
        case .command, .fileChange:
            result = ["decision": allow ? "accept" : "decline"]
        case .permissions:
            result = [
                "permissions": allow ? (requestedPermissionGrant ?? [:]) : [:],
                "scope": "turn"
            ]
            requestedPermissionGrant = nil
        case .mcp:
            result = ["action": allow ? "accept" : "decline"]
        }
        do { try client.respond(id: pending.requestId, result: result) }
        catch {
            state = .ready
            appendError("Approval reply failed: \(error.localizedDescription)")
        }
    }

    func respondToUserInput(answers: [String: String], cancelled: Bool = false) {
        guard let pending = pendingUserInput, let client else { return }
        pendingUserInput = nil
        state = .working
        do {
            switch pending.kind {
            case .tool:
                let payload = Dictionary(uniqueKeysWithValues: pending.questions.map { question in
                    (question.id, ["answers": cancelled ? [] : [answers[question.id, default: ""]]])
                })
                try client.respond(id: pending.requestId, result: ["answers": payload])
            case .mcp:
                guard !cancelled else {
                    try client.respond(id: pending.requestId, result: ["action": "cancel"])
                    return
                }
                var content: [String: Any] = [:]
                for question in pending.questions {
                    let raw = answers[question.id, default: ""]
                    switch question.valueType {
                    case .string: content[question.id] = raw
                    case .number: content[question.id] = Double(raw) ?? 0
                    case .boolean: content[question.id] = ["true", "yes", "1"].contains(raw.lowercased())
                    }
                }
                try client.respond(id: pending.requestId, result: ["action": "accept", "content": content])
            }
        } catch {
            state = .ready
            appendError("Input reply failed: \(error.localizedDescription)")
        }
    }

    func setModel(_ id: String) {
        model = id
        if let selected = selectedModel,
           !selected.supportedReasoningEfforts.contains(where: { $0.id == effort }) {
            effort = selected.defaultReasoningEffort
        }
    }

    func setEffort(_ value: String) { effort = value }
    func setPermissionMode(_ value: String) { permissionMode = value }

    func refreshMCPStatus() async {
        guard let client else { return }
        guard !mcpRefreshInFlight else {
            mcpRefreshQueued = true
            return
        }
        mcpRefreshInFlight = true
        defer {
            mcpRefreshInFlight = false
            if mcpRefreshQueued {
                mcpRefreshQueued = false
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(180))
                    await self?.refreshMCPStatus()
                }
            }
        }
        do {
            var cursor: String?
            var collected: [CodexMCPServer] = []
            repeat {
                var params: [String: Any] = ["detail": "full", "limit": 100]
                if let threadId { params["threadId"] = threadId }
                if let cursor { params["cursor"] = cursor }
                let response = try await client.request("mcpServerStatus/list", params: CodexJSONObject(params))
                collected.append(contentsOf: (response["data"] as? [[String: Any]] ?? []).compactMap { raw in
                guard let name = raw["name"] as? String else { return nil }
                return CodexMCPServer(
                    name: name,
                    authStatus: raw["authStatus"] as? String ?? "unsupported",
                    toolCount: (raw["tools"] as? [String: Any])?.count ?? 0,
                    resourceCount: (raw["resources"] as? [Any])?.count ?? 0
                )
                })
                cursor = response["nextCursor"] as? String
            } while cursor != nil
            mcpServers = collected
        } catch {
            log.error("mcpServerStatus/list failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loginMCP(name: String) {
        guard let client else { return }
        Task { [weak self] in
            do {
                var params: [String: Any] = ["name": name]
                if let threadId = self?.threadId { params["threadId"] = threadId }
                let response = try await client.request("mcpServer/oauth/login", params: CodexJSONObject(params))
                guard let raw = response["authorizationUrl"] as? String,
                      let url = URL(string: raw) else { throw CodexAppServerError.invalidResponse }
                NSWorkspace.shared.open(url)
            } catch {
                self?.appendError("MCP login failed: \(error.localizedDescription)")
            }
        }
    }

    func writeMCPServer(name: String, value: [String: Any]?, projectScoped: Bool) async throws {
        guard let client else { throw CodexAppServerError.notRunning }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CodexAppServerError.rpc(code: nil, message: "Server names may contain letters, numbers, hyphens, and underscores.")
        }
        var params: [String: Any] = [
            "keyPath": "mcp_servers.\(name)",
            "mergeStrategy": "upsert",
            "value": value ?? NSNull()
        ]
        if projectScoped, let cwd {
            let configDir = cwd.appendingPathComponent(".codex", isDirectory: true)
            try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
            params["filePath"] = configDir.appendingPathComponent("config.toml").path
        }
        _ = try await client.request("config/value/write", params: CodexJSONObject(params))
        _ = try await client.requestWithNullParams("config/mcpServer/reload")
        await refreshMCPStatus()
    }

    /// Explicit one-way bridge for a repo's checked-in Claude MCP file. Codex
    /// has its own config hierarchy, so copying is opt-in and never touches
    /// Claude's user-level secrets or auth cache.
    func importClaudeProjectMCPServers() async throws -> Int {
        guard let client, let cwd else { throw CodexAppServerError.notRunning }
        let source = cwd.appendingPathComponent(".mcp.json")
        let data = try Data(contentsOf: source)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAppServerError.rpc(code: nil, message: ".mcp.json is not a JSON object.")
        }
        let rawServers = root["mcpServers"] as? [String: Any] ?? root
        let destinationDirectory = cwd.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent("config.toml").path
        var imported = 0
        let allowedNameCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        for name in rawServers.keys.sorted() {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowedNameCharacters.contains),
                  let raw = rawServers[name] as? [String: Any],
                  let mapped = Self.codexMCPConfig(fromClaude: raw) else { continue }
            _ = try await client.request("config/value/write", params: [
                "keyPath": "mcp_servers.\(name)",
                "mergeStrategy": "upsert",
                "value": mapped,
                "filePath": destination
            ])
            imported += 1
        }
        _ = try await client.requestWithNullParams("config/mcpServer/reload")
        await refreshMCPStatus()
        return imported
    }

    private static func codexMCPConfig(fromClaude raw: [String: Any]) -> [String: Any]? {
        var mapped: [String: Any] = ["enabled": raw["disabled"] as? Bool != true]
        if let command = raw["command"] as? String, !command.isEmpty {
            mapped["command"] = command
            if let args = raw["args"] as? [String] { mapped["args"] = args }
            if let env = raw["env"] as? [String: String] { mapped["env"] = env }
            if let cwd = raw["cwd"] as? String { mapped["cwd"] = cwd }
            return mapped
        }
        if let url = raw["url"] as? String, !url.isEmpty {
            mapped["url"] = url
            if let headers = raw["headers"] as? [String: String] { mapped["http_headers"] = headers }
            return mapped
        }
        return nil
    }

    private func openThreadIfNeeded() async throws {
        guard threadId == nil, let client, let cwd else { state = .ready; return }
        var params: [String: Any] = [
            "cwd": cwd.path,
            "approvalPolicy": permissionMode,
            "sandbox": "workspace-write"
        ]
        if !model.isEmpty { params["model"] = model }
        let response: CodexJSONObject
        if let resumeThreadId {
            params["threadId"] = resumeThreadId
            response = try await client.request("thread/resume", params: CodexJSONObject(params))
        } else {
            response = try await client.request("thread/start", params: CodexJSONObject(params))
        }
        if let thread = response["thread"] as? [String: Any] {
            threadId = thread["id"] as? String
            if transcript.isEmpty,
               let turns = thread["turns"] as? [[String: Any]], !turns.isEmpty {
                transcript = Self.transcript(from: turns)
            }
        }
        if let actual = response["model"] as? String { model = actual }
        if let actual = response["reasoningEffort"] as? String { effort = actual }
        state = .ready
    }

    private func handleNotification(method: String, params: [String: Any]) {
        switch method {
        case "account/login/completed", "account/updated":
            loginInProgress = false
            Task { [weak self] in
                guard let self else { return }
                await self.refreshAccount()
                await self.refreshModels()
                if !self.requiresChatGPTLogin { try? await self.openThreadIfNeeded() }
            }
        case "mcpServer/oauthLogin/completed", "mcpServer/startupStatus/updated":
            Task { [weak self] in await self?.refreshMCPStatus() }
        case "turn/started":
            turnId = (params["turn"] as? [String: Any])?["id"] as? String
            if turnStartedAt == nil { turnStartedAt = Date() }
            state = .working
        case "turn/completed":
            finalizeStreamingText()
            let turn = params["turn"] as? [String: Any]
            if let error = turn?["error"] as? [String: Any] {
                appendError(error["message"] as? String ?? "Codex turn failed.")
            }
            pendingPermission = nil
            pendingUserInput = nil
            requestedPermissionGrant = nil
            turnId = nil
            turnStartedAt = nil
            state = .ready
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String,
               let itemId = params["itemId"] as? String {
                appendTextDelta(delta, itemId: itemId)
            }
        case "item/plan/delta":
            if let delta = params["delta"] as? String,
               let itemId = params["itemId"] as? String {
                appendTextDelta(delta, itemId: itemId)
            }
        case "thread/tokenUsage/updated":
            if let usage = params["tokenUsage"] as? [String: Any] {
                contextWindow = usage["modelContextWindow"] as? Int
                totalTokens = ((usage["total"] as? [String: Any])?["totalTokens"] as? Int) ?? totalTokens
            }
        case "thread/compacted":
            finalizeStreamingText()
            transcript.append(.compactBoundary)
        case "model/rerouted":
            let from = params["fromModel"] as? String
            let to = params["toModel"] as? String
            transcript.append(.assistantBlock(.fallback(fromModel: from, toModel: to)))
            if let to { model = to }
        case "item/completed":
            if let item = params["item"] as? [String: Any] { handleCompletedItem(item) }
        default:
            log.debug("Unhandled Codex notification: \(method, privacy: .public)")
        }
    }

    private func handleServerRequest(id: String, method: String, params: [String: Any]) {
        switch method {
        case "item/tool/requestUserInput":
            let questions = (params["questions"] as? [[String: Any]] ?? []).compactMap(Self.decodeToolQuestion)
            guard !questions.isEmpty else {
                try? client?.respond(id: id, result: ["answers": [:]])
                return
            }
            pendingUserInput = PendingCodexUserInput(
                requestId: id, kind: .tool, title: "Codex needs your input", questions: questions
            )
            state = .awaitingPermission
            return
        case "mcpServer/elicitation/request":
            if params["mode"] as? String == "url" {
                let url = params["url"] as? String ?? ""
                pendingPermission = PendingCodexApproval(
                    requestId: id, kind: .mcp, title: "MCP authorization",
                    previewText: [params["message"] as? String, url].compactMap { $0 }.joined(separator: "\n")
                )
                state = .awaitingPermission
                return
            }
            let questions = Self.decodeMCPQuestions(params["requestedSchema"] as? [String: Any] ?? [:])
            pendingUserInput = PendingCodexUserInput(
                requestId: id, kind: .mcp,
                title: params["message"] as? String ?? "MCP server needs information",
                questions: questions
            )
            state = .awaitingPermission
            return
        case "currentTime/read":
            try? client?.respond(id: id, result: ["currentTimeAt": Int(Date().timeIntervalSince1970)])
            return
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval", "item/permissions/requestApproval":
            break
        default:
            log.error("Unsupported Codex server request: \(method, privacy: .public)")
            try? client?.respondError(id: id, code: -32601, message: "Atelier does not support server request \(method)")
            return
        }
        let lower = method.lowercased()
        let preview: String
        let kind: PendingCodexApproval.Kind
        let title: String
        requestedPermissionGrant = nil
        if lower.contains("commandexecution") || params["command"] != nil {
            kind = .command; title = "Run command"
            preview = params["command"] as? String ?? params["reason"] as? String ?? "Command execution"
        } else if lower.contains("filechange") {
            kind = .fileChange; title = "Apply file changes"
            preview = params["reason"] as? String ?? params["grantRoot"] as? String ?? "Workspace file changes"
        } else if lower.contains("permission") {
            kind = .permissions; title = "Grant permissions"
            preview = params["reason"] as? String ?? params["cwd"] as? String ?? "Additional permissions"
            requestedPermissionGrant = params["permissions"] as? [String: Any]
        } else {
            kind = .mcp; title = "MCP request"
            preview = params["message"] as? String ?? "An MCP server needs confirmation"
        }
        pendingPermission = PendingCodexApproval(requestId: id, kind: kind, title: title, previewText: preview)
        state = .awaitingPermission
    }

    private static func decodeToolQuestion(_ raw: [String: Any]) -> CodexInputQuestion? {
        guard let id = raw["id"] as? String, let prompt = raw["question"] as? String else { return nil }
        let options = (raw["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
        return CodexInputQuestion(
            id: id, header: raw["header"] as? String ?? id, prompt: prompt,
            options: options, isSecret: raw["isSecret"] as? Bool ?? false,
            required: true, valueType: .string
        )
    }

    private static func decodeMCPQuestions(_ schema: [String: Any]) -> [CodexInputQuestion] {
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        return properties.keys.sorted().map { key in
            let raw = properties[key] ?? [:]
            let type = raw["type"] as? String ?? "string"
            let valueType: CodexInputQuestion.ValueType = type == "boolean" ? .boolean : (type == "number" || type == "integer" ? .number : .string)
            let options = raw["enum"] as? [String] ?? (valueType == .boolean ? ["true", "false"] : [])
            return CodexInputQuestion(
                id: key, header: raw["title"] as? String ?? key,
                prompt: raw["description"] as? String ?? raw["title"] as? String ?? key,
                options: options, isSecret: (raw["format"] as? String) == "password",
                required: required.contains(key), valueType: valueType
            )
        }
    }

    private func appendTextDelta(_ delta: String, itemId: String) {
        if streamingItemId != itemId {
            finalizeStreamingText()
            streamingItemId = itemId
            streamBuffer = ""
            transcript.append(.assistantBlock(.text("")))
            streamingIndex = transcript.count - 1
        }
        streamBuffer.append(delta)
        guard !flushPending else { return }
        flushPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + streamFlushInterval) { [weak self] in
            self?.flushStreamingText()
        }
    }

    private func flushStreamingText() {
        flushPending = false
        guard let index = streamingIndex, transcript.indices.contains(index) else { return }
        transcript[index] = .assistantBlock(.text(streamBuffer))
    }

    private func finalizeStreamingText() {
        flushStreamingText()
        if let streamingItemId { renderedItemIDs.insert(streamingItemId) }
        streamingIndex = nil
        streamingItemId = nil
        streamBuffer = ""
    }

    private func handleCompletedItem(_ item: [String: Any]) {
        guard let id = item["id"] as? String, !renderedItemIDs.contains(id) else { return }
        if id == streamingItemId { finalizeStreamingText(); return }
        if let mapped = Self.transcriptItem(from: item) {
            transcript.append(mapped)
            renderedItemIDs.insert(id)
        }
    }

    private func handleTermination(_ reason: String) {
        guard state != .closing else { return }
        if case .terminated = state { return }
        client = nil
        fail(reason)
    }

    private func fail(_ message: String, terminal: Bool = true) {
        endError = message
        appendError(message)
        if terminal { state = .terminated(reason: message) }
    }

    private func appendError(_ message: String) {
        transcript.append(.systemNote(kind: .error, text: message))
    }

    static func decodeModel(_ raw: [String: Any]) -> CodexModel? {
        guard let id = raw["id"] as? String else { return nil }
        let efforts = (raw["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { effort -> CodexReasoningEffort? in
            guard let id = effort["reasoningEffort"] as? String else { return nil }
            return CodexReasoningEffort(id: id, description: effort["description"] as? String ?? "")
        }
        return CodexModel(
            id: id,
            model: raw["model"] as? String ?? id,
            displayName: raw["displayName"] as? String ?? id,
            description: raw["description"] as? String ?? "",
            isDefault: raw["isDefault"] as? Bool ?? false,
            defaultReasoningEffort: raw["defaultReasoningEffort"] as? String ?? efforts.first?.id ?? "",
            supportedReasoningEfforts: efforts,
            inputModalities: raw["inputModalities"] as? [String] ?? ["text"]
        )
    }

    static func transcript(from turns: [[String: Any]]) -> [TranscriptItem] {
        turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap(transcriptItem)
        }
    }

    static func transcriptItem(from item: [String: Any]) -> TranscriptItem? {
        let type = item["type"] as? String ?? ""
        switch type {
        case "userMessage":
            let text = (item["content"] as? [[String: Any]] ?? [])
                .compactMap { $0["text"] as? String }.joined(separator: "\n")
            return text.isEmpty ? nil : .userText(text)
        case "agentMessage", "plan":
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            return .assistantBlock(.text(text))
        case "reasoning":
            let text = ((item["summary"] as? [String]) ?? []).joined(separator: "\n")
            return text.isEmpty ? nil : .assistantBlock(.thinking(text: text, signature: nil))
        case "commandExecution":
            let id = item["id"] as? String ?? UUID().uuidString
            let input: JSONValue = .object([
                "command": .string(item["command"] as? String ?? ""),
                "cwd": .string(item["cwd"] as? String ?? "")
            ])
            return .assistantBlock(.toolUse(id: id, name: "Bash", input: input))
        case "fileChange":
            let id = item["id"] as? String ?? UUID().uuidString
            return .assistantBlock(.toolUse(id: id, name: "Edit", input: jsonValue(item["changes"] ?? [])))
        case "mcpToolCall":
            let id = item["id"] as? String ?? UUID().uuidString
            let server = item["server"] as? String ?? "mcp"
            let tool = item["tool"] as? String ?? "tool"
            return .assistantBlock(.toolUse(id: id, name: "\(server).\(tool)", input: jsonValue(item["arguments"] ?? [:])))
        default:
            return nil
        }
    }

    private static func jsonValue(_ any: Any) -> JSONValue {
        switch any {
        case is NSNull: return .null
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as String: return .string(value)
        case let value as [Any]: return .array(value.map(jsonValue))
        case let value as [String: Any]: return .object(value.mapValues(jsonValue))
        default: return .string(String(describing: any))
        }
    }
}
