import Foundation
import OSLog

// A "huge freeze, rainbow cursor everywhere" hang leaves NOTHING behind
// today — confirmed live: nothing in ~/Library/Logs/DiagnosticReports (no
// crash, no hang/spin report), nothing in the unified log, no jetsam kill.
// Nothing crashed, so Apple's own crash reporter has nothing to write, and
// macOS's own "app not responding" hang detector doesn't always trigger a
// saved report for every freeze that gets force-quit or resolves on its own.
//
// This is a lightweight self-contained watchdog so the NEXT freeze leaves a
// real, symbolicated stack sample of every thread (especially main) instead
// of silence. Pings the main thread from a background timer; if the ping
// hasn't been answered within `hangThreshold`, logs it via os_log (so
// `log show`/Console.app finally have something) and shells out to
// /usr/bin/sample — which suspends the process at the kernel level to
// capture stacks, so it works even on a genuinely wedged main thread that
// isn't cooperating.

private let log = Logger(subsystem: "com.munyamakosa.work", category: "watchdog")

/// All mutable state is behind `lock`; safe to share across the background
/// timer queue and whatever thread calls `start()`.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    /// How often the background timer checks in.
    private let checkInterval: TimeInterval = 1.0
    /// How long the main thread can go without answering before we call it
    /// a hang. Above the ~2s where macOS itself starts showing the spinning
    /// cursor, so this fires on real freezes, not routine per-frame work.
    private let hangThreshold: TimeInterval = 3.0
    /// How long `sample` spends capturing once triggered.
    private let sampleSeconds = 3
    /// Avoid overlap and give the app a chance to recover after `sample`
    /// intentionally suspends it.
    private let captureCooldown: TimeInterval = 30

    private let lock = NSLock()
    private var lastHeartbeat = Date()
    private var isCurrentlyHung = false
    private var captureInProgress = false
    private var lastCaptureAt: Date?
    private var timer: DispatchSourceTimer?

    private init() {}

    /// Idempotent — safe to call more than once, only the first call starts
    /// anything. Call once at app launch (AppDelegate.applicationDidFinishLaunching).
    func start() {
        lock.lock()
        guard timer == nil else { lock.unlock(); return }
        lastHeartbeat = Date()
        // A background queue, not the main run loop — a Timer scheduled on
        // main would stall right along with the thing it's supposed to be
        // watching.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + checkInterval, repeating: checkInterval)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
        lock.unlock()
        log.info("hang watchdog started — checking main-thread responsiveness every \(self.checkInterval, format: .fixed(precision: 1))s")
    }

    private func tick() {
        // Ask the main thread to check in. If it's free, this drains almost
        // immediately. If it's blocked, this just queues up harmlessly —
        // GCD coalesces nothing, it simply waits its turn once the main
        // thread frees up, which is exactly the signal we want.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.lastHeartbeat = Date()
            let wasHung = self.isCurrentlyHung
            self.isCurrentlyHung = false
            self.lock.unlock()
            if wasHung { log.notice("main thread responsive again") }
        }

        lock.lock()
        let staleness = Date().timeIntervalSince(lastHeartbeat)
        let alreadyFlagged = isCurrentlyHung
        let now = Date()
        var shouldCapture = false
        if staleness > hangThreshold, !alreadyFlagged {
            isCurrentlyHung = true
            let cooledDown = lastCaptureAt.map { now.timeIntervalSince($0) >= captureCooldown } ?? true
            if !captureInProgress, cooledDown {
                captureInProgress = true
                lastCaptureAt = now
                shouldCapture = true
            }
        }
        lock.unlock()

        guard staleness > hangThreshold, !alreadyFlagged else { return }

        log.fault("main thread unresponsive for \(staleness, format: .fixed(precision: 1))s — capturing a sample")
        Diagnostics.record(
            severity: .fault, subsystem: .hang, operation: .hangDetected, outcome: .observed,
            code: shouldCapture ? "capture-started" : "capture-suppressed",
            durationMilliseconds: Int(staleness * 1_000)
        )
        guard shouldCapture else { return }
        // Off the timer's own queue so a slow `sample` invocation never
        // delays the next scheduled check-in.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.captureSample()
        }
    }

    private func captureSample() {
        defer {
            lock.lock(); captureInProgress = false; lock.unlock()
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let dir = Self.hangsDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode_t(0o700))], ofItemAtPath: dir.path)
        } catch {
            log.error("Could not create hang diagnostics directory")
            Diagnostics.record(severity: .error, subsystem: .hang, operation: .hangSample, outcome: .failed, code: "storage-failed")
            return
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let outPath = dir.appendingPathComponent("hang-\(stamp).txt").path

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // -mayDie: grab symbol info immediately, in case a genuinely wedged
        // process crashes or gets force-quit mid-sample.
        process.arguments = [String(pid), String(sampleSeconds), "-mayDie", "-file", outPath]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                log.fault("Hang sample captured")
                Diagnostics.record(severity: .fault, subsystem: .hang, operation: .hangSample, outcome: .succeeded, code: "captured")
            } else {
                log.error("Hang sample process failed")
                Diagnostics.record(severity: .error, subsystem: .hang, operation: .hangSample, outcome: .failed, code: "sample-exit", measurements: ["exit_status": Int(process.terminationStatus)])
            }
        } catch {
            log.error("Could not run hang sampler")
            Diagnostics.record(severity: .error, subsystem: .hang, operation: .hangSample, outcome: .failed, code: "sample-spawn")
        }
    }

    private static func hangsDirectory() -> URL {
        DiagnosticsPaths.hangs()
    }
}
