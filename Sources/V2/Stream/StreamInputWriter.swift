// Typed wrapper around the subprocess stdin FileHandle. Exposes
// sendUserText / respondToPermission / interrupt / setPermissionMode /
// setModel instead of free-form NDJSON writes.
//
// Each method writes one NDJSON line (envelope + "\n") to the binary's stdin.
// All writes are serialized via the actor so we can't interleave partial
// envelopes from two callers.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "stdin")

actor StreamInputWriter {
    private let fileHandle: FileHandle
    private let encoder: JSONEncoder
    private var requestCounter: Int = 0
    private var closed = false

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        self.encoder = enc
    }

    // MARK: - User turns

    func sendUserText(_ text: String) throws {
        try writeLine(UserEnvelope(message: .init(role: "user", content: text)))
    }

    /// Send the initialize handshake claude expects on spawn. Without this,
    /// `claude -p --input-format stream-json` sits idle waiting for input
    /// and never emits its first `system/init` event — the session stays
    /// stuck on .initializing forever. The SDK clients
    /// (claude-agent-sdk-python / claude-code-acp) send this same envelope
    /// right after process.run() before any user turn.
    func initialize() throws {
        try writeLine(InitializeEnvelope(
            requestId: nextRequestId(prefix: "init"),
            request: .init(subtype: "initialize")
        ))
    }

    // MARK: - Permissions

    enum Behavior: String { case allow, deny }

    func respondToPermission(requestId: String, behavior: Behavior, message: String? = nil) throws {
        try writeLine(ControlResponseEnvelope(
            response: .init(
                subtype: "success",
                requestId: requestId,
                response: .init(behavior: behavior.rawValue, message: message)
            )
        ))
    }

    // MARK: - Control requests

    func interrupt() throws {
        try writeLine(ControlRequestEnvelope(
            requestId: nextRequestId(prefix: "interrupt"),
            request: .init(subtype: "interrupt")
        ))
    }

    func setPermissionMode(_ mode: String) throws {
        try writeLine(ControlRequestEnvelope(
            requestId: nextRequestId(prefix: "perm_mode"),
            request: .init(subtype: "set_permission_mode", mode: mode)
        ))
    }

    func setModel(_ model: String) throws {
        try writeLine(ControlRequestEnvelope(
            requestId: nextRequestId(prefix: "model"),
            request: .init(subtype: "set_model", model: model)
        ))
    }

    /// Ask claude for the CURRENT status of every MCP server — the reply
    /// (control_response with an `mcpServers` array) is the only way to see
    /// a server move past the snapshot system/init reported: the binary
    /// never pushes MCP status changes on its own (verified against live
    /// wire captures — a server that finished connecting after init showed
    /// "pending" forever until a reconnect). Verified live against the real
    /// binary: subtype "mcp_status" returns name + status + config + scope
    /// per server.
    func requestMCPStatus() throws {
        try writeLine(ControlRequestEnvelope(
            requestId: nextRequestId(prefix: "mcp_status"),
            request: .init(subtype: "mcp_status")
        ))
    }

    /// Ask claude for the account's plan usage/rate-limit standing — the
    /// reply carries typed rate_limits (five_hour/seven_day utilization %,
    /// per-limit severity + reset times, subscription type). Verified live
    /// against the real binary 2026-07-17: zero-cost (no model turn), and
    /// only serviced AFTER the session has initialized — a request sent
    /// before init gets no response at all, so callers gate on ready state.
    func requestUsage() throws {
        try writeLine(ControlRequestEnvelope(
            requestId: nextRequestId(prefix: "usage"),
            request: .init(subtype: "get_usage")
        ))
    }

    // MARK: - Lifecycle

    func close() throws {
        guard !closed else { return }
        closed = true
        try fileHandle.close()
    }

    // MARK: - Internals

    private func nextRequestId(prefix: String) -> String {
        requestCounter += 1
        return "\(prefix)_\(requestCounter)"
    }

    private func writeLine<T: Encodable>(_ value: T) throws {
        guard !closed else { throw WriteError.closed }
        let data = try encoder.encode(value)
        // Combine envelope + newline into one write so we never publish a
        // half-line. The two-write form could leave the stdin stream with
        // a JSON envelope but no terminating newline if the second write
        // failed — the next writeLine would then concatenate with the
        // previous envelope and claude's parser would choke.
        var line = data
        line.append(0x0A)
        try fileHandle.write(contentsOf: line)
    }

    enum WriteError: Error { case closed }

    // MARK: - Envelopes

    private struct UserEnvelope: Encodable {
        let type = "user"
        let message: UserMessage
    }
    private struct UserMessage: Encodable {
        let role: String
        let content: String
    }
    private struct ControlRequestEnvelope: Encodable {
        let type = "control_request"
        let requestId: String
        let request: ControlRequestBody

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case request
        }
    }
    private struct ControlRequestBody: Encodable {
        let subtype: String
        var mode: String? = nil
        var model: String? = nil
    }

    // Initialize uses the same envelope shape as ControlRequestEnvelope but
    // we keep a dedicated type so the request body is tightly scoped to
    // 'subtype: initialize' with no extra fields.
    private struct InitializeEnvelope: Encodable {
        let type = "control_request"
        let requestId: String
        let request: InitializeBody

        enum CodingKeys: String, CodingKey {
            case type
            case requestId = "request_id"
            case request
        }
    }
    private struct InitializeBody: Encodable {
        let subtype: String
    }
    private struct ControlResponseEnvelope: Encodable {
        let type = "control_response"
        let response: ControlResponseBody
    }
    private struct ControlResponseBody: Encodable {
        let subtype: String
        let requestId: String
        let response: PermissionResponse

        enum CodingKeys: String, CodingKey {
            case subtype
            case requestId = "request_id"
            case response
        }
    }
    private struct PermissionResponse: Encodable {
        let behavior: String
        let message: String?
    }
}
