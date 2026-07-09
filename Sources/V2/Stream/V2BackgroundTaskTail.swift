// Bounded tail-reading for a background task's output file (#69/#70). Same
// discipline as CoTerminalPane's folded-terminal tail: read a bounded chunk
// from the end, ANSI-strip, never the whole file — a build log can run to
// tens of MB while the task is still going.

import Foundation

enum V2BackgroundTaskTail {
    /// One line for the strip row: the last non-empty line in the file's
    /// final `bytes` bytes.
    static func lastLine(path: String, bytes: Int = 8 * 1024) -> String? {
        guard let data = readTail(path: path, bytes: bytes) else { return nil }
        let clean = strip(data)
        return clean
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .reversed()
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map(String.init)
    }

    /// The fuller tail for the peek modal — same bound, just more of it.
    static func fullTail(path: String, bytes: Int = 64 * 1024) -> [String] {
        guard let data = readTail(path: path, bytes: bytes) else { return [] }
        return strip(data)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    private static func readTail(path: String, bytes: Int) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? fh.seek(toOffset: start)
        return try? fh.readToEnd()
    }

    private static func strip(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}]*\u{07}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
