// AsyncStream<StreamEvent> over a FileHandle. Uses Foundation's bytes.lines —
// it handles UTF-8 boundaries and partial reads for us. Malformed lines are
// logged and skipped instead of tearing down the stream.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "ndjson")

extension FileHandle {
    /// Read NDJSON lines off stdout and decode each into a StreamEvent.
    /// Cancellable — propagates Task cancellation to the bytes sequence.
    func ndjsonEvents(decoder: JSONDecoder = .init()) -> AsyncStream<StreamEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) { [self] in
                do {
                    for try await line in self.bytes.lines {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty,
                              let data = trimmed.data(using: .utf8) else { continue }
                        do {
                            let event = try decoder.decode(StreamEvent.self, from: data)
                            continuation.yield(event)
                        } catch {
                            log.warning("ndjson decode skipped line: \(error.localizedDescription, privacy: .public) — \(trimmed.prefix(200), privacy: .public)")
                        }
                    }
                } catch is CancellationError {
                    // expected on stop
                } catch {
                    log.error("ndjson read failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
