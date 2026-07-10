// Bounded tail-reading for a background task's output file (#69/#70). Same
// discipline as CoTerminalPane's folded-terminal tail: read a bounded chunk
// from the end, ANSI-strip, never the whole file — a build log can run to
// tens of MB while the task is still going.

import Foundation

enum V2BackgroundTaskTail {
    /// One line for the strip row: the last non-empty line in the file's
    /// final `bytes` bytes.
    static func lastLine(path: String, bytes: Int = 8 * 1024) -> String? {
        guard let tail = readTail(path: path, bytes: bytes) else { return nil }
        let clean = strip(tail.data)
        return clean
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
    }

    /// The fuller tail for the peek modal — same bound, just more of it. A
    /// mid-file start means the first line is a fragment of whatever line
    /// straddled the read boundary — drop it (same guard V2SubagentTail
    /// .activity uses), unless we actually read from byte 0 of the real file.
    static func fullTail(path: String, bytes: Int = 64 * 1024) -> [String] {
        guard let tail = readTail(path: path, bytes: bytes) else { return [] }
        var lines = strip(tail.data)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if tail.startedMidFile, !lines.isEmpty { lines.removeFirst() }
        return lines
    }

    /// Reads the file's final `bytes` bytes. `startedMidFile` is derived from
    /// the file's actual size (checked BEFORE the read), not from
    /// `data.count == bytes` after the fact — the latter misfires when a
    /// file's size happens to exactly equal the read bound while still being
    /// read from offset 0, which would wrongly drop a real first line as if
    /// it were a fragment.
    private static func readTail(path: String, bytes: Int) -> (data: Data, startedMidFile: Bool)? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let startedMidFile = size > UInt64(bytes)
        let start = startedMidFile ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        guard let data = try? fh.readToEnd() else { return nil }
        return (data, startedMidFile)
    }

    private static func strip(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
