// Line-buffering used by StreamSession's stdout readabilityHandler —
// events stream as claude writes them. `FileHandle.bytes.lines` buffers on
// pipes (waits for EOF or larger chunks) and made StreamSession sit on
// "Initializing" forever; an AsyncStream wrapper around readabilityHandler
// was also tried and its events never reached the consumer. StreamSession
// drains the handle directly with a readabilityHandler + this buffer
// instead (see StreamSession.start()).

import Foundation

/// Append-and-drain line buffer. Used by the readabilityHandler to handle
/// chunks that don't align with line boundaries — claude's stdout writes
/// arrive in arbitrary chunk sizes.
final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
    }

    /// Return all complete (newline-terminated) lines in the buffer, leaving
    /// the trailing partial line for the next chunk.
    func drainLines() -> [Data] {
        lock.lock(); defer { lock.unlock() }
        var lines: [Data] = []
        while let newlineIdx = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<newlineIdx]
            lines.append(Data(line))
            data.removeSubrange(data.startIndex...newlineIdx)
        }
        return lines
    }

    /// Whatever's left after the last drainLines() call — a line with no
    /// trailing newline yet. On a clean stream this is always empty; on
    /// process EOF it holds a final event that never got its trailing "\n"
    /// (e.g. the process crashed/exited mid-write). Callers should attempt
    /// one last decode of this on EOF instead of silently dropping it (M9,
    /// bug-hunt 2026-07-10). Clears the buffer so it can't be double-read.
    func drainRemainder() -> Data {
        lock.lock(); defer { lock.unlock() }
        let remainder = data
        data.removeAll()
        return remainder
    }
}
