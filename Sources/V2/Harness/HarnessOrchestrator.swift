// HarnessOrchestrator — the long-form orchestration primitive (#25).
//
// Where LoopOrchestrator runs a tight doer-verifier cycle inside one
// long-lived StreamSession, a Harness runs THREE phases across FRESH
// `claude -p` processes:
//
//   1. PLAN     — generate a structured plan.md from the goal.
//   2. WORK_N   — execute the next chunk of the plan; append to progress.md.
//   3. REVIEW_N — check if the goal is met (PASS/FAIL); on FAIL, loop back
//                 to WORK_N+1 with the updated progress.
//
// Why fresh processes per phase: each work iteration starts from zero
// context. The progress.md file is the only state that crosses iterations —
// which means the harness survives Claude Code context limits on long jobs.
//
// On-disk layout:
//   ~/Library/Application Support/com.munyamakosa.work/harnesses/<uuid>/
//     ├── plan.md       (written once by the plan phase)
//     ├── progress.md   (appended by each work iteration)
//     └── reviews/<n>.md (saved verifier output per review)

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "harness")

// MARK: - Config + iterations

struct HarnessConfig: Equatable {
    var goal: String
    /// Hard cap on work-review iterations. Each iteration may include many
    /// tool calls inside the spawned claude -p run; the cap bounds the
    /// number of *iterations*, not the per-iteration turn count.
    var maxIterations: Int
    /// Pass `--dangerously-skip-permissions` to the work-phase spawn so the
    /// agent doesn't pause on tool prompts. Plan + review phases are
    /// read-only and never use this flag.
    var skipPermissions: Bool

    static let defaults = HarnessConfig(
        goal: "",
        maxIterations: 5,
        skipPermissions: false
    )
}

struct HarnessIteration: Identifiable, Equatable {
    let id = UUID()
    let number: Int
    var workSummary: String = ""
    var reviewVerdict: String = ""
    var passed: Bool? = nil
}

// MARK: - Orchestrator

@MainActor
final class HarnessOrchestrator: ObservableObject {

    enum Phase: Equatable {
        case idle
        case planning
        case working(iteration: Int)
        case reviewing(iteration: Int)
        case completed
        case failed(reason: String)
        case stopped
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var plan: String = ""
    @Published private(set) var progress: String = ""
    @Published private(set) var iterations: [HarnessIteration] = []

    let id = UUID()
    let config: HarnessConfig
    let cwd: URL
    let claudeURL: URL
    let storageRoot: URL

    private var currentTask: Task<Void, Never>?

    var planURL: URL { storageRoot.appendingPathComponent("plan.md") }
    var progressURL: URL { storageRoot.appendingPathComponent("progress.md") }
    func reviewURL(_ n: Int) -> URL {
        storageRoot.appendingPathComponent("reviews/\(n).md")
    }

    // MARK: - Init

    init(config: HarnessConfig, cwd: URL, claudeURL: URL) {
        self.config = config
        self.cwd = cwd
        self.claudeURL = claudeURL
        self.storageRoot = HarnessOrchestrator.storageRoot(forId: id)
    }

    /// Application Support root that holds every harness directory.
    nonisolated static var harnessesRoot: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("com.munyamakosa.work")
            .appendingPathComponent("harnesses")
    }

    /// Lightweight on-disk record of a previously-run harness. Used by the
    /// dock panel's empty state to offer resume/inspect.
    struct SavedHarness: Identifiable, Equatable {
        let id: UUID
        let url: URL
        let createdAt: Date
        /// First non-empty line of plan.md, used as a label. Empty if the
        /// plan file is missing or empty.
        let summary: String
        let hasProgress: Bool
    }

    /// Enumerate harness directories under Application Support and return
    /// their summaries newest-first. Excludes the currently-active harness
    /// (matching `excluding`) if provided.
    nonisolated static func listSaved(excluding currentId: UUID? = nil) -> [SavedHarness] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: harnessesRoot,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries.compactMap { url -> SavedHarness? in
            guard url.hasDirectoryPath,
                  let uuid = UUID(uuidString: url.lastPathComponent),
                  uuid != currentId else { return nil }
            let attrs = try? url.resourceValues(forKeys: [.creationDateKey])
            let created = attrs?.creationDate ?? .distantPast

            let planURL = url.appendingPathComponent("plan.md")
            let progressURL = url.appendingPathComponent("progress.md")
            let plan = (try? String(contentsOf: planURL, encoding: .utf8)) ?? ""
            let firstLine = plan
                .split(whereSeparator: \.isNewline)
                .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                .map { line -> String in
                    var s = String(line)
                    // Strip Markdown heading markers for a cleaner label.
                    while s.hasPrefix("#") || s.hasPrefix(" ") { s.removeFirst() }
                    return s
                } ?? ""

            return SavedHarness(
                id: uuid,
                url: url,
                createdAt: created,
                summary: firstLine,
                hasProgress: fm.fileExists(atPath: progressURL.path)
            )
        }.sorted { $0.createdAt > $1.createdAt }
    }

    nonisolated static func storageRoot(forId id: UUID) -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport
            .appendingPathComponent("com.munyamakosa.work")
            .appendingPathComponent("harnesses")
            .appendingPathComponent(id.uuidString)
    }

    // MARK: - Lifecycle

    func start() {
        guard phase == .idle else { return }
        guard prepareStorage() else {
            // Without storageRoot, every downstream write is a silent try?
            // no-op — fail loudly up front instead of running the whole
            // harness in-memory with nothing persisted and no user signal.
            phase = .failed(reason: "couldn't create harness storage directory — check disk space/permissions")
            return
        }
        phase = .planning

        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.runPlanPhase()
            guard self.phase != .stopped else { return }

            for n in 1...self.config.maxIterations {
                if Task.isCancelled || self.phase == .stopped { return }
                self.phase = .working(iteration: n)
                self.iterations.append(HarnessIteration(number: n))
                await self.runWorkPhase(n: n)
                if Task.isCancelled || self.phase == .stopped { return }

                self.phase = .reviewing(iteration: n)
                let passed = await self.runReviewPhase(n: n)
                if Task.isCancelled || self.phase == .stopped { return }

                if passed {
                    self.phase = .completed
                    return
                }
                if n == self.config.maxIterations {
                    self.phase = .failed(reason: "iteration cap reached without pass")
                    return
                }
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        // Only downgrade an in-flight phase to .stopped — a terminal phase
        // reached just before cancellation raced in must survive (mirrors
        // LoopOrchestrator.stop()). The old `phase != .completed` guard was
        // inverted: when phase *was* .completed the guard was false, so the
        // else branch ran and clobbered it to .stopped.
        if case .completed = phase {} else if case .failed = phase {} else {
            phase = .stopped
        }
    }

    // MARK: - Phases

    private func runPlanPhase() async {
        let prompt = """
        You are planning autonomous work on the project at \(cwd.path).

        Goal:
        \(config.goal)

        Write a Markdown plan with concrete, ordered steps. Each step should be one bullet, naming files / commands / outcomes. End with a 'Definition of done' section that the work phase can self-check against. No prose preamble — start with the heading.
        """

        let result = await runOneShot(prompt: prompt, skipPermissions: false)
        plan = result
        do {
            try plan.write(to: planURL, atomically: true, encoding: .utf8)
        } catch {
            // plan.md not persisted — the harness keeps running from the
            // in-memory `plan`, but resume/inspect from disk will be stale.
            log.error("failed to write plan.md: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func runWorkPhase(n: Int) async {
        let priorProgress = progress.isEmpty ? "(none yet)" : progress
        let prompt = """
        You are executing iteration \(n) of an autonomous harness on the project at \(cwd.path).

        Goal:
        \(config.goal)

        Plan (do not deviate; pick up where progress.md left off):
        \(plan)

        Progress so far:
        \(priorProgress)

        Do the next chunk of work. Make file edits, run commands, do whatever the plan calls for. When you're done with this iteration, output a 'Progress update' Markdown section describing exactly what changed in this iteration — files touched, commands run, what's now true. Be terse, factual, and append-friendly (it will be concatenated into progress.md).
        """

        let result = await runOneShot(prompt: prompt, skipPermissions: config.skipPermissions)

        // Update in-memory + disk
        let appended = progress.isEmpty
            ? result
            : "\(progress)\n\n---\n\n\(result)"
        progress = appended
        do {
            try progress.write(to: progressURL, atomically: true, encoding: .utf8)
        } catch {
            // progress.md not persisted — a crash/quit mid-harness loses the
            // resumable trail even though this iteration's in-memory state
            // (and the review that follows) is still correct.
            log.error("failed to write progress.md: \(error.localizedDescription, privacy: .public)")
        }

        if let idx = iterations.firstIndex(where: { $0.number == n }) {
            iterations[idx].workSummary = result.prefix(800).description
        }
    }

    private func runReviewPhase(n: Int) async -> Bool {
        let prompt = """
        You are reviewing iteration \(n) of an autonomous harness.

        Original goal:
        \(config.goal)

        Plan:
        \(plan)

        Cumulative progress.md so far:
        \(progress)

        Has the goal been fully met by the current progress? Respond with the FIRST LINE being exactly one of:
          PASS
          FAIL: <one-line critique pointing at what's missing>
        Optionally include a short paragraph of reasoning below.
        """

        let raw = await runOneShot(prompt: prompt, skipPermissions: false)
        do {
            try raw.write(to: reviewURL(n), atomically: true, encoding: .utf8)
        } catch {
            // reviews/<n>.md not persisted — verdict parsing below still
            // works from `raw` in-memory, but the per-iteration audit trail
            // on disk is missing this entry.
            log.error("failed to write review \(n): \(error.localizedDescription, privacy: .public)")
        }

        let verdict = parseVerdict(raw: raw)
        if let idx = iterations.firstIndex(where: { $0.number == n }) {
            iterations[idx].reviewVerdict = verdict.summary
            iterations[idx].passed = verdict.isPass
        }
        return verdict.isPass
    }

    // MARK: - Helpers

    /// Returns false if either directory failed to create. Callers must not
    /// proceed into phases that assume `storageRoot` exists — the plan/
    /// progress/review writes below are all try? and would otherwise fail
    /// silently, one file at a time, with no single place to catch it.
    private func prepareStorage() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: storageRoot, withIntermediateDirectories: true)
            try fm.createDirectory(
                at: storageRoot.appendingPathComponent("reviews"),
                withIntermediateDirectories: true
            )
            return true
        } catch {
            log.error("prepareStorage failed at \(self.storageRoot.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Spawn `claude -p` with the prompt, capture stdout text. Returns ""
    /// on spawn failure or cancellation — phases tolerate empty output
    /// (no progress, next iteration's review will likely fail).
    ///
    /// Goes through V2Subprocess so:
    ///   • stderr is drained concurrently (no pipe-buffer deadlock)
    ///   • Task cancellation (`currentTask?.cancel()` from stop()) actually
    ///     terminates the child process instead of leaving it orphaned.
    private func runOneShot(prompt: String, skipPermissions: Bool) async -> String {
        var args = ["-p", prompt, "--output-format", "text"]
        if skipPermissions {
            args.append("--dangerously-skip-permissions")
        }
        return await V2Subprocess.runCollectingStdout(
            executable: claudeURL,
            args: args,
            cwd: cwd
        )
    }

    nonisolated static func parseVerdict(raw: String) -> (isPass: Bool, summary: String) {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased()

        if upper.hasPrefix("PASS") {
            let after = normalized
                .dropFirst(4)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":—-– .").union(.whitespaces))
            return (true, after.isEmpty ? "passed" : String(after))
        }
        if upper.hasPrefix("FAIL") {
            let after = normalized
                .dropFirst(4)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":—-– .").union(.whitespaces))
            return (false, after.isEmpty ? "no reason given" : String(after))
        }
        return (false, "review didn't start with PASS or FAIL: \(normalized.prefix(160))")
    }

    private func parseVerdict(raw: String) -> (isPass: Bool, summary: String) {
        HarnessOrchestrator.parseVerdict(raw: raw)
    }
}
