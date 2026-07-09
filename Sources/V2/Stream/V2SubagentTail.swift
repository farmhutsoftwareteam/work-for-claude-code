// Live tailing of a subagent's own transcript (#39). An agent's work never
// enters the parent session's stream — it lands in
// <session-dir>/subagents/agent-<id>.jsonl on disk, so "watch it work"
// means tailing that file. Same bounded-read discipline as
// V2BackgroundTaskTail: read a chunk from the end, never the whole file
// (agent transcripts routinely reach many MB mid-run).

import Foundation

enum V2SubagentTail {

    // MARK: - Transcript resolution

    private struct Meta: Decodable {
        let toolUseId: String?
        let agentType: String?
        let description: String?
    }

    /// toolUseId → resolved jsonl path, cached because resolution scans a
    /// directory of meta files; misses are NOT cached (the meta file appears
    /// a beat after the spawn — a re-poll next tick should find it).
    @MainActor private static var resolved: [String: URL] = [:]

    /// The agent's transcript file for a spawn, or nil while it hasn't
    /// appeared on disk yet. Prefers a direct agentId hit (background acks
    /// carry it); otherwise scans subagents/*.meta.json for the matching
    /// toolUseId — which also works for runs restored from history.
    @MainActor
    static func transcript(sessionDir: URL, toolUseId: String, agentId: String?) -> URL? {
        if let hit = resolved[toolUseId] { return hit }
        let fm = FileManager.default
        let subagents = sessionDir.appendingPathComponent("subagents")

        if let agentId {
            let direct = subagents.appendingPathComponent("agent-\(agentId).jsonl")
            if fm.fileExists(atPath: direct.path) {
                resolved[toolUseId] = direct
                return direct
            }
        }
        guard let entries = try? fm.contentsOfDirectory(at: subagents, includingPropertiesForKeys: nil) else {
            return nil
        }
        for meta in entries where meta.lastPathComponent.hasSuffix(".meta.json") {
            guard let data = try? Data(contentsOf: meta),
                  let decoded = try? JSONDecoder().decode(Meta.self, from: data),
                  decoded.toolUseId == toolUseId
            else { continue }
            let jsonl = meta.deletingLastPathComponent()
                .appendingPathComponent(meta.lastPathComponent.replacingOccurrences(of: ".meta.json", with: ".jsonl"))
            guard fm.fileExists(atPath: jsonl.path) else { return nil }
            resolved[toolUseId] = jsonl
            return jsonl
        }
        return nil
    }

    // MARK: - Activity feed

    /// One human-readable line per meaningful transcript event, oldest
    /// first. `bytes` bounds the read; the first (likely partial) line of
    /// the chunk is dropped.
    static func activity(path: URL, bytes: Int = 256 * 1024) -> [String] {
        guard let data = readTail(path: path, bytes: bytes) else { return [] }
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        // A mid-file start means the first line is a fragment — drop it
        // unless we read the whole file from offset 0.
        if data.count == bytes, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { describe(line: String($0)) }
    }

    /// path → (file size when parsed, result). The card polls at 1Hz while
    /// an agent runs; a stat is cheap, re-parsing 64KB of JSONL every tick
    /// when nothing changed is not (PERFORMANCE.md rule 1: cache any parse).
    @MainActor private static var lastActionCache: [String: (size: UInt64, action: String?)] = [:]

    /// Just the most recent action, for the delegation card's one-liner.
    @MainActor
    static func lastAction(path: URL, bytes: Int = 64 * 1024) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? UInt64) ?? nil
        if let size, let hit = lastActionCache[path.path], hit.size == size { return hit.action }
        let action = activity(path: path, bytes: bytes).last
        if let size { lastActionCache[path.path] = (size, action) }
        return action
    }

    // MARK: - Line → readable action

    /// A transcript line rendered as one feed row, or nil for lines that
    /// aren't worth a row (attachments, results echoing back, meta events).
    private static func describe(line: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }

        for block in content {
            switch block["type"] as? String {
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let input = (block["input"] as? [String: Any]) ?? [:]
                if let brief = briefInput(input) { return "› \(name) — \(brief)" }
                return "› \(name)"
            case "text":
                guard let text = block["text"] as? String else { continue }
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                return trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed
            default:
                continue
            }
        }
        return nil
    }

    /// The most human-identifying scrap of a tool input — a path's last
    /// component, a command's head, a pattern — whichever the tool has.
    private static func briefInput(_ input: [String: Any]) -> String? {
        if let p = input["file_path"] as? String { return URL(fileURLWithPath: p).lastPathComponent }
        if let c = input["command"] as? String {
            let head = c.split(separator: "\n").first.map(String.init) ?? c
            return head.count > 70 ? String(head.prefix(70)) + "…" : head
        }
        if let p = input["pattern"] as? String { return p }
        if let d = input["description"] as? String { return d }
        if let u = input["url"] as? String { return u }
        if let q = input["query"] as? String { return q }
        return nil
    }

    private static func readTail(path: URL, bytes: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        return try? fh.readToEnd()
    }
}
