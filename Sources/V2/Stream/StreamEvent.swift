// Top-level NDJSON envelope from `claude -p --output-format stream-json`.
// Each line of the binary's stdout decodes to exactly one of these cases.
// Wire shapes confirmed via DesignSync research + claude-code-parser +
// Roasbeef/claude-agent-sdk-go protocol doc.

import Foundation

enum StreamEvent: Decodable, Sendable {
    case system(SystemEvent)
    case assistant(MessageEvent)
    case user(MessageEvent)
    case streamEvent(StreamEventInner)
    case result(ResultEvent)
    case controlRequest(ControlRequest)
    case controlResponse(ControlResponse)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? "unknown"
        switch type {
        case "system":           self = .system(try SystemEvent(from: decoder))
        case "assistant":        self = .assistant(try MessageEvent(from: decoder))
        case "user":             self = .user(try MessageEvent(from: decoder))
        case "stream_event":     self = .streamEvent(try StreamEventInner(from: decoder))
        case "result":           self = .result(try ResultEvent(from: decoder))
        case "control_request":  self = .controlRequest(try ControlRequest(from: decoder))
        case "control_response": self = .controlResponse(try ControlResponse(from: decoder))
        default:                 self = .unknown(type: type)
        }
    }
}

// MARK: - system

struct SystemEvent: Decodable, Sendable {
    /// "init" | "api_retry" | "compact_boundary"
    let subtype: String
    let sessionId: String?
    let model: String?
    let cwd: String?
    let tools: [String]?
    let mcpServers: [MCPServerInfo]?
    let permissionMode: String?
    let apiKeySource: String?

    // api_retry fields
    let attempt: Int?
    let maxRetries: Int?
    let retryDelayMs: Int?
    let errorStatus: String?

    enum CodingKeys: String, CodingKey {
        case subtype
        case sessionId = "session_id"
        case model, cwd, tools
        case mcpServers = "mcp_servers"
        case permissionMode
        case apiKeySource = "apiKeySource"
        case attempt
        case maxRetries = "max_retries"
        case retryDelayMs = "retry_delay_ms"
        case errorStatus = "error_status"
    }
}

struct MCPServerInfo: Decodable, Sendable {
    let name: String
    let status: String?
}

// MARK: - assistant / user

struct MessageEvent: Decodable, Sendable {
    let sessionId: String?
    let parentToolUseId: String?
    let message: Message

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case parentToolUseId = "parent_tool_use_id"
        case message
    }
}

struct Message: Decodable, Sendable {
    let role: String?
    let content: [ContentBlock]
    let id: String?
    let model: String?
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case role, content, id, model, usage
        case stopReason = "stop_reason"
    }

    // user.message.content can be a string OR an array of blocks. Decode both shapes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try? c.decodeIfPresent(String.self, forKey: .role)
        self.id = try? c.decodeIfPresent(String.self, forKey: .id)
        self.model = try? c.decodeIfPresent(String.self, forKey: .model)
        self.stopReason = try? c.decodeIfPresent(String.self, forKey: .stopReason)
        self.usage = try? c.decodeIfPresent(Usage.self, forKey: .usage)

        if let arr = try? c.decode([ContentBlock].self, forKey: .content) {
            self.content = arr
        } else if let text = try? c.decode(String.self, forKey: .content) {
            self.content = [.text(text)]
        } else {
            self.content = []
        }
    }
}

struct Usage: Decodable, Sendable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }

    var total: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0)
            + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }
}

// MARK: - stream_event (wraps raw SSE event from Anthropic Messages API)

struct StreamEventInner: Decodable, Sendable {
    let uuid: String?
    let sessionId: String?
    let parentToolUseId: String?
    let ttftMs: Int?
    let event: RawSSEEvent

    enum CodingKeys: String, CodingKey {
        case uuid, event
        case sessionId = "session_id"
        case parentToolUseId = "parent_tool_use_id"
        case ttftMs = "ttft_ms"
    }
}

struct RawSSEEvent: Decodable, Sendable {
    let type: String
    let index: Int?
    let delta: SSEDelta?
    let contentBlock: ContentBlock?
    let message: Message?

    enum CodingKeys: String, CodingKey {
        case type, index, delta, message
        case contentBlock = "content_block"
    }
}

struct SSEDelta: Decodable, Sendable {
    /// "text_delta" | "input_json_delta" | "thinking_delta" | "signature_delta"
    let type: String?
    let text: String?
    let partialJson: String?
    let thinking: String?
    let stopReason: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, usage
        case partialJson = "partial_json"
        case stopReason = "stop_reason"
    }
}

// MARK: - result

struct ResultEvent: Decodable, Sendable {
    /// "success" | "error_max_turns" | "error_during_execution" | ...
    let subtype: String?
    let sessionId: String?
    let totalCostUsd: Double?
    let numTurns: Int?
    let durationMs: Int?
    let isError: Bool?
    let result: String?
    let usage: Usage?

    enum CodingKeys: String, CodingKey {
        case subtype, result, usage
        case sessionId = "session_id"
        case totalCostUsd = "total_cost_usd"
        case numTurns = "num_turns"
        case durationMs = "duration_ms"
        case isError = "is_error"
    }
}

// MARK: - control_request / control_response

struct ControlRequest: Decodable, Sendable {
    let requestId: String
    let request: ControlRequestBody

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case request
    }
}

struct ControlRequestBody: Decodable, Sendable {
    let subtype: String  // "can_use_tool" | "initialize" | "interrupt" | "set_permission_mode"
    let toolName: String?
    let input: JSONValue?

    enum CodingKeys: String, CodingKey {
        case subtype, input
        case toolName = "tool_name"
    }
}

struct ControlResponse: Decodable, Sendable {
    let response: ControlResponseBody
}

struct ControlResponseBody: Decodable, Sendable {
    let subtype: String  // "success" | "error"
    let requestId: String
    // The inner shape varies by which request we're replying to:
    //   - permission_request_response → PermissionDecision (behavior/message)
    //   - initialize                  → {commands, agents, skills, plugins, …}
    //   - interrupt / set_model / …   → null or empty object
    // Keep it as opaque JSON so the parser tolerates every case; callers that
    // need permission fields can pull them out via .dig().
    let response: JSONValue?

    var permission: PermissionDecision? {
        guard let response, case .object(let dict) = response,
              case .string(let behavior) = dict["behavior"] ?? .null else { return nil }
        var msg: String? = nil
        if case .string(let s) = dict["message"] ?? .null { msg = s }
        return PermissionDecision(behavior: behavior, updatedInput: dict["updated_input"], message: msg)
    }

    enum CodingKeys: String, CodingKey {
        case subtype, response
        case requestId = "request_id"
    }
}

struct PermissionDecision: Decodable, Sendable {
    let behavior: String  // "allow" | "deny"
    let updatedInput: JSONValue?
    let message: String?
}
