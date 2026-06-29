// Shared subprocess runner for the orchestrators (loop verifier + harness
// phases). Replaces the two near-identical inline implementations that
// suffered from two bugs:
//
//   1. stderr buffer deadlock — Pipe's pipe buffer (~64 KB) fills if the
//      subprocess emits a lot to stderr while we wait on `waitUntilExit()`.
//      The child blocks on write, parent blocks on wait, process never
//      exits. We drain both pipes concurrently via readabilityHandler.
//
//   2. Orphaned subprocess on cancel — calling `Task.cancel()` on an outer
//      task does nothing for `process.waitUntilExit()` since that call
//      isn't a Swift concurrency suspension point. We bridge cancellation
//      explicitly: when the cancel handler fires we `process.terminate()`,
//      which lets the termination handler resume the continuation.
//
// Returns whatever stdout collected up to termination (full output on
// normal exit, partial on cancel / spawn failure).

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "subprocess")

enum V2Subprocess {

    /// Spawn the given executable, collect stdout into a string while
    /// concurrently draining stderr (logged at warning level), and honour
    /// Task cancellation by SIGTERM'ing the child.
    static func runCollectingStdout(
        executable: URL,
        args: [String],
        cwd: URL,
        environment: [String: String]? = nil
    ) async -> String {
        let box = ProcessBox()
        return await withTaskCancellationHandler(
            operation: {
                if Task.isCancelled { return "" }
                return await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = args
                    process.currentDirectoryURL = cwd
                    if let environment { process.environment = environment }

                    let stdout = Pipe()
                    let stderr = Pipe()
                    process.standardOutput = stdout
                    process.standardError = stderr

                    let stdoutBuf = DataBuffer()

                    stdout.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        stdoutBuf.append(chunk)
                    }
                    stderr.fileHandleForReading.readabilityHandler = { handle in
                        let chunk = handle.availableData
                        if chunk.isEmpty {
                            handle.readabilityHandler = nil
                            return
                        }
                        if let s = String(data: chunk, encoding: .utf8) {
                            // Log each non-empty line so multi-line errors
                            // don't get squashed into one entry.
                            for line in s.split(whereSeparator: \.isNewline) {
                                let trimmed = line.trimmingCharacters(in: .whitespaces)
                                if !trimmed.isEmpty {
                                    log.warning("subprocess stderr: \(trimmed, privacy: .public)")
                                }
                            }
                        }
                    }

                    // `terminationHandler` fires on a background queue once
                    // the child exits (either naturally or via terminate()).
                    // CheckedContinuation is safe to resume from any thread.
                    let resumeOnce = OneShotResumer(continuation: cont)
                    process.terminationHandler = { _ in
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        // Drain whatever is left in the pipe before we
                        // hand back the string.
                        let final = stdout.fileHandleForReading.availableData
                        if !final.isEmpty { stdoutBuf.append(final) }
                        resumeOnce.resume(with: stdoutBuf.string)
                    }

                    box.attach(process)

                    do {
                        try process.run()
                    } catch {
                        log.error("subprocess spawn failed: \(error.localizedDescription, privacy: .public)")
                        stdout.fileHandleForReading.readabilityHandler = nil
                        stderr.fileHandleForReading.readabilityHandler = nil
                        // terminationHandler won't fire if run() threw.
                        resumeOnce.resume(with: "")
                    }
                }
            },
            onCancel: {
                box.terminate()
            }
        )
    }

    // MARK: - Helpers

    /// Holds the running Process so the cancellation handler (which runs
    /// outside the operation closure's scope) can reach in and terminate.
    private final class ProcessBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?

        func attach(_ p: Process) {
            lock.lock(); defer { lock.unlock() }
            process = p
        }

        func terminate() {
            lock.lock(); defer { lock.unlock() }
            process?.terminate()
        }
    }

    /// Append-only data buffer protected by a lock; readabilityHandlers
    /// fire on a global queue so we need synchronisation.
    private final class DataBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func append(_ chunk: Data) {
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
        }

        var string: String {
            lock.lock(); defer { lock.unlock() }
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    /// CheckedContinuation can only be resumed once. We may race the spawn
    /// error path with terminationHandler (very rare), so wrap in a one-shot
    /// guard.
    private final class OneShotResumer: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<String, Never>

        init(continuation: CheckedContinuation<String, Never>) {
            self.continuation = continuation
        }

        func resume(with value: String) {
            lock.lock()
            let already = done
            done = true
            lock.unlock()
            if !already { continuation.resume(returning: value) }
        }
    }
}
