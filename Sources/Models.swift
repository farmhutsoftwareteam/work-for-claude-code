import Foundation

// MARK: - Decoded from ~/.claude/history.jsonl
// Each line: { "display": "...", "timestamp": 1234567890123, "project": "/path", "sessionId": "uuid" }
struct HistoryEntry: Decodable {
    let display: String
    let timestamp: TimeInterval  // milliseconds since epoch
    let project: String
    let sessionId: String?
}

// MARK: - Decoded from ~/.claude/sessions/{pid}.json
struct ActiveSessionFile: Decodable {
    let pid: Int
    let sessionId: String
    let cwd: String
    let startedAt: TimeInterval
    let kind: String?
}

// MARK: - Domain: a project directory that has Claude history
struct Project: Identifiable, Hashable {
    let id: String           // encoded dir name: "/Users/foo/bar" -> "-Users-foo-bar"
    let cwd: String          // real absolute path
    var displayName: String  // last path component
    var sessions: [Session]
    var isActive: Bool       // true if any Claude process is running in this dir

    static func == (lhs: Project, rhs: Project) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Domain: one Claude conversation
struct Session: Identifiable, Hashable {
    let id: String           // the session UUID
    let projectCwd: String
    var slug: String?        // e.g. "spicy-yawning-cat" — lazily loaded from .jsonl tail
    var lastMessagePreview: String
    /// First substantive human prompt — what the session was actually about.
    /// Lazily read from the .jsonl head; "" once read but none found, nil until
    /// loaded. Far better as a title than the last message (often "/clear").
    var firstPrompt: String? = nil
    var lastActivity: Date
    var isActive: Bool       // true if this session is the one currently running

    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Token usage for a single assistant message
struct TokenUsage: Codable, Equatable, Sendable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int
    /// The portion of `cacheCreationTokens` written under the 1-hour cache
    /// TTL specifically (Anthropic's `cache_creation.ephemeral_1h_input_
    /// tokens`, confirmed present on real per-message usage objects — a
    /// 1h cache write costs ~1.6x a 5-min one). The remainder
    /// (cacheCreationTokens - cacheCreation1hTokens) is 5-min. Defaults to
    /// 0 for JSONL rows/cached data written before this field existed,
    /// which exactly preserves the old (implicit all-5-min) behavior for
    /// anything that predates the fix rather than silently changing it.
    var cacheCreation1hTokens: Int = 0
    /// Per-model breakdown of the four token counts above, keyed by the raw
    /// `message.model` string from JSONL (e.g. "claude-opus-4-8"). Empty when
    /// no model could be attributed to a row (older JSONL formats, partial
    /// streaming lines, etc.). The aggregate fields above remain the
    /// authoritative source of totals; `byModel` lets cost-aware UI surfaces
    /// split a session/day across the models it actually used.
    var byModel: [String: TokenUsage] = [:]

    var total: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    static let zero = TokenUsage()

    /// Explicit member-wise init so existing call sites that pass only the
    /// four positional token counts keep compiling; `byModel` defaults to `[:]`.
    init(
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheCreationTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        byModel: [String: TokenUsage] = [:]
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.byModel = byModel
    }

    /// Custom decode that tolerates missing `byModel` (pre-v2 cache rows that
    /// were written before this field existed — those caches are invalidated
    /// at load time, but this keeps the decode itself robust).
    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheCreationTokens, cacheReadTokens, cacheCreation1hTokens, byModel
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decode(Int.self, forKey: .inputTokens)
        outputTokens = try c.decode(Int.self, forKey: .outputTokens)
        cacheCreationTokens = try c.decode(Int.self, forKey: .cacheCreationTokens)
        cacheReadTokens = try c.decode(Int.self, forKey: .cacheReadTokens)
        cacheCreation1hTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreation1hTokens) ?? 0
        byModel = try c.decodeIfPresent([String: TokenUsage].self, forKey: .byModel) ?? [:]
    }

    /// Omit `byModel`/`cacheCreation1hTokens` from the encoded form when
    /// empty/zero so cached/serialised rows stay compact for stdio/pre-v2
    /// sessions that never populate them.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheCreationTokens, forKey: .cacheCreationTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        if cacheCreation1hTokens != 0 {
            try c.encode(cacheCreation1hTokens, forKey: .cacheCreation1hTokens)
        }
        if !byModel.isEmpty {
            try c.encode(byModel, forKey: .byModel)
        }
    }

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        var mergedByModel = lhs.byModel
        for (model, usage) in rhs.byModel {
            mergedByModel[model] = (mergedByModel[model] ?? .zero) + usage
        }
        return TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens,
            cacheCreation1hTokens: lhs.cacheCreation1hTokens + rhs.cacheCreation1hTokens,
            byModel: mergedByModel
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

// MARK: - Chat message parsed from a session .jsonl file
struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    enum Kind {
        case text(content: String)
        case toolUse(tool: String, input: String)
        case toolResult(tool: String, output: String, isError: Bool)
    }
    let id: UUID
    let role: Role
    let kind: Kind

    /// Display/preview text derived from `kind`. For `.toolResult` this is a
    /// 500-char preview — full output stays only in the enum case, so we
    /// never carry two strong references to the same multi-megabyte blob.
    /// Callers that need the full output read it directly from the case.
    var text: String {
        switch kind {
        case .text(let content):
            return content
        case .toolUse(let tool, let input):
            return input.isEmpty ? tool : "\(tool): \(input)"
        case .toolResult(_, let output, _):
            return output.count > 500 ? String(output.prefix(500)) : output
        }
    }
}
