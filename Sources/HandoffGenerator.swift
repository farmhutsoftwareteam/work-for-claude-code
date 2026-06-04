import Foundation
import AppKit

// MARK: - Session handoff generator (uses claude -p to summarize)

enum HandoffGenerator {

    enum HandoffState: Equatable {
        case idle
        case generating
        case done(String)
        case failed(String)
    }

    /// Build a context payload from conversation messages, then run claude -p to summarize.
    static func generate(
        session: Session,
        project: Project?,
        messages: [ChatMessage],
        completion: @escaping @Sendable (HandoffState) -> Void
    ) {
        // Build the raw context
        let context = buildContext(session: session, project: project, messages: messages)

        // Run claude -p in the background
        DispatchQueue.global(qos: .userInitiated).async {
            let prompt = """
            You are generating a session handoff brief. A developer worked on a codebase with Claude Code \
            and now wants to hand off context to a teammate so they can continue in their own LLM.

            Below is the session content. Generate a concise, structured handoff document in markdown:

            1. **Summary** — 2-3 sentences on what was accomplished
            2. **Files Changed** — list of files that were created, edited, or read (deduplicate)
            3. **Key Decisions** — important choices or corrections the user made
            4. **Current State** — where things stand right now
            5. **Next Steps** — what the teammate should pick up on (if apparent)

            Keep it under 400 words. Be specific — use file names, function names, and concrete details.

            ---

            \(context)
            """

            let result = runClaude(prompt: prompt)

            DispatchQueue.main.async {
                switch result {
                case .success(let summary):
                    completion(.done(summary))
                case .failure(let error):
                    completion(.failed(error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Build context from messages

    private static func buildContext(session: Session, project: Project?, messages: [ChatMessage]) -> String {
        var parts: [String] = []

        // Header
        parts.append("PROJECT: \(project?.cwd ?? "unknown")")
        parts.append("SESSION: \(session.slug ?? session.id)")
        parts.append("")

        // Extract files touched from tool calls
        var filesTouched = Set<String>()

        for msg in messages {
            switch msg.kind {
            case .toolUse(let tool, let input):
                // Extract file paths from tool inputs
                if ["Read", "Edit", "Write"].contains(tool), !input.isEmpty {
                    filesTouched.insert(input)
                }
            default:
                break
            }
        }

        if !filesTouched.isEmpty {
            parts.append("FILES TOUCHED:")
            for f in filesTouched.sorted() {
                parts.append("  - \(f)")
            }
            parts.append("")
        }

        // Conversation — include user prompts and assistant text responses (skip tool noise)
        parts.append("CONVERSATION:")
        for msg in messages {
            switch msg.kind {
            case .text:
                let role = msg.role == .user ? "USER" : "CLAUDE"
                // Truncate very long responses
                let text = msg.text.count > 500
                    ? String(msg.text.prefix(500)) + "…"
                    : msg.text
                parts.append("\(role): \(text)")
                parts.append("")
            case .toolUse(let tool, let input):
                parts.append("TOOL: \(tool) \(input)")
            default:
                break // skip tool results to keep context compact
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Run claude -p

    private static func runClaude(prompt: String) -> Result<String, Error> {
        let binary = Launcher.claudeBinary

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", "--output-format", "text", prompt]

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return .failure(error)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "Unknown error"
            return .failure(NSError(domain: "HandoffGenerator", code: Int(process.terminationStatus),
                                   userInfo: [NSLocalizedDescriptionKey: errStr]))
        }

        return .success(output)
    }
}
