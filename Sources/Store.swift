import Foundation
import Combine
import AppKit

@MainActor
final class Store: ObservableObject {

    @Published var projects: [Project] = []
    @Published var selectedProject: Project?
    @Published var selectedSessionForViewing: Session?
    @Published var isLoading = false

    /// User-supplied display names for projects, keyed by cwd. Re-applied on
    /// every `load()` so a custom name survives the 30s reload that rebuilds
    /// projects from disk (where displayName is derived from the path).
    @Published var projectNameOverrides: [String: String] = [:]

    /// In-flight guards for the per-row lazy reads so fast scrolling (or a
    /// reload that just cleared firstPrompt/slug) doesn't issue duplicate
    /// 300KB/4KB head reads for the same session before the first completes.
    private var pendingFirstPromptLoads: Set<String> = []
    private var pendingSlugLoads: Set<String> = []

    // Extensions data (global)
    @Published var plugins: [ClaudePlugin] = []
    @Published var standaloneSkills: [ClaudeSkill] = []
    @Published var standaloneMCPs: [MCPServer] = []
    @Published var hooks: [ClaudeHook] = []
    @Published var pluginSkills: [String: [ClaudeSkill]] = [:]   // pluginId -> skills
    @Published var pluginMCPs: [String: [MCPServer]] = [:]       // pluginId -> mcps

    // Per-project extensions (keyed by project cwd)
    @Published var projectMCPs: [String: [MCPServer]] = [:]
    @Published var projectSkills: [String: [ClaudeSkill]] = [:]

    /// Per-project, user-private MCPs from `~/.claude.json` →
    /// `projects.<cwd>.mcpServers`. These are the "local" scope in
    /// Claude Code's three-scope model — only load in the named project,
    /// only visible to this user. Keyed by project cwd.
    @Published var localUserMCPs: [String: [MCPServer]] = [:]

    // MCP runtime statuses (keyed by MCPServer.statusKey)
    @Published var mcpStatuses: [String: MCPStatus] = [:]

    // Token usage aggregated across all sessions
    @Published var usageTotals: UsageTotals = UsageTotals()
    /// True while `UsageAggregator.aggregate()` is running. Used by UsageView
    /// to show a skeleton instead of a misleading row of zeros.
    @Published var isLoadingUsage = false

    // Per-session overrides (aliases + hidden). Loaded once at startup,
    // republished whenever a mutation happens so SwiftUI rows refresh.
    @Published var sessionPrefs: SessionPreferencesData = .empty

    private let prefsStore = SessionPreferencesStore()

    // Perf: track whether extensions have been loaded at least once
    private var extensionsLoaded = false
    private var prefsLoaded = false

    // Pending renames: when a user types a name at launch, we store it here
    // until a new session appears with a matching cwd — then we apply the alias.
    private struct PendingRename {
        let cwd: String
        let name: String
        let queuedAt: Date
    }
    private var pendingRenames: [PendingRename] = []
    private var knownSessionIds: Set<String> = []

    private let claudeDir: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude")

    // BUG-7 fix: guard flag so startWatching() is idempotent
    private var isWatching = false

    // nonisolated(unsafe) because DispatchSource/Timer are not Sendable in strict mode,
    // but we only ever touch them from the main thread.
    nonisolated(unsafe) private var sessionsWatcher: (any DispatchSourceFileSystemObject)?
    nonisolated(unsafe) private var historyWatcher: (any DispatchSourceFileSystemObject)?
    nonisolated(unsafe) private var refreshTimer: Timer?
    nonisolated(unsafe) private var appActiveObserver: Any?

    /// Incremented on every `load()` start; the fire-and-forget aggregate Task
    /// compares its captured value against this before publishing its result,
    /// so a slow-finishing aggregate from an older load can't overwrite the
    /// newer one's totals.
    private var loadGeneration: Int = 0

    /// Timestamp of the last `isLoading = true` flip. The 30s refresh timer
    /// uses this to force-release a wedged load (if one happens) rather than
    /// silently drifting forever.
    private var loadStartedAt: Date?

    // Store is conceptually app-lifetime but we still tear the watchers down
    // on deinit so tests / preview contexts don't leak FDs + observers.
    deinit {
        sessionsWatcher?.cancel()
        historyWatcher?.cancel()
        refreshTimer?.invalidate()
        if let token = appActiveObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Full reload

    /// Register a directory as a Claude project. Idempotent — no-op if the
    /// path is already tracked. Inserts at the top of the sidebar, marks it
    /// `selectedProject` so the load() merge logic preserves it, and writes
    /// to `~/.claude.json` so the project sticks across app restarts even
    /// before Claude writes any JSONL for it. Used by both v1's AddProjectSheet
    /// and v2's left rail.
    @MainActor
    func registerProject(at path: String) -> Project? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        if let existing = projects.first(where: { $0.cwd == path }) {
            selectedProject = existing
            persistProjectRegistration(path: path)
            return existing
        }

        let displayName = (path as NSString).lastPathComponent
        let project = Project(
            id: path,
            cwd: path,
            displayName: displayName,
            sessions: [],
            isActive: false
        )
        projects.insert(project, at: 0)
        selectedProject = project
        persistProjectRegistration(path: path)
        return project
    }

    /// Record a user-supplied display name for a project and apply it now so
    /// the rail and home update immediately. The override is re-applied on
    /// every `load()` so it isn't lost when projects are rebuilt from disk.
    /// Passing an empty name clears any existing override.
    func setProjectName(_ name: String, for cwd: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            projectNameOverrides[cwd] = nil
        } else {
            projectNameOverrides[cwd] = trimmed
            if let pi = projects.firstIndex(where: { $0.cwd == cwd }) {
                projects[pi].displayName = trimmed
                if selectedProject?.cwd == cwd { selectedProject = projects[pi] }
            }
        }
    }

    /// Append the project path to `~/.claude.json` `projects` map with
    /// sensible defaults so Claude treats it as a known cwd next launch.
    private func persistProjectRegistration(path: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        var projectsMap = (root["projects"] as? [String: Any]) ?? [:]
        if projectsMap[path] == nil {
            projectsMap[path] = [
                "allowedTools": [],
                "hasTrustDialogAccepted": true
            ] as [String: Any]
            root["projects"] = projectsMap
            if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
                try? out.write(to: url, options: .atomic)
            }
        }
    }

    func load() async {
        // Prevent concurrent loads stomping each other's isLoading flag. If a
        // previous load has been wedged for >30s (e.g. hung file read), clear
        // the flag so we can recover rather than drifting with stale data.
        if isLoading {
            if let started = loadStartedAt, Date().timeIntervalSince(started) > 30 {
                isLoading = false
            } else {
                return
            }
        }
        isLoading = true
        loadStartedAt = Date()
        loadGeneration &+= 1
        let myGeneration = loadGeneration
        let dir = claudeDir
        let built = await Task.detached(priority: .userInitiated) {
            let active = Self.readActiveSessions(claudeDir: dir)
            let entries = Self.readHistory(claudeDir: dir)
            let knownPaths = Self.readKnownProjectPaths()
            return Self.buildProjects(from: entries, active: active, knownPaths: knownPaths)
        }.value
        let prevSelected = selectedProject
        let prevProjects = projects
        var merged = built

        // Preserve lazily-loaded firstPrompt/slug across reloads. buildProjects
        // rebuilds Sessions from disk with these fields nil; without this, every
        // 30s reload would blank project-home titles back to their fallbacks
        // until each row re-appears and re-reads its JSONL head.
        var priorLazyFields: [String: (firstPrompt: String?, slug: String?)] = [:]
        for project in prevProjects {
            for s in project.sessions where s.firstPrompt != nil || s.slug != nil {
                priorLazyFields[s.id] = (s.firstPrompt, s.slug)
            }
        }
        if !priorLazyFields.isEmpty {
            for pi in merged.indices {
                for si in merged[pi].sessions.indices {
                    guard let prior = priorLazyFields[merged[pi].sessions[si].id] else { continue }
                    if merged[pi].sessions[si].firstPrompt == nil {
                        merged[pi].sessions[si].firstPrompt = prior.firstPrompt
                    }
                    if merged[pi].sessions[si].slug == nil {
                        merged[pi].sessions[si].slug = prior.slug
                    }
                }
            }
        }

        // Re-apply user-set project name overrides (path-derived displayName
        // would otherwise clobber them on every reload).
        if !projectNameOverrides.isEmpty {
            for pi in merged.indices {
                if let name = projectNameOverrides[merged[pi].cwd], !name.isEmpty {
                    merged[pi].displayName = name
                }
            }
        }
        // Preserve an ephemeral project (one the user just opened via
        // "Open directory…" that hasn't had a Claude JSONL written for it
        // yet, so it wouldn't show up in `built`). Write a fresh empty-shell
        // copy rather than the cached `prev` — its `.sessions` array may be
        // stale (e.g. JSONLs deleted since last load).
        if let prev = prevSelected,
           !merged.contains(where: { $0.id == prev.id }) {
            let emptyShell = Project(
                id: prev.id,
                cwd: prev.cwd,
                displayName: prev.displayName,
                sessions: [],
                isActive: false
            )
            merged.insert(emptyShell, at: 0)
        }
        projects = merged
        if let id = prevSelected?.id {
            selectedProject = merged.first { $0.id == id }
        }
        isLoading = false
        loadStartedAt = nil

        // Perf #6: only load extensions on first call or explicit refresh, not every 30s
        if !extensionsLoaded {
            await loadExtensions()
            extensionsLoaded = true
        }

        // Token usage:
        //  1. Snap in cached totals from disk so the UI fills instantly.
        //  2. Kick off a fresh aggregation in the background. Only files
        //     whose mtime changed since last run get re-parsed, so the
        //     refresh is near-free unless Claude has been writing heavily.
        let cached = await UsageAggregator.cachedTotals()
        if cached.total.total > 0 {
            usageTotals = cached
            isLoadingUsage = false
            // Fire-and-forget re-aggregate. Check `loadGeneration` before
            // publishing — a later load() may have already written newer
            // totals that this stale task would clobber.
            Task { [weak self] in
                let fresh = await UsageAggregator.aggregate()
                await MainActor.run {
                    guard let self, self.loadGeneration == myGeneration else { return }
                    self.usageTotals = fresh
                }
            }
        } else {
            // First run (or cache cleared) — show skeleton while we scan.
            isLoadingUsage = true
            usageTotals = await UsageAggregator.aggregate()
            isLoadingUsage = false
        }

        // Session preferences (aliases + hidden) — load once at startup
        if !prefsLoaded {
            sessionPrefs = await prefsStore.load()
            prefsLoaded = true
        }

        // Apply any pending renames to sessions that appeared since the last load
        await applyPendingRenames()
    }

    // MARK: - Pending rename (applied when new session is detected)

    /// Queue a name to apply to the next new session that appears in this project cwd.
    /// Expires after 5 minutes to avoid accidentally renaming a different future session.
    func queuePendingRename(_ name: String, for cwd: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Expire old pending renames (>5 min)
        pendingRenames.removeAll { Date().timeIntervalSince($0.queuedAt) > 300 }
        // Remove any prior pending for this cwd (last-write-wins)
        pendingRenames.removeAll { $0.cwd == cwd }
        pendingRenames.append(PendingRename(cwd: cwd, name: trimmed, queuedAt: Date()))
    }

    /// Called after each load to apply any pending renames to freshly-appeared sessions.
    private func applyPendingRenames() async {
        guard !pendingRenames.isEmpty else {
            // Still track known IDs so we don't misfire on a future queue
            knownSessionIds = Set(projects.flatMap { $0.sessions.map(\.id) })
            return
        }

        // Build current set of session IDs; detect new ones
        let allSessions = projects.flatMap { project in
            project.sessions.map { ($0, project) }
        }
        let currentIds = Set(allSessions.map { $0.0.id })
        let newIds = currentIds.subtracting(knownSessionIds)

        // On first load, treat everything as "already known" — don't retroactively rename
        if knownSessionIds.isEmpty {
            knownSessionIds = currentIds
            return
        }

        // Expire stale pending entries before matching
        pendingRenames.removeAll { Date().timeIntervalSince($0.queuedAt) > 300 }

        for newId in newIds {
            guard let (session, project) = allSessions.first(where: { $0.0.id == newId }) else { continue }
            // Match the oldest (first-queued) pending rename with this cwd
            guard let pendingIdx = pendingRenames.firstIndex(where: { $0.cwd == project.cwd }) else { continue }
            let pending = pendingRenames[pendingIdx]
            pendingRenames.remove(at: pendingIdx)
            await setAlias(pending.name, for: session)
        }

        knownSessionIds = currentIds
    }

    // MARK: - Session display + preferences

    /// The name to show for a session: user alias > Claude slug > UUID prefix.
    func displayName(for session: Session) -> String {
        if let alias = sessionPrefs.alias(for: session.id) { return alias }
        if let slug = session.slug, !slug.isEmpty { return slug }
        return String(session.id.prefix(8))
    }

    func hasAlias(_ session: Session) -> Bool {
        sessionPrefs.alias(for: session.id) != nil
    }

    func isHidden(_ session: Session) -> Bool {
        sessionPrefs.isHidden(session.id)
    }

    func setAlias(_ alias: String, for session: Session) async {
        // 1. Set local alias immediately so the UI updates without waiting.
        sessionPrefs = await prefsStore.setAlias(alias, for: session.id)

        // 2. Propagate to Claude itself via `claude --resume <id> --name <name>`.
        //    Writes a customTitle line into the JSONL so `claude --resume`
        //    picker (and any other Claude consumer) sees the new name too.
        do {
            try await ClaudeRenamer.renameSession(
                id: session.id,
                in: session.projectCwd,
                to: alias
            )
            // 3. Re-read the JSONL tail so Work picks up the new customTitle.
            await refreshSlug(for: session)
        } catch {
            // Local alias still applies — Claude propagation just didn't land.
            // We don't surface this; the user sees the rename in Work either way.
            #if DEBUG
            print("ClaudeRenamer failed: \(error)")
            #endif
        }
    }

    func clearAlias(for session: Session) async {
        sessionPrefs = await prefsStore.clearAlias(for: session.id)
    }

    func setHidden(_ hidden: Bool, for session: Session) async {
        sessionPrefs = await prefsStore.setHidden(hidden, for: session.id)
    }

    // MARK: - Global "Continue most recent"

    /// Returns the most recently-active visible session globally, or nil if none.
    /// Projects are already sorted by most-recent-session descending, so we walk
    /// them in order and return the first non-hidden session we see.
    func mostRecentSession() -> (session: Session, project: Project)? {
        for project in projects {
            if let s = project.sessions.first(where: { !isHidden($0) }) {
                return (s, project)
            }
        }
        return nil
    }

    /// All visible sessions across all projects, paired with their owning project,
    /// sorted by lastActivity desc. Used by the ⌘K search.
    func allSessionsWithProjects(includeHidden: Bool = false) -> [(session: Session, project: Project)] {
        var out: [(Session, Project)] = []
        for project in projects {
            for session in project.sessions where includeHidden || !isHidden(session) {
                out.append((session, project))
            }
        }
        out.sort { $0.0.lastActivity > $1.0.lastActivity }
        return out
    }

    // MARK: - Lazy slug loading (called per session row as it appears)

    func loadSlug(for session: Session) async {
        guard session.slug == nil else { return }
        guard !pendingSlugLoads.contains(session.id) else { return }
        pendingSlugLoads.insert(session.id)
        defer { pendingSlugLoads.remove(session.id) }
        await refreshSlug(for: session)
    }

    /// Force a re-read of the session's slug from the JSONL tail. Used after
    /// renaming via `claude --name` so the new customTitle replaces any old slug.
    func refreshSlug(for session: Session) async {
        let dir = claudeDir
        let sessionId = session.id
        let cwd = session.projectCwd

        let slug = await Task.detached(priority: .background) { () -> String? in
            // This encoding must match what Claude writes on disk — it always uses / → -
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonlURL = dir
                .appendingPathComponent("projects")
                .appendingPathComponent(encoded)
                .appendingPathComponent(sessionId + ".jsonl")
            return Self.readSlugFromTail(at: jsonlURL)
        }.value

        guard let slug else { return }

        if let pi = projects.firstIndex(where: { $0.cwd == session.projectCwd }),
           let si = projects[pi].sessions.firstIndex(where: { $0.id == session.id }) {
            projects[pi].sessions[si].slug = slug
            if selectedProject?.cwd == session.projectCwd {
                selectedProject = projects[pi]
            }
        }
    }

    // MARK: - Lazy first-prompt loading (the "what was it about" clue)

    func loadFirstPrompt(for session: Session) async {
        guard session.firstPrompt == nil else { return }
        guard !pendingFirstPromptLoads.contains(session.id) else { return }
        pendingFirstPromptLoads.insert(session.id)
        defer { pendingFirstPromptLoads.remove(session.id) }
        let dir = claudeDir
        let sessionId = session.id
        let cwd = session.projectCwd

        let prompt = await Task.detached(priority: .background) { () -> String in
            let encoded = cwd.replacingOccurrences(of: "/", with: "-")
            let jsonlURL = dir
                .appendingPathComponent("projects")
                .appendingPathComponent(encoded)
                .appendingPathComponent(sessionId + ".jsonl")
            return Self.readFirstPromptFromHead(at: jsonlURL) ?? ""
        }.value

        if let pi = projects.firstIndex(where: { $0.cwd == session.projectCwd }),
           let si = projects[pi].sessions.firstIndex(where: { $0.id == session.id }) {
            projects[pi].sessions[si].firstPrompt = prompt   // "" = looked, found none
            if selectedProject?.cwd == session.projectCwd {
                selectedProject = projects[pi]
            }
        }
    }

    /// Scan the head of a session's JSONL for the first substantive human
    /// prompt — skipping the continuation-summary preamble, slash commands,
    /// caveats, and tool-result turns (whose content is an array, not a string).
    private nonisolated static func readFirstPromptFromHead(at url: URL) -> String? {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? fh.close() }
        // Large window so a long continuation-summary preamble (one giant
        // user line) doesn't crowd out the real first prompt that follows it.
        let data = fh.readData(ofLength: 300_000)
        // Lossy decode: a fixed-byte cut can split a multibyte sequence (emoji,
        // CJK) at the tail. `String(data:encoding:.utf8)` would return nil for
        // the WHOLE buffer in that case, blanking an otherwise-valid head. The
        // lossy decode replaces only the broken tail byte(s); the truncated
        // final line fails JSON parsing and is skipped anyway.
        let text = String(decoding: data, as: UTF8.self)

        for line in text.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? String   // string ⇒ typed by a human
            else { continue }

            let t = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.count < 8 { continue }
            if t.hasPrefix("/") { continue }                                   // slash command
            if t.hasPrefix("This session is being continued") { continue }     // compaction preamble
            if t.hasPrefix("Caveat:") { continue }
            if t.hasPrefix("<") { continue }                                   // system-reminder / tags
            let oneLine = t.replacingOccurrences(of: "\n", with: " ")
            return String(oneLine.prefix(120))
        }
        return nil
    }

    // MARK: - Active-session badge refresh

    func refreshActiveSessions() async {
        let dir = claudeDir
        let active = await Task.detached(priority: .utility) {
            Self.readActiveSessions(claudeDir: dir)
        }.value

        for pi in projects.indices {
            projects[pi].isActive = active.cwds.contains(projects[pi].cwd)
            for si in projects[pi].sessions.indices {
                projects[pi].sessions[si].isActive =
                    active.sessionIds.contains(projects[pi].sessions[si].id)
            }
        }
        if let id = selectedProject?.id {
            selectedProject = projects.first { $0.id == id }
        }
    }

    // MARK: - Watchers

    func startWatching() {
        // BUG-7/13 fix: idempotent — safe to call from .task on every scene activation
        guard !isWatching else { return }
        isWatching = true
        watchSessionsDirectory()
        watchHistoryFile()
        // Belt-and-suspenders: full reload every 30s catches anything the watchers miss
        // Perf: skip when app is backgrounded to avoid wasted CPU/battery
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard NSApplication.shared.isActive else { return }
            Task { await self?.load() }
        }
        // Refresh active badges the moment the user switches back to this app —
        // catches terminals that were closed while Work was in the background
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshActiveSessions()
                await self?.refreshMCPStatuses()
            }
        }
    }

    // Watches ~/.claude/sessions/ — fires when a new Claude process starts/stops
    // nonisolated: DispatchSource fires on a background queue; the closure must NOT
    // inherit @MainActor isolation or macOS 26 strict-concurrency runtime will trap.
    nonisolated private func watchSessionsDirectory() {
        let path = claudeDir.appendingPathComponent("sessions").path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // BUG-8 fix: log the failure instead of silently vanishing; 30s timer is the fallback
            print("[Work] Warning: could not watch sessions directory at \(path) — real-time active badges unavailable, falling back to 30s timer")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.refreshActiveSessions() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        sessionsWatcher = src
    }

    // Watches ~/.claude/history.jsonl — fires the moment any new message is sent
    // nonisolated: same reason as watchSessionsDirectory above.
    nonisolated private func watchHistoryFile() {
        let path = claudeDir.appendingPathComponent("history.jsonl").path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // BUG-8 fix: log the failure
            print("[Work] Warning: could not watch history.jsonl at \(path) — new sessions will appear after the 30s timer")
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .extend, queue: .global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.load() }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        historyWatcher = src
    }

    // MARK: - Static file-I/O helpers (nonisolated — safe for Task.detached)

    /// Stream-parse history.jsonl byte-by-byte. Previously we converted the
    /// full memory-mapped `Data` into a Swift `String` then `split` it, which
    /// allocates a UTF-8 copy of the entire file (~100MB+ for power users)
    /// before any decoding even starts. This version walks the bytes once
    /// and decodes each line directly from a `Data` slice — same pattern
    /// `UsageAggregator.parseSessionUsage` already uses successfully.
    private nonisolated static func readHistory(claudeDir: URL) -> [HistoryEntry] {
        let url = claudeDir.appendingPathComponent("history.jsonl")
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }

        let decoder = JSONDecoder()
        var entries: [HistoryEntry] = []
        entries.reserveCapacity(8_000)

        // Walk the bytes via withUnsafeBytes — no String allocation, no copy.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            let count = raw.count
            var lineStart = 0

            for i in 0..<count where base[i] == 0x0A /* '\n' */ {
                // Strip a trailing \r if the file uses CRLF (rare for JSONL).
                var lineEnd = i
                if lineEnd > lineStart && base[lineEnd - 1] == 0x0D { lineEnd -= 1 }
                if lineEnd > lineStart {
                    let lineData = Data(bytes: base.advanced(by: lineStart), count: lineEnd - lineStart)
                    if let entry = try? decoder.decode(HistoryEntry.self, from: lineData) {
                        entries.append(entry)
                    }
                }
                lineStart = i + 1
            }
            // Final line without trailing newline
            if lineStart < count {
                let lineData = Data(bytes: base.advanced(by: lineStart), count: count - lineStart)
                if let entry = try? decoder.decode(HistoryEntry.self, from: lineData) {
                    entries.append(entry)
                }
            }
        }

        return entries
    }

    private nonisolated static func readActiveSessions(
        claudeDir: URL
    ) -> (cwds: Set<String>, sessionIds: Set<String>) {
        let dir = claudeDir.appendingPathComponent("sessions")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil
        ) else { return ([], []) }

        var cwds = Set<String>()
        var sessionIds = Set<String>()
        let decoder = JSONDecoder()

        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let s = try? decoder.decode(ActiveSessionFile.self, from: data) else { continue }
            // BUG-9 fix: verify PID belongs to a claude process, not just any process
            if kill(Int32(s.pid), 0) == 0 && isClaudeProcess(pid: Int32(s.pid)) {
                cwds.insert(s.cwd)
                sessionIds.insert(s.sessionId)
            }
        }
        return (cwds, sessionIds)
    }

    // BUG-9 fix: verify the process at this PID is actually a claude binary
    private nonisolated static func isClaudeProcess(pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return false }
        // KERN_PROCARGS2 layout: [Int32 argc][null-terminated exec path][args...]
        let pathStart = MemoryLayout<Int32>.size
        // Ensure there's at least one byte for the path and the buffer is null-terminated
        guard size > pathStart + 1 else { return false }
        let execPath = buffer.withUnsafeBufferPointer { ptr in
            // Clamp to readable range to avoid reading past valid data
            let pathRegion = UnsafeBufferPointer(
                start: ptr.baseAddress!.advanced(by: pathStart),
                count: size - pathStart
            )
            // Find the first null terminator within the valid region
            let len = pathRegion.firstIndex(of: 0) ?? pathRegion.count
            return String(bytes: pathRegion.prefix(len).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
        }
        return execPath.hasSuffix("/claude") || execPath.hasSuffix("/claude-node")
    }

    /// Read the `projects` dict from `~/.claude.json` and return the set of
    /// project paths still present on disk. This is Claude Code's canonical
    /// list of "directories the user has approved" — includes projects the
    /// user opened but whose JSONL history has since been cleaned up (and
    /// therefore wouldn't show up via `readHistory` alone).
    private nonisolated static func readKnownProjectPaths() -> Set<String> {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent(".claude.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [String: Any] else {
            return []
        }
        let fm = FileManager.default
        var paths: Set<String> = []
        for key in projects.keys {
            // Only keep absolute paths. Canonicalize via `URL` standardization
            // (collapses `//`, `./`, trailing slash) so a path that appears
            // twice as `/a/b` and `/a/b/` doesn't get treated as two projects.
            // `realpath` would also resolve symlinks — we deliberately don't,
            // since following a symlink to a sensitive dir (/etc, /tmp) would
            // let a malicious ~/.claude.json surface unrelated locations.
            guard key.hasPrefix("/") else { continue }
            let canonical = URL(fileURLWithPath: key).standardizedFileURL.path
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: canonical, isDirectory: &isDir), isDir.boolValue {
                paths.insert(canonical)
            }
        }
        return paths
    }

    private nonisolated static func buildProjects(
        from entries: [HistoryEntry],
        active: (cwds: Set<String>, sessionIds: Set<String>),
        knownPaths: Set<String> = []
    ) -> [Project] {

        struct SessionAccum {
            var preview: String
            var date: Date
        }

        var projectMap: [String: (sessions: [String: SessionAccum], lastActivity: Date)] = [:]

        for entry in entries {
            let cwd = entry.project
            guard !cwd.isEmpty else { continue }
            let date = Date(timeIntervalSince1970: entry.timestamp / 1000.0)

            var proj = projectMap[cwd] ?? (sessions: [:], lastActivity: .distantPast)
            if date > proj.lastActivity { proj.lastActivity = date }

            if let sid = entry.sessionId, !sid.isEmpty {
                if var s = proj.sessions[sid] {
                    if date > s.date {
                        s.preview = String(entry.display.prefix(200))
                        s.date = date
                    }
                    proj.sessions[sid] = s
                } else {
                    proj.sessions[sid] = SessionAccum(
                        preview: String(entry.display.prefix(200)),
                        date: date
                    )
                }
            }
            projectMap[cwd] = proj
        }

        // Include projects Claude knows about (from `~/.claude.json`'s
        // `projects` dict) even if they have no JSONL history yet. Otherwise
        // a dir where the user canceled a session, or whose JSONLs were
        // cleaned up, never shows in the sidebar despite being "approved."
        for path in knownPaths where projectMap[path] == nil {
            projectMap[path] = (sessions: [:], lastActivity: .distantPast)
        }

        let allCwds = Set(projectMap.keys)
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        return projectMap.map { cwd, data in
            let sessions = data.sessions
                .map { sid, accum in
                    Session(
                        id: sid,
                        projectCwd: cwd,
                        slug: nil,
                        lastMessagePreview: accum.preview,
                        lastActivity: accum.date,
                        isActive: active.sessionIds.contains(sid)
                    )
                }
                .sorted { $0.lastActivity > $1.lastActivity }

            return Project(
                // BUG-5 fix: use the raw cwd as the stable, collision-free Project.id
                // (the old "/" → "-" encoding was not injective)
                id: cwd,
                cwd: cwd,
                displayName: Self.displayName(for: cwd, home: home, allCwds: allCwds),
                sessions: sessions,
                isActive: active.cwds.contains(cwd)
            )
        }
        .sorted {
            ($0.sessions.first?.lastActivity ?? .distantPast) >
            ($1.sessions.first?.lastActivity ?? .distantPast)
        }
    }

    // BUG-14 fix: walk the full ancestor chain, not just one level,
    // so paths nested 2+ deep inside a known project get proper disambiguation.
    private nonisolated static func displayName(
        for cwd: String,
        home: String,
        allCwds: Set<String>
    ) -> String {
        let url = URL(fileURLWithPath: cwd)
        var suffixComponents: [String] = [url.lastPathComponent]
        var ancestor = url.deletingLastPathComponent()

        // Walk up until we find a known project ancestor or reach the home dir / root
        while ancestor.path != "/" && ancestor.path != home && !ancestor.path.isEmpty {
            if allCwds.contains(ancestor.path) {
                // Show "nearestAncestorName/...relative path..."
                let ancestorName = ancestor.lastPathComponent
                let relative = suffixComponents.reversed().joined(separator: "/")
                return "\(ancestorName)/\(relative)"
            }
            suffixComponents.append(ancestor.lastPathComponent)
            ancestor = ancestor.deletingLastPathComponent()
        }

        // No known ancestor — just the last component
        return url.lastPathComponent
    }

    // Read the last 4KB of a .jsonl file and scan backwards for the session's
    // display name. Prefers `customTitle` (set by `claude --name <name>`) over
    // `slug` (the auto-generated three-word slug). Either lives on its own line.
    private nonisolated static func readSlugFromTail(at url: URL) -> String? {
        // Two-pass read: start with the last 4KB, drop the (likely partial)
        // first line. If that pass didn't find customTitle or slug, re-read
        // with a wider window so a customTitle line that happened to straddle
        // the first pass's seek boundary isn't silently lost.
        if let found = readSlugPass(at: url, tailBytes: 4096, dropFirstPartial: true) {
            return found
        }
        // Larger second pass; at 64KB we're still bounded but catch virtually
        // every realistic line length. `dropFirstPartial: false` because at
        // 64KB we're almost certainly covering the whole header too.
        return readSlugPass(at: url, tailBytes: 65_536, dropFirstPartial: false)
    }

    private nonisolated static func readSlugPass(
        at url: URL,
        tailBytes: UInt64,
        dropFirstPartial: Bool
    ) -> String? {
        guard let fh = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? fh.close() }

        let size = fh.seekToEndOfFile()
        let seekedMidFile = size > tailBytes
        fh.seek(toFileOffset: seekedMidFile ? size - tailBytes : 0)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return nil }

        var lines = text.split(separator: "\n")
        if dropFirstPartial && seekedMidFile && !lines.isEmpty {
            lines.removeFirst()
        }

        var fallbackSlug: String?
        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }
            if let title = obj["customTitle"] as? String, !title.isEmpty {
                return title
            }
            if fallbackSlug == nil, let slug = obj["slug"] as? String, !slug.isEmpty {
                fallbackSlug = slug
            }
        }
        return fallbackSlug
    }

    // MARK: - Extensions loading

    func loadExtensions() async {
        let dir = claudeDir
        let result = await Task.detached(priority: .utility) {
            Self.parseExtensions(claudeDir: dir)
        }.value

        plugins = result.plugins
        standaloneSkills = result.skills
        standaloneMCPs = result.mcps
        hooks = result.hooks
        pluginSkills = result.pluginSkills
        pluginMCPs = result.pluginMCPs
        localUserMCPs = result.localUserMCPs

        // Load per-project MCPs and skills
        let projectCwds = projects.map(\.cwd)
        let perProject = await Task.detached(priority: .utility) {
            Self.parseProjectExtensions(cwds: projectCwds)
        }.value
        projectMCPs = perProject.mcps
        projectSkills = perProject.skills
    }

    private nonisolated static func parseExtensions(claudeDir: URL) -> (
        plugins: [ClaudePlugin],
        skills: [ClaudeSkill],
        mcps: [MCPServer],
        hooks: [ClaudeHook],
        pluginSkills: [String: [ClaudeSkill]],
        pluginMCPs: [String: [MCPServer]],
        localUserMCPs: [String: [MCPServer]]
    ) {
        let settings = readJSON(at: claudeDir.appendingPathComponent("settings.json"))
        let localSettings = readJSON(at: claudeDir.appendingPathComponent("settings.local.json"))
        // ~/.claude.json is where Claude Code 2.1+ actually stores user-scope
        // MCPs. Our older settings.json read was a legacy location.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let claudeRoot = readJSON(at: home.appendingPathComponent(".claude.json"))

        let mcps = parseMCPs(from: settings, localSettings: localSettings, claudeRoot: claudeRoot)
        let hooks = parseHooks(from: settings)
        let (plugins, pluginSkills, pluginMCPs) = parsePlugins(claudeDir: claudeDir, settings: settings)
        let skills = parseStandaloneSkills(
            claudeDir: claudeDir,
            pluginSkillNames: Set(pluginSkills.values.flatMap { $0.map(\.name) })
        )
        let localUserMCPs = parseLocalUserMCPs(claudeRoot: claudeRoot)

        return (plugins, skills, mcps, hooks, pluginSkills, pluginMCPs, localUserMCPs)
    }

    /// Read `~/.claude.json` → `projects[cwd].mcpServers` for every project,
    /// returning a cwd-keyed dict. This is the "local" scope in Claude Code's
    /// three-scope model: per-project, private to the user. Skips projects
    /// that have no MCPs configured.
    private nonisolated static func parseLocalUserMCPs(claudeRoot: [String: Any]) -> [String: [MCPServer]] {
        guard let projects = claudeRoot["projects"] as? [String: [String: Any]] else {
            return [:]
        }
        var out: [String: [MCPServer]] = [:]
        for (cwd, projectEntry) in projects {
            guard let mcpDict = projectEntry["mcpServers"] as? [String: [String: Any]],
                  !mcpDict.isEmpty
            else { continue }
            let parsed = mcpDict.map { name, config in
                parseSingleMCP(name: name, config: config, source: .localUser)
            }.sorted { $0.name < $1.name }
            out[cwd] = parsed
        }
        return out
    }

    private nonisolated static func readJSON(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }

    // MARK: Parse MCPs

    private nonisolated static func parseMCPs(
        from settings: [String: Any],
        localSettings: [String: Any],
        claudeRoot: [String: Any] = [:]
    ) -> [MCPServer] {
        var servers: [MCPServer] = []

        // ~/.claude.json top-level mcpServers — the canonical user scope
        // Claude Code 2.1+ actually reads.
        if let mcpDict = claudeRoot["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in mcpDict {
                servers.append(parseSingleMCP(name: name, config: config, source: .global))
            }
        }

        // Legacy: ~/.claude/settings.json mcpServers (older versions wrote here).
        // Only add entries the newer file doesn't already contain so the UI
        // doesn't show phantom duplicates for people mid-migration.
        if let mcpDict = settings["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in mcpDict where !servers.contains(where: { $0.name == name }) {
                servers.append(parseSingleMCP(name: name, config: config, source: .global))
            }
        }

        // BUG-17 fix: local settings replace globals with the same name
        if let mcpDict = localSettings["mcpServers"] as? [String: [String: Any]] {
            for (name, config) in mcpDict {
                servers.removeAll { $0.id == name }
                servers.append(parseSingleMCP(name: name, config: config, source: .global))
            }
        }

        return servers.sorted { $0.name < $1.name }
    }

    private nonisolated static func parseSingleMCP(
        name: String,
        config: [String: Any],
        source: MCPServer.Source
    ) -> MCPServer {
        let transport: MCPServer.Transport
        if let type = config["type"] as? String {
            switch type {
            case "http", "streamable-http":
                // `streamable-http` is the MCP spec's name for this transport;
                // Claude Code accepts both and treats them identically. We
                // normalize to `.http` on read; the writer emits canonical
                // `"type": "http"` on save.
                transport = .http(url: MCPEnvExpand.expand(config["url"] as? String ?? ""))
            case "sse":
                transport = .sse(url: MCPEnvExpand.expand(config["url"] as? String ?? ""))
            case "sdk":
                transport = .sdk
            default:
                // BUG-29 fix: preserve unknown type instead of coercing to .http
                transport = .unknown(type: type)
            }
        } else if let command = config["command"] as? String {
            let rawArgs = config["args"] as? [String] ?? []
            transport = .stdio(
                command: MCPEnvExpand.expand(command),
                args: rawArgs.map(MCPEnvExpand.expand)
            )
        } else {
            transport = .sdk
        }

        // Env vars — robust parsing that handles JSONSerialization's [String: Any] results
        var env: [String: String]? = nil
        if let rawEnv = config["env"] as? [String: Any] {
            var parsed: [String: String] = [:]
            for (k, v) in rawEnv {
                if let s = v as? String {
                    parsed[k] = s
                } else {
                    // Coerce non-string values (numbers, bools) to their string form
                    parsed[k] = "\(v)"
                }
            }
            // Expand ${VAR} / ${VAR:-default} so MCP processes receive the
            // resolved values, not the literal `${API_KEY}` placeholder.
            env = parsed.isEmpty ? nil : MCPEnvExpand.expand(parsed)
        }

        // HTTP / SSE headers (post-expansion so bearer tokens reference
        // env values cleanly).
        var headers: [String: String]? = nil
        if let rawHeaders = config["headers"] as? [String: Any] {
            var parsed: [String: String] = [:]
            for (k, v) in rawHeaders {
                if let s = v as? String { parsed[k] = s }
                else                     { parsed[k] = "\(v)" }
            }
            headers = parsed.isEmpty ? nil : MCPEnvExpand.expand(parsed)
        }

        // OAuth pre-configured credentials (http/sse only on the Claude
        // side, but we don't enforce transport here — preserve whatever
        // shape the user wrote).
        var oauth: OAuthConfig? = nil
        if let rawOAuth = config["oauth"] as? [String: Any] {
            let parsed = OAuthConfig(
                clientId: (rawOAuth["clientId"] as? String).map(MCPEnvExpand.expand),
                callbackPort: rawOAuth["callbackPort"] as? Int,
                scopes: (rawOAuth["scopes"] as? String).map(MCPEnvExpand.expand),
                authServerMetadataUrl: (rawOAuth["authServerMetadataUrl"] as? String).map(MCPEnvExpand.expand)
            )
            oauth = parsed.isEmpty ? nil : parsed
        }

        // Common knobs — alwaysLoad is a bool; timeout is in milliseconds.
        let alwaysLoad = config["alwaysLoad"] as? Bool
        let timeoutMs = config["timeout"] as? Int

        return MCPServer(
            id: name,
            name: name,
            transport: transport,
            source: source,
            env: env,
            headers: headers,
            oauth: oauth,
            alwaysLoad: alwaysLoad,
            timeoutMs: timeoutMs
        )
    }

    // MARK: Parse Hooks

    private nonisolated static func parseHooks(from settings: [String: Any]) -> [ClaudeHook] {
        guard let hooksDict = settings["hooks"] as? [String: Any] else { return [] }

        var result: [ClaudeHook] = []
        let eventOrder = ["SessionStart", "UserPromptSubmit", "PreToolUse",
                          "PostToolUse", "PostToolUseFailure", "Stop", "SessionEnd"]

        for event in eventOrder {
            guard let matchers = hooksDict[event] as? [[String: Any]], !matchers.isEmpty else { continue }
            var commands: [ClaudeHook.HookCommand] = []

            for matcher in matchers {
                let matcherStr = matcher["matcher"] as? String
                if let hookList = matcher["hooks"] as? [[String: Any]] {
                    for hook in hookList {
                        if let cmd = hook["command"] as? String {
                            commands.append(ClaudeHook.HookCommand(
                                id: UUID(), command: cmd, matcher: matcherStr
                            ))
                        }
                    }
                }
            }

            if !commands.isEmpty {
                result.append(ClaudeHook(id: event, event: event, commands: commands))
            }
        }
        return result
    }

    // MARK: Parse Plugins

    private nonisolated static func parsePlugins(
        claudeDir: URL,
        settings: [String: Any]
    ) -> ([ClaudePlugin], [String: [ClaudeSkill]], [String: [MCPServer]]) {
        let enabledPlugins = settings["enabledPlugins"] as? [String: Bool] ?? [:]
        let fm = FileManager.default
        let marketplacesDir = claudeDir
            .appendingPathComponent("plugins")
            .appendingPathComponent("marketplaces")

        var plugins: [ClaudePlugin] = []
        var allPluginSkills: [String: [ClaudeSkill]] = [:]
        var allPluginMCPs: [String: [MCPServer]] = [:]

        // Scan each marketplace
        guard let marketplaces = try? fm.contentsOfDirectory(at: marketplacesDir, includingPropertiesForKeys: nil) else {
            return ([], [:], [:])
        }

        for marketplace in marketplaces {
            let marketplaceName = marketplace.lastPathComponent
            let pluginsDir = marketplace.appendingPathComponent("plugins")
            guard let pluginDirs = try? fm.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: nil) else {
                continue
            }

            for pluginDir in pluginDirs {
                let pluginName = pluginDir.lastPathComponent
                let pluginId = "\(pluginName)@\(marketplaceName)"
                let isEnabled = enabledPlugins[pluginId] ?? false

                plugins.append(ClaudePlugin(
                    id: pluginId,
                    name: pluginName,
                    marketplace: marketplaceName,
                    isEnabled: isEnabled
                ))

                var skills: [ClaudeSkill] = []

                // 1) Skills inside skills/ subdirectory (standard layout)
                let skillsDir = pluginDir.appendingPathComponent("skills")
                if let skillDirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) {
                    for skillDir in skillDirs {
                        if let skill = parseSkillDir(skillDir, source: .plugin(name: pluginName)) {
                            skills.append(skill)
                        }
                    }
                }

                // 2) Plugin-as-skill pattern: SKILL.md sits at the plugin root
                //    (e.g. claude-reflect). Treat the plugin itself as a skill.
                if fm.fileExists(atPath: pluginDir.appendingPathComponent("SKILL.md").path) {
                    if let skill = parseSkillDir(pluginDir, source: .plugin(name: pluginName)) {
                        skills.append(skill)
                    }
                }

                if !skills.isEmpty {
                    allPluginSkills[pluginId] = skills.sorted { $0.name < $1.name }
                }

                // BUG-25 fix: try both flat format and mcpServers-wrapped format
                let mcpJson = pluginDir.appendingPathComponent(".mcp.json")
                if let data = try? Data(contentsOf: mcpJson),
                   let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    var mcps: [MCPServer] = []
                    // Try wrapped format first: { "mcpServers": { ... } }
                    if let mcpDict = raw["mcpServers"] as? [String: [String: Any]] {
                        for (name, config) in mcpDict {
                            mcps.append(parseSingleMCP(name: name, config: config, source: .plugin(name: pluginName)))
                        }
                    } else {
                        // Fallback to flat format: { "name": { config } }
                        for (name, value) in raw {
                            if let config = value as? [String: Any] {
                                mcps.append(parseSingleMCP(name: name, config: config, source: .plugin(name: pluginName)))
                            }
                        }
                    }
                    if !mcps.isEmpty {
                        allPluginMCPs[pluginId] = mcps
                    }
                }
            }
        }

        plugins.sort { ($0.isEnabled ? 0 : 1, $0.name) < ($1.isEnabled ? 0 : 1, $1.name) }
        return (plugins, allPluginSkills, allPluginMCPs)
    }

    // MARK: Parse standalone skills

    private nonisolated static func parseStandaloneSkills(
        claudeDir: URL,
        pluginSkillNames: Set<String>
    ) -> [ClaudeSkill] {
        let skillsDir = claudeDir.appendingPathComponent("skills")
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) else {
            return []
        }

        var skills: [ClaudeSkill] = []
        var seenCanonicalPaths: Set<String> = []

        for entry in entries {
            // Handle .skill zip archives separately
            if entry.pathExtension == "skill" {
                if let skill = parseSkillZip(entry) {
                    if !pluginSkillNames.contains(skill.name) {
                        skills.append(skill)
                    }
                }
                continue
            }

            // Canonicalize: resolve symlinks fully so `~/.claude/skills/foo`
            // and `~/.agents/skills/foo` (same target) dedupe to one entry.
            let resolved = entry.resolvingSymlinksInPath().standardizedFileURL
            let canon = resolved.path
            if seenCanonicalPaths.contains(canon) { continue }
            seenCanonicalPaths.insert(canon)

            if let skill = parseSkillDir(resolved, source: .standalone) {
                // A plugin with the same skill name wins — personal is still kept
                // but marked so UI can surface the conflict later (precedence viewer).
                if !pluginSkillNames.contains(skill.name) {
                    skills.append(skill)
                }
            }
        }
        return skills.sorted { $0.name < $1.name }
    }

    /// Parse a `<name>.skill` zip archive. The zip contains `<name>/SKILL.md`
    /// and optionally sibling folders. We copy out into a tmp dir just long
    /// enough to read the frontmatter; the ClaudeSkill keeps the zip path
    /// as its `path` and marks `packaging: .zipArchive`.
    private nonisolated static func parseSkillZip(_ zipURL: URL) -> ClaudeSkill? {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("work-skill-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }

        try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-q", "-o", zipURL.path, "-d", tmp.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run(); proc.waitUntilExit() } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }

        // Find the first SKILL.md one level deep
        guard let contents = try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else {
            return nil
        }

        for candidate in contents {
            let skillMd = candidate.appendingPathComponent("SKILL.md")
            if fm.fileExists(atPath: skillMd.path),
               let content = try? String(contentsOf: skillMd, encoding: .utf8) {
                let meta = SkillFrontmatter.parse(content)
                let name = meta["name"] ?? zipURL.deletingPathExtension().lastPathComponent
                return ClaudeSkill(
                    id: "standalone:\(name)",
                    name: name,
                    skillDescription: meta["description"] ?? "",
                    author: meta["author"],
                    version: meta["version"],
                    source: .standalone,
                    path: zipURL,   // point at the zip so operations know where it lives
                    hasReferences: fm.fileExists(atPath: candidate.appendingPathComponent("references").path),
                    hasScripts: fm.fileExists(atPath: candidate.appendingPathComponent("scripts").path),
                    hasAssets: fm.fileExists(atPath: candidate.appendingPathComponent("assets").path),
                    whenToUse: meta["when_to_use"] ?? meta["when-to-use"],
                    allowedTools: SkillFrontmatter.parseStringList(meta["allowed-tools"] ?? ""),
                    model: meta["model"],
                    effort: meta["effort"],
                    license: meta["license"],
                    argumentHint: meta["argument-hint"],
                    disableModelInvocation: SkillFrontmatter.parseBool(meta["disable-model-invocation"], default: false),
                    userInvocable: SkillFrontmatter.parseBool(meta["user-invocable"], default: true),
                    paths: SkillFrontmatter.parseStringList(meta["paths"] ?? ""),
                    packaging: .zipArchive,
                    rawFrontmatter: meta
                )
            }
        }
        return nil
    }

    // MARK: Per-project extensions

    private nonisolated static func parseProjectExtensions(
        cwds: [String]
    ) -> (mcps: [String: [MCPServer]], skills: [String: [ClaudeSkill]]) {
        var allMCPs: [String: [MCPServer]] = [:]
        var allSkills: [String: [ClaudeSkill]] = [:]
        let fm = FileManager.default

        for cwd in cwds {
            let projectRoot = URL(fileURLWithPath: cwd)
            let claudeDir = projectRoot.appendingPathComponent(".claude")
            var mcps: [MCPServer] = []

            // BUG-18 fix: use .project source for project-level MCPs
            // 1) Project MCPs from <project-root>/.mcp.json → mcpServers
            let mcpJsonFile = projectRoot.appendingPathComponent(".mcp.json")
            if let data = try? Data(contentsOf: mcpJsonFile),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mcpDict = obj["mcpServers"] as? [String: [String: Any]] {
                for (name, config) in mcpDict {
                    mcps.append(parseSingleMCP(name: name, config: config, source: .project))
                }
            }

            // 2) Also check .claude/settings.local.json → mcpServers (less common)
            let settingsFile = claudeDir.appendingPathComponent("settings.local.json")
            if let data = try? Data(contentsOf: settingsFile),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let mcpDict = obj["mcpServers"] as? [String: [String: Any]] {
                let existingNames = Set(mcps.map(\.name))
                for (name, config) in mcpDict where !existingNames.contains(name) {
                    mcps.append(parseSingleMCP(name: name, config: config, source: .project))
                }
            }

            if !mcps.isEmpty { allMCPs[cwd] = mcps.sorted { $0.name < $1.name } }

            // 3) Project skills from .claude/skills/
            let skillsDir = claudeDir.appendingPathComponent("skills")
            if fm.fileExists(atPath: skillsDir.path),
               let dirs = try? fm.contentsOfDirectory(at: skillsDir, includingPropertiesForKeys: nil) {
                var skills: [ClaudeSkill] = []
                var seenCanonicalPaths: Set<String> = []
                for dir in dirs {
                    let resolved = dir.resolvingSymlinksInPath()
                    let canon = resolved.standardizedFileURL.path
                    if seenCanonicalPaths.contains(canon) { continue }
                    seenCanonicalPaths.insert(canon)
                    if let skill = parseSkillDir(resolved, source: .project(cwd: cwd)) {
                        skills.append(skill)
                    }
                }
                if !skills.isEmpty { allSkills[cwd] = skills.sorted { $0.name < $1.name } }
            }
        }

        return (allMCPs, allSkills)
    }

    // MARK: MCP status detection

    func refreshMCPStatuses() async {
        let allMCPs = standaloneMCPs + projectMCPs.values.flatMap { $0 }
        let dir = claudeDir
        let statuses = await Task.detached(priority: .utility) {
            Self.checkMCPStatuses(mcps: allMCPs, claudeDir: dir)
        }.value
        mcpStatuses = statuses
    }

    /// Re-read MCP configs from disk and re-check running statuses. Call after edits.
    func reloadMCPs() async {
        // Re-parse extensions from disk (picks up new/edited/deleted MCPs)
        await loadExtensions()
        // Re-scan process list to update running/configured/needsAuth status
        await refreshMCPStatuses()
    }

    private nonisolated static func checkMCPStatuses(
        mcps: [MCPServer],
        claudeDir: URL
    ) -> [String: MCPStatus] {
        // BUG-6 fix: parse ps output into per-process command lines (not one blob)
        let processLines: [String] = {
            let pipe = Pipe()
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/ps")
            proc.arguments = ["-eo", "command"]  // just command column, one per line
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.components(separatedBy: "\n")
        }()

        // 2) Read auth cache
        let authCache = readJSON(at: claudeDir.appendingPathComponent("mcp-needs-auth-cache.json"))

        // 3) Evaluate each MCP
        var statuses: [String: MCPStatus] = [:]

        for mcp in mcps {
            let key = mcp.statusKey

            // BUG-7 fix: use exact key lookup instead of substring matching
            if authCache[mcp.name] != nil {
                statuses[key] = .needsAuth
                continue
            }

            switch mcp.transport {
            case .stdio(let command, let args):
                // Match against individual process command lines. Require BOTH
                // the command basename AND at least one distinctive arg. The
                // old "OR mcp in procLine" shortcut produced false positives
                // (e.g. `ls node mcp-stuff` matching any node-based MCP).
                let commandBase = (command as NSString).lastPathComponent
                let distinctiveArgs = args.map { arg in
                    arg.replacingOccurrences(of: "@latest", with: "")
                       .replacingOccurrences(of: "-y", with: "")
                       .trimmingCharacters(in: .whitespaces)
                }.filter { $0.count > 4 }

                let isRunning = processLines.contains { procLine in
                    guard procLine.contains(commandBase) else { return false }
                    // No distinctive args: basename alone must be exact enough.
                    // With args: require at least one to appear in the procLine.
                    if distinctiveArgs.isEmpty { return true }
                    return distinctiveArgs.contains { procLine.contains($0) }
                }
                statuses[key] = isRunning ? .running : .configured

            case .http, .sse:
                statuses[key] = .configured

            case .sdk:
                statuses[key] = .running

            case .unknown:
                statuses[key] = .configured
            }
        }

        return statuses
    }

    // MARK: Parse skills

    /// Parse a directory-backed SKILL.md into a full ClaudeSkill. `idOverride`
    /// is used when the caller needs to namespace the id (e.g. "plugin:skill"
    /// or "project:<cwd>:skill") to avoid collisions across scopes.
    private nonisolated static func parseSkillDir(
        _ dir: URL,
        source: ClaudeSkill.Source,
        idOverride: String? = nil
    ) -> ClaudeSkill? {
        let fm = FileManager.default
        let skillMd = dir.appendingPathComponent("SKILL.md")
        guard fm.fileExists(atPath: skillMd.path),
              let content = try? String(contentsOf: skillMd, encoding: .utf8)
        else { return nil }

        let meta = SkillFrontmatter.parse(content)
        let name = meta["name"] ?? dir.lastPathComponent

        let hasRefs    = fm.fileExists(atPath: dir.appendingPathComponent("references").path)
        let hasScripts = fm.fileExists(atPath: dir.appendingPathComponent("scripts").path)
        let hasAssets  = fm.fileExists(atPath: dir.appendingPathComponent("assets").path)

        return ClaudeSkill(
            id: idOverride ?? idFor(source: source, name: name),
            name: name,
            skillDescription: meta["description"] ?? "",
            author: meta["author"],
            version: meta["version"],
            source: source,
            path: dir,
            hasReferences: hasRefs,
            hasScripts: hasScripts,
            hasAssets: hasAssets,
            whenToUse: meta["when_to_use"] ?? meta["when-to-use"],
            allowedTools: SkillFrontmatter.parseStringList(meta["allowed-tools"] ?? meta["allowed_tools"] ?? ""),
            model: meta["model"],
            effort: meta["effort"],
            license: meta["license"],
            argumentHint: meta["argument-hint"] ?? meta["argument_hint"],
            disableModelInvocation: SkillFrontmatter.parseBool(meta["disable-model-invocation"] ?? meta["disable_model_invocation"], default: false),
            userInvocable: SkillFrontmatter.parseBool(meta["user-invocable"] ?? meta["user_invocable"], default: true),
            paths: SkillFrontmatter.parseStringList(meta["paths"] ?? ""),
            packaging: .directory,
            rawFrontmatter: meta
        )
    }

    /// Stable scoped id so the same skill name across scopes doesn't collide.
    private nonisolated static func idFor(source: ClaudeSkill.Source, name: String) -> String {
        switch source {
        case .standalone:           return "standalone:\(name)"
        case .enterprise:           return "enterprise:\(name)"
        case .plugin(let p):        return "plugin:\(p):\(name)"
        case .project(let cwd):     return "project:\(cwd):\(name)"
        }
    }
}
