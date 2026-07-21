// Reads a Codex thread's history WITHOUT loading the thread or spending a
// model turn, so restored tabs can show their conversation while costing
// zero running agents.
//
// Verified live against codex-cli 0.144.4 (2026-07-19): `thread/read` with
// `includeTurns: true` returns the thread with every turn and ThreadItem
// populated from rollout history, and the returned thread's status is
// `notLoaded` — the thread is NOT started, no turn is created, and the only
// notification the server emits is `remoteControl/status/changed`. A
// 27-turn / 610-item thread came back complete with `itemsView: "full"` on
// every turn.
//
// This deliberately does NOT parse ~/.codex/sessions/*.jsonl directly. That
// format is internal and hostile to outside readers: subagent sessions are
// inlined into the parent's rollout, a resumed thread appends a fresh
// session_meta on every resume (one real file carried 21 of them for a
// single thread), and the records carry developer/system prompt text with no
// per-record thread attribution. The app-server already does that parsing
// correctly and hands back the same ThreadItem shapes the live path uses —
// so history and live rendering cannot drift apart.
//
// One process serves every restore. CodexSession spawns an app-server per
// session, so restoring N tabs through those would mean N processes; the
// whole point of hibernation is that a restored tab costs none.

import Foundation
import OSLog

@MainActor
final class CodexHistoryReader {
    static let shared = CodexHistoryReader()
    private init() {}

    private let log = Logger(subsystem: "com.munyamakosa.work", category: "codex-history")

    /// How long the shared app-server lingers after the last read. Launch
    /// restore reads several threads in a burst; keeping the process for a
    /// short tail means that burst pays one spawn, not one per tab.
    static let idleShutdownSeconds: TimeInterval = 20

    private var client: CodexAppServerClient?
    private var startTask: Task<CodexAppServerClient?, Never>?
    private var idleShutdown: Task<Void, Never>?
    private var inFlight = 0
    /// The codex binary this machine resolved, remembered so callers deep
    /// in the view tree (the sub-agent peek) can read a thread without
    /// plumbing a URL through every view between them and app state.
    private var rememberedBinary: URL?
    /// Which binary the live `client` was actually spawned from — not the
    /// same thing as the most recent caller's binary.
    private var startedBinary: URL?

    func rememberBinary(_ url: URL) { rememberedBinary = url }

    /// Read using the remembered binary. Returns nil if nothing has
    /// established one yet — the caller shows its empty state rather than
    /// guessing at a path.
    func read(threadId: String) async -> [String: Any]? {
        guard let binary = rememberedBinary else { return nil }
        return await read(threadId: threadId, binary: binary)
    }

    /// The thread's app-server representation (`turns` → `items`), or nil if
    /// the read failed. Callers map it with `CodexSession.transcript(from:)`
    /// — the identical mapping `thread/resume` results go through.
    func read(threadId: String, binary: URL) async -> [String: Any]? {
        rememberedBinary = binary
        guard let client = await ensureClient(binary: binary) else { return nil }
        inFlight += 1
        idleShutdown?.cancel()
        defer {
            inFlight -= 1
            scheduleIdleShutdown()
        }
        do {
            let response = try await client.request("thread/read", params: [
                "threadId": threadId,
                "includeTurns": true
            ])
            return response["thread"] as? [String: Any]
        } catch {
            log.error("thread/read failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Concurrent restores must share ONE spawn. Without coalescing, five
    /// tabs restoring at launch would each race to start their own
    /// app-server and four would be orphaned.
    private func ensureClient(binary: URL) async -> CodexAppServerClient? {
        // A live client from a DIFFERENT binary must not be reused: two
        // projects can resolve different codex versions (a global install
        // and a project-local one), and answering a thread written by the
        // newer one with the older one silently yields items it doesn't
        // understand — which map to nothing, so a peek shows an empty
        // thread rather than an error.
        if let client, startedBinary == binary { return client }
        if client != nil, startedBinary != binary { shutdownIfIdle() }
        if let startTask { return await startTask.value }

        let task = Task<CodexAppServerClient?, Never> { [weak self] in
            let candidate = CodexAppServerClient(binary: binary)
            candidate.onTermination = { [weak self] reason in
                Task { @MainActor in self?.handleTermination(reason) }
            }
            do {
                try await candidate.start()
            } catch {
                await self?.logStartFailure(error)
                return nil
            }
            return candidate
        }
        startTask = task
        let started = await task.value
        startedBinary = started == nil ? nil : binary
        // No suspension between here and the return, so a second caller
        // arriving now sees either the in-flight task or the settled client
        // — never a window where both are nil.
        startTask = nil
        client = started
        return started
    }

    private func logStartFailure(_ error: Error) {
        log.error("codex app-server (history reader) failed to start: \(error.localizedDescription, privacy: .public)")
    }

    /// The process died on its own (crash, user killed it). Drop the handle
    /// so the next read spawns a fresh one instead of writing into a pipe
    /// with nothing on the other end.
    private func handleTermination(_ reason: String) {
        log.notice("codex app-server (history reader) ended: \(reason, privacy: .public)")
        client = nil
    }

    private func scheduleIdleShutdown() {
        guard inFlight == 0 else { return }
        idleShutdown?.cancel()
        idleShutdown = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.idleShutdownSeconds))
            guard !Task.isCancelled else { return }
            self?.shutdownIfIdle()
        }
    }

    private func shutdownIfIdle() {
        guard inFlight == 0, let client else { return }
        // Clear the handler first: this teardown is deliberate, and
        // handleTermination would otherwise log it as an unexpected death.
        client.onTermination = nil
        client.stop()
        self.client = nil
    }

    /// App termination — the async idle path may never get another run-loop
    /// turn, so tear the process down synchronously.
    func terminateNow() {
        idleShutdown?.cancel()
        startTask?.cancel()
        client?.onTermination = nil
        client?.terminateNow()
        client = nil
    }
}
