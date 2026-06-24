// AsyncStream<StreamEvent> over a FileHandle. Uses readabilityHandler so
// events stream as claude writes them — `FileHandle.bytes.lines` buffers
// on pipes (waits for EOF or larger chunks) and made StreamSession sit on
// "Initializing" forever. AtelierSpike uses the same handler-based pattern
// and proves it streams correctly against the live binary.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "ndjson")

extension FileHandle {
    /// Read NDJSON lines as they arrive and decode each into a StreamEvent.
    /// Malformed lines are logged + skipped; the stream stays alive.
    /// Continuation finishes on EOF (empty availableData) or when the
    /// consumer cancels.
    func ndjsonEvents(decoder: JSONDecoder = .init()) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let buffer = LineBuffer()
            self.readabilityHandler = { [weak self] handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    // EOF — process didn't write anything new; tear down.
                    self?.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.append(chunk)
                for lineData in buffer.drainLines() {
                    let trimmed = lineData
                    guard !trimmed.isEmpty else { continue }
                    do {
                        let event = try decoder.decode(StreamEvent.self, from: trimmed)
                        continuation.yield(event)
                    } catch {
                        let preview = String(data: trimmed.prefix(200), encoding: .utf8) ?? "<binary>"
                        log.warning("ndjson decode skipped: \(error.localizedDescription, privacy: .public) — \(preview, privacy: .public)")
                    }
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.readabilityHandler = nil
            }
        }
    }
}

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
}
