// LoopOrchestrator — the engine behind v2's hero "loops" feature (#24).
//
// One instance per running loop. Drives a doer StreamSession in tight cycles:
//
//   1. send goal as a user turn
//   2. wait for the doer's `result` event
//   3. run a one-shot verifier (claude -p) on the doer's output
//   4. if PASS → stop, mark .passed
//   5. if FAIL + budget remaining → feed the verifier's critique back to the
//      doer as the next user turn, increment turn count, repeat
//   6. if budget exhausted → stop, mark .budgetExhausted
//
// The doer is a long-lived StreamSession (persistent stdin). The verifier is
// a per-cycle one-shot claude process — simpler than maintaining a second
// long-lived session, and `claude -p` exits after one turn so no cleanup.

import Foundation
import Combine
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "loop")

// MARK: - Config + state

struct LoopConfig: Equatable {
    var goal: String
    /// Verifier prompt. The doer's text result is appended below.
    var verifierPrompt: String
    /// Maximum doer-verifier round-trips.
    var maxTurns: Int

    static let testsPassPreset = LoopConfig(
        goal: "",
        verifierPrompt: "You are a strict reviewer. Read the agent's output below and decide if the task is fully done. Respond with the FIRST LINE being exactly one of:\n  PASS\n  FAIL: <one-line critique>\nThen optionally a short paragraph of reasoning.",
        maxTurns: 10
    )
}

struct LoopTurn: Identifiable {
    let id = UUID()
    let number: Int
    var title: String
    var state: TurnState

    enum TurnState: Equatable {
        case running
        case pass(summary: String)
        case fail(summary: String)
    }
}

// MARK: - Orchestrator

@MainActor
final class LoopOrchestrator: ObservableObject {

    enum LifecycleState: Equatable {
        case idle
        case running(turn: Int)
        case verifying(turn: Int)
        case passed
        case failed(reason: String)
        case budgetExhausted
        case stopped
    }

    @Published private(set) var state: LifecycleState = .idle
    @Published private(set) var turns: [LoopTurn] = []
    let config: LoopConfig

    private let doer: StreamSession
    private let cwd: URL
    private let claudeURL: URL

    private var resultObserver: AnyCancellable?
    private var currentTurn: Int = 0
    private var verifierTask: Task<Void, Never>?

    // MARK: - Init

    init(config: LoopConfig, doer: StreamSession, cwd: URL, claudeURL: URL) {
        self.config = config
        self.doer = doer
        self.cwd = cwd
        self.claudeURL = claudeURL
    }

    // MARK: - Lifecycle

    func start() {
        guard state == .idle else { return }
        currentTurn = 1
        state = .running(turn: currentTurn)
        turns = [LoopTurn(number: 1, title: "kicking off goal", state: .running)]

        if doer.state == .idle {
            doer.start(cwd: cwd, claudeURL: claudeURL)
        }

        // React to each doer `result` event by kicking off verification.
        // The doer publishes latestResult on its own ObservableObject; we
        // observe it via Combine to avoid threading the events through
        // another channel.
        resultObserver = doer.$latestResult
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] result in
                self?.handleDoerResult(result)
            }

        doer.send(text: config.goal)
    }

    func stop() {
        verifierTask?.cancel()
        resultObserver?.cancel()
        resultObserver = nil
        doer.stop()
        if case .running = state { state = .stopped }
        else if case .verifying = state { state = .stopped }
        else if state == .idle { state = .stopped }
    }

    // MARK: - Doer → verifier flow

    private func handleDoerResult(_ result: ResultEvent) {
        guard case .running(let turn) = state else { return }
        guard turn == currentTurn else { return }

        state = .verifying(turn: turn)
        if let idx = turns.lastIndex(where: { $0.number == turn }) {
            turns[idx].title = "waiting on verifier"
        }

        verifierTask = Task { [weak self] in
            guard let self else { return }
            let doerText = result.result ?? ""
            let verdict = await Self.runOneShotVerifier(
                prompt: self.config.verifierPrompt,
                doerOutput: doerText,
                claudeURL: self.claudeURL,
                cwd: self.cwd
            )
            await self.applyVerdict(verdict)
        }
    }

    private func applyVerdict(_ verdict: Verdict) {
        guard case .verifying(let turn) = state else { return }
        guard turn == currentTurn else { return }

        // Update the current turn row with the verdict.
        if let idx = turns.lastIndex(where: { $0.number == turn }) {
            turns[idx].title = verdict.isPass
                ? "verifier passed"
                : "verifier failed — \(verdict.summary)"
            turns[idx].state = verdict.isPass
                ? .pass(summary: verdict.summary)
                : .fail(summary: verdict.summary)
        }

        if verdict.isPass {
            state = .passed
            doer.stop()
            resultObserver?.cancel()
            return
        }

        if currentTurn >= config.maxTurns {
            state = .budgetExhausted
            doer.stop()
            resultObserver?.cancel()
            return
        }

        // Roll into the next iteration. Feed the verifier's critique to the
        // doer as the next user turn.
        currentTurn += 1
        state = .running(turn: currentTurn)
        turns.append(LoopTurn(
            number: currentTurn,
            title: "addressing critique",
            state: .running
        ))
        doer.send(text: "The verifier rejected the previous attempt:\n\(verdict.summary)\n\nPlease address that and try again.")
    }

    // MARK: - One-shot verifier (claude -p)

    struct Verdict: Sendable {
        let isPass: Bool
        let summary: String
    }

    nonisolated static func runOneShotVerifier(
        prompt: String,
        doerOutput: String,
        claudeURL: URL,
        cwd: URL
    ) async -> Verdict {
        let combined = """
        \(prompt)

        ---
        Agent output to evaluate:
        \(doerOutput.isEmpty ? "(no text result returned)" : doerOutput)
        ---
        """

        // Goes through V2Subprocess which drains both pipes concurrently
        // (no stderr-buffer deadlock) and terminates the child on outer
        // Task cancel (no orphaned claude processes when the user clicks
        // Stop while the verifier is running).
        let raw = await V2Subprocess.runCollectingStdout(
            executable: claudeURL,
            args: ["-p", combined, "--output-format", "text"],
            cwd: cwd
        )
        if raw.isEmpty {
            return Verdict(isPass: false, summary: "verifier produced no output (spawn failed or cancelled)")
        }
        return parseVerdict(raw: raw)
    }

    /// Parse PASS / FAIL: <reason> from the verifier's first non-empty line.
    /// Lenient — case-insensitive, accepts trailing punctuation.
    nonisolated static func parseVerdict(raw: String) -> Verdict {
        let firstLine = raw
            .split(whereSeparator: \.isNewline)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map(String.init) ?? ""
        let normalized = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = normalized.uppercased()

        if upper.hasPrefix("PASS") {
            // Trailing reason if present (e.g. "PASS: looks great" or "PASS — ok")
            let after = normalized.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: ":—-– .").union(.whitespaces))
            return Verdict(isPass: true, summary: after.isEmpty ? "passed" : String(after))
        }
        if upper.hasPrefix("FAIL") {
            let after = normalized.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: ":—-– .").union(.whitespaces))
            return Verdict(isPass: false, summary: after.isEmpty ? "no reason given" : String(after))
        }
        // Default to fail when the verifier didn't follow the format — safer
        // than auto-passing on ambiguous output.
        return Verdict(isPass: false, summary: "verifier output didn't start with PASS or FAIL: \(normalized.prefix(160))")
    }
}
