// AI-authored skill creation (#63) — the user describes a skill in plain
// language, Claude drafts the real SKILL.md content, and the result is
// shown for review before anything touches ~/.claude/skills/.
//
// Implementation: reuse StreamSession wholesale rather than writing a
// parallel one-shot process spawner — the stdin-JSON framing, spawn args,
// and event parsing are already tested there. The session is scoped to a
// throwaway temp directory with bypassPermissions (safe: nothing outside
// that directory can be touched, and the directory is deleted once the
// result is read), so Claude's Write tool call never hits a permission
// prompt and never lands in the user's real skills directory. Save is a
// separate, explicit step (SkillOperations.createSkill) — cancelling this
// flow leaves the real skills directory untouched.

import Foundation

enum V2SkillGeneratorError: Error, LocalizedError {
    case noBinary
    case timedOut
    case noFileWritten
    case sessionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noBinary:         return "Can't find the claude binary."
        case .timedOut:         return "Claude didn't finish drafting in time — try again or start from a blank template."
        case .noFileWritten:    return "Claude didn't write a SKILL.md — try rephrasing the description."
        case .sessionFailed(let m): return m
        }
    }
}

struct V2GeneratedSkill {
    let name: String
    let description: String
    let whenToUse: String?
    let model: String?
    let body: String   // everything after the frontmatter fence
}

@MainActor
enum V2SkillGenerator {

    /// Spawns a scoped session, asks Claude (via the skill-creator skill
    /// convention) to write a complete SKILL.md for the given description,
    /// and parses the result back. Cleans up its scratch directory in every
    /// exit path — success, error, or timeout.
    static func generate(
        description: String,
        claudeBinary: URL,
        model: String? = nil,
        timeout: TimeInterval = 90
    ) async throws -> V2GeneratedSkill {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-skill-draft-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let session = StreamSession()
        defer { session.stop() }

        session.start(cwd: scratch, claudeURL: claudeBinary, model: model, permissionMode: "bypassPermissions")
        try await waitFor(session: session, state: { $0.isReadyOrLater }, timeout: 20)

        let prompt = """
        Use the skill-creator skill to draft a new Claude Code skill for this request:

        \(description)

        Write the complete result to ./SKILL.md in the current directory (a scratch \
        directory — write directly, no need to ask). Follow SKILL.md conventions: YAML \
        frontmatter with name, description, and when_to_use, then the instructional body. \
        Keep the body under 500 lines. Don't create any other files. Reply with a short \
        confirmation once written — no need to show me the content in chat.
        """
        session.send(text: prompt)
        try await waitFor(session: session, state: { $0.isReady }, timeout: timeout)

        if case .terminated(let reason) = session.state {
            throw V2SkillGeneratorError.sessionFailed(reason)
        }

        let skillMd = scratch.appendingPathComponent("SKILL.md")
        guard let content = try? String(contentsOf: skillMd, encoding: .utf8) else {
            throw V2SkillGeneratorError.noFileWritten
        }
        guard let parsed = parse(content) else {
            throw V2SkillGeneratorError.noFileWritten
        }
        return parsed
    }

    /// Polls session.state on the run loop until `matches` is true or the
    /// timeout elapses. StreamSession's state is @Published/@MainActor —
    /// this stays off any Combine plumbing and just checks between spawns.
    private static func waitFor(
        session: StreamSession,
        state matches: (StreamSession.LifecycleState) -> Bool,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !matches(session.state) {
            if case .terminated = session.state { return }   // let the caller inspect the reason
            if Date() >= deadline { throw V2SkillGeneratorError.timedOut }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func parse(_ content: String) -> V2GeneratedSkill? {
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }

        var fields: [String: String] = [:]
        for line in lines[(first + 1)..<second] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            fields[key] = value
        }
        guard let name = fields["name"], let description = fields["description"] else { return nil }

        let bodyStart = min(second + 1, lines.count)
        let body = lines[bodyStart...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return V2GeneratedSkill(
            name: name,
            description: description,
            whenToUse: fields["when_to_use"],
            model: fields["model"],
            body: body.isEmpty ? "## Steps\n\n1. " : body
        )
    }
}

private extension StreamSession.LifecycleState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
    /// True once the spawn handshake is behind us — the initial .start()
    /// wait only needs "not still spawning," not a full turn's .ready.
    var isReadyOrLater: Bool {
        switch self {
        case .idle, .spawning, .initializing: return false
        default: return true
        }
    }
}
