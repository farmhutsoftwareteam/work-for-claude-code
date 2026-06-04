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
    var lastActivity: Date
    var isActive: Bool       // true if this session is the one currently running

    static func == (lhs: Session, rhs: Session) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - Token usage for a single assistant message
struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    var outputTokens: Int
    var cacheCreationTokens: Int
    var cacheReadTokens: Int

    var total: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    static let zero = TokenUsage(inputTokens: 0, outputTokens: 0, cacheCreationTokens: 0, cacheReadTokens: 0)

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheCreationTokens: lhs.cacheCreationTokens + rhs.cacheCreationTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
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
        case text                              // normal text message
        case toolUse(tool: String, input: String)  // assistant called a tool
        case toolResult(tool: String, output: String, isError: Bool) // tool output
    }
    let id: UUID
    let role: Role
    let kind: Kind
    let text: String  // primary display text (for .text: the message, for toolUse: the tool summary)
}
