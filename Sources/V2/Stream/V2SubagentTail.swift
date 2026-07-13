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
    ///
    /// Lock-protected rather than @MainActor (bug-hunt M22): callers now do
    /// the stat+read+parse behind this from a detached background task, so
    /// the once-a-second-per-visible-card cost stops landing on the main
    /// thread. A plain NSLock is enough — these dictionaries are tiny and
    /// held for microseconds, same pattern as CoTermRing's own lock.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var resolved: [String: URL] = [:]

    /// The agent's transcript file for a spawn, or nil while it hasn't
    /// appeared on disk yet. Prefers a direct agentId hit (background acks
    /// carry it); otherwise scans subagents/*.meta.json for the matching
    /// toolUseId — which also works for runs restored from history. Safe to
    /// call off the main actor — see the lock note on `resolved` above.
    static func transcript(sessionDir: URL, toolUseId: String, agentId: String?) -> URL? {
        cacheLock.lock()
        let cached = resolved[toolUseId]
        cacheLock.unlock()
        if let cached { return cached }

        let fm = FileManager.default
        let subagents = sessionDir.appendingPathComponent("subagents")

        if let agentId {
            let direct = subagents.appendingPathComponent("agent-\(agentId).jsonl")
            if fm.fileExists(atPath: direct.path) {
                cacheLock.lock()
                // Cap growth (bug-hunt M14): an app-lifetime cache with no
                // eviction would otherwise grow for as long as the app runs.
                // A full clear on overflow is fine — worst case a re-visited
                // spawn re-scans its meta file once.
                if resolved.count > 200 { resolved.removeAll() }
                resolved[toolUseId] = direct
                cacheLock.unlock()
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
            cacheLock.lock()
            if resolved.count > 200 { resolved.removeAll() }
            resolved[toolUseId] = jsonl
            cacheLock.unlock()
            return jsonl
        }
        return nil
    }

    // MARK: - Activity feed

    /// One human-readable line per meaningful transcript event, oldest
    /// first. `bytes` bounds the read; the first (likely partial) line of
    /// the chunk is dropped.
    static func activity(path: URL, bytes: Int = 256 * 1024) -> [String] {
        guard let tail = readTail(path: path, bytes: bytes) else { return [] }
        var lines = String(decoding: tail.data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        // A mid-file start means the first line is a fragment — drop it
        // unless we read the whole file from offset 0. Uses the actual
        // read-offset flag from readTail (bug-hunt M16) rather than
        // `data.count == bytes`, which used to misfire and drop a genuine
        // first line whenever the file's size happened to exactly equal
        // the read bound while still being read from offset 0.
        if tail.startedMidFile, !lines.isEmpty { lines.removeFirst() }
        return lines.compactMap { describe(line: String($0)) }
    }

    /// path → (file size when parsed, result). The card polls at 1Hz while
    /// an agent runs; a stat is cheap, re-parsing 64KB of JSONL every tick
    /// when nothing changed is not (PERFORMANCE.md rule 1: cache any parse).
    /// Lock-protected, not @MainActor — see the note on `resolved` above.
    nonisolated(unsafe) private static var lastActionCache: [String: (size: UInt64, action: String?)] = [:]

    /// Just the most recent action, for the delegation card's one-liner.
    /// Scans the tail chunk BACKWARD and returns the first describable line
    /// (bug-hunt M22) instead of describing every line in the chunk just to
    /// keep `.last` — a 64KB chunk routinely holds hundreds of JSONL events
    /// and only the newest describable one is ever shown, so forward-parsing
    /// the whole thing was wasted work on top of running on the main thread.
    static func lastAction(path: URL, bytes: Int = 64 * 1024) -> String? {
        let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? UInt64) ?? nil
        cacheLock.lock()
        let hit = lastActionCache[path.path]
        cacheLock.unlock()
        if let size, let hit, hit.size == size { return hit.action }

        guard let tail = readTail(path: path, bytes: bytes) else { return nil }
        var lines = String(decoding: tail.data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        if tail.startedMidFile, !lines.isEmpty { lines.removeFirst() }
        let action = lines.reversed().lazy.compactMap { describe(line: String($0)) }.first

        if let size {
            cacheLock.lock()
            // Cap growth (bug-hunt M14): unlike V2MarkdownText/V2RichText,
            // this cache had no eviction — a full clear on overflow is fine
            // here given how rarely this matters.
            if lastActionCache.count > 200 { lastActionCache.removeAll() }
            lastActionCache[path.path] = (size, action)
            cacheLock.unlock()
        }
        return action
    }

    // MARK: - Line → readable action

    /// A transcript line rendered as one feed row, or nil for lines that
    /// aren't worth a row (attachments, meta events, successful tool
    /// results — a success doesn't say anything the preceding "› tool"
    /// line didn't already imply, and every tool call gets one, so
    /// surfacing all of them would double the feed for no new information).
    ///
    /// Handles BOTH assistant lines (tool_use/text/thinking) and user lines
    /// (tool_result) — it used to only look at assistant lines at all, so a
    /// subagent tool call that FAILED was invisible here even though it's
    /// exactly the moment a user opening the peek sheet most wants to see.
    /// Confirmed via a real capture: a Read call inside a delegated agent
    /// hit an InputValidationError, and neither the live one-liner nor the
    /// full feed ever showed it — the only trace was the next successful
    /// tool call quietly appearing as if nothing had happened.
    private static func describe(line: String) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return nil }

        switch obj["type"] as? String {
        case "assistant":
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
                case "thinking":
                    // Persisted thinking blocks are ALWAYS empty on disk —
                    // same wire quirk as the main session (real text only
                    // ever arrives via the live thinking_delta stream,
                    // never persisted) — so there's no content to preview.
                    // But presence alone is real signal: without this case,
                    // describe() returned nil here, and lastAction()'s
                    // backward scan just re-surfaced whatever tool call
                    // came before it. Verified against a real 10-minute
                    // subagent transcript: thinking-only stretches of
                    // 30-90+ seconds are the NORM, not an edge case
                    // (thinking → tool_use → thinking → … nearly the whole
                    // run) — the card's one-liner sat frozen on stale text
                    // the entire time, with only a small pulsing dot as the
                    // sole "still alive" cue.
                    return "‹ thinking…"
                default:
                    continue
                }
            }
            return nil
        case "user":
            for block in content {
                guard block["type"] as? String == "tool_result",
                      block["is_error"] as? Bool == true
                else { continue }
                let text = toolResultText(block["content"])
                let firstLine = text.split(separator: "\n").first.map(String.init) ?? text
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return "✗ error" }
                return "✗ " + (trimmed.count > 140 ? String(trimmed.prefix(140)) + "…" : trimmed)
            }
            return nil
        default:
            return nil
        }
    }

    /// `tool_result.content` is either a plain string or an array of
    /// content blocks (text/image mixed) — extract whatever text is there.
    private static func toolResultText(_ raw: Any?) -> String {
        if let s = raw as? String { return s }
        if let blocks = raw as? [[String: Any]] {
            return blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return ""
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

    /// Reads the tail chunk and reports whether the read actually started
    /// mid-file (vs. legitimately from offset 0) — callers use this instead
    /// of inferring it from `data.count == bytes`, which misfires whenever
    /// the file's real size happens to exactly equal the read bound
    /// (bug-hunt M16).
    private static func readTail(path: URL, bytes: Int) -> (data: Data, startedMidFile: Bool)? {
        guard let fh = FileHandle(forReadingAtPath: path.path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let startedMidFile = size > UInt64(bytes)
        let start = startedMidFile ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return (data, startedMidFile)
    }
}
