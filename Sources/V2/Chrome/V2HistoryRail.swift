// History list shown inside the left rail when the user flips the
// projects/history toggle. Claude sessions come from Store.projects; Codex
// threads come from the local official app-server. Both are merged, sorted,
// then grouped into time buckets per the design
// (Atelier+app.dc.html → historyData).
//
// Each row resumes its provider-native session/thread in a Mode-B tab.

import SwiftUI
import Inject

struct V2HistoryRail: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState

    // Cached snapshot of both providers across all projects. Claude is
    // recomputed only when store.projects changes; Codex is refreshed once
    // when the rail appears/binary changes — never on every render. Previously
    // V2HistoryEntry.collect (a flatMap + map + sort across thousands of
    // sessions) ran on EVERY SwiftUI render, which made the rail noticeably
    // chunky as the user typed into the search box.
    @State private var cachedAll: [V2HistoryEntry] = []
    @State private var cachedClaude: [V2HistoryEntry] = []
    @State private var cachedCodex: [V2HistoryEntry] = []
    @State private var cachedGroups: [V2HistoryGroup] = []
    @State private var lastProjectSignature: Int = 0
    @State private var codexHistoryLoading = false
    @State private var codexHistoryError: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                let groups = filteredGroups
                // Sessions already open in an Atelier tab are never "live to
                // observe" — they're live IN-APP. Built once per body eval
                // (tabs are a handful), not per row.
                let openClaudeIds = Set(appState.tabs.compactMap { $0.streamSession?.sessionId })
                let openCodexIds = Set(appState.tabs.compactMap { $0.codexSession?.threadId })
                    .union(appState.codexResumeIds.values)
                if codexHistoryLoading {
                    historyStatus("Loading Codex history…")
                } else if let codexHistoryError {
                    historyStatus("Codex history unavailable · \(codexHistoryError)")
                }
                if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.label) { group in
                        groupHeader(group.label)
                        ForEach(group.entries) { entry in
                            // A session file that grew in the last ~2 minutes
                            // IS a live session some other process owns (#75)
                            // — offer observing instead of resume (resuming a
                            // session another harness owns is the takeover
                            // path observer mode exists to avoid).
                            let isOpen = entry.provider == .claude
                                ? openClaudeIds.contains(entry.sessionId)
                                : openCodexIds.contains(entry.sessionId)
                            let isLive = entry.provider == .claude && !isOpen
                                && Date().timeIntervalSince(entry.lastActivity) < 120
                            V2HistoryRow(entry: entry, isLive: isLive) {
                                if entry.provider == .codex {
                                    appState.openCodexHistoryThread(
                                        threadId: entry.sessionId,
                                        projectCwd: entry.projectCwd,
                                        title: entry.title
                                    )
                                } else if isLive {
                                    appState.openObserver(
                                        projectCwd: entry.projectCwd,
                                        sessionId: entry.sessionId,
                                        title: entry.title
                                    )
                                } else {
                                    appState.openHistorySession(
                                        sessionId: entry.sessionId,
                                        projectCwd: entry.projectCwd,
                                        projectName: entry.projectName,
                                        title: entry.title
                                    )
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .onAppear { refreshIfNeeded() }
        .onChange(of: projectSignature) { _, _ in
            cachedClaude = V2HistoryEntry.collect(from: store.projects)
            rebuildCombinedHistory()
            lastProjectSignature = projectSignature
        }
        .task(id: appState.codexBinary) { await refreshCodexHistory() }
        .enableInjection()
    }

    /// Cheap signature that changes when the project set actually changes —
    /// avoids deep equality on every render.
    private var projectSignature: Int {
        var hasher = Hasher()
        hasher.combine(store.projects.count)
        for project in store.projects {
            hasher.combine(project.id)
            hasher.combine(project.sessions.count)
        }
        return hasher.finalize()
    }

    private func refreshIfNeeded() {
        let sig = projectSignature
        if sig != lastProjectSignature || cachedAll.isEmpty {
            cachedClaude = V2HistoryEntry.collect(from: store.projects)
            rebuildCombinedHistory()
            lastProjectSignature = sig
        }
    }

    @MainActor
    private func refreshCodexHistory() async {
        guard let binary = appState.codexBinary else {
            cachedCodex = []
            codexHistoryError = nil
            rebuildCombinedHistory()
            return
        }
        codexHistoryLoading = true
        codexHistoryError = nil
        defer { codexHistoryLoading = false }
        do {
            cachedCodex = try await CodexSession.listThreads(codexURL: binary).map(V2HistoryEntry.init)
        } catch {
            codexHistoryError = error.localizedDescription
        }
        rebuildCombinedHistory()
    }

    private func rebuildCombinedHistory() {
        cachedAll = (cachedClaude + cachedCodex).sorted { $0.lastActivity > $1.lastActivity }
        cachedGroups = V2HistoryEntry.bucket(cachedAll)
    }

    /// Filter is cheap relative to collect — runs on the cached set on
    /// every search-query change but doesn't re-walk Store.projects.
    private var filteredEntries: [V2HistoryEntry] {
        let q = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return cachedAll }
        return cachedAll.filter {
            $0.title.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.sessionId.lowercased().contains(q)
        }
    }

    private var filteredGroups: [V2HistoryGroup] {
        let q = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        if q.isEmpty { return cachedGroups }
        return V2HistoryEntry.bucket(filteredEntries)
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(v2.faint)
            .padding(.horizontal, 8)
            .padding(.top, 13)
            .padding(.bottom, 6)
    }

    private func historyStatus(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundColor(v2.faint)
            .lineLimit(2)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions yet.")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Text("Start a session in a project to see it here.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity)
    }

}

// MARK: - Row

private struct V2HistoryRow: View {
    @Environment(\.v2) private var v2
    let entry: V2HistoryEntry
    var isLive: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    if isLive {
                        V2PulseDot(size: 7, color: v2.ink)
                    } else {
                        Circle()
                            .fill(entry.isActive ? v2.ink : Color.clear)
                            .overlay(Circle().stroke(entry.isActive ? Color.clear : v2.line2, lineWidth: 1))
                            .frame(width: 7, height: 7)
                    }
                    Text(entry.title)
                        .font(.system(size: 13, weight: (entry.isActive || isLive) ? .medium : .regular))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if isLive {
                        Text("live")
                            .font(.system(size: 9, design: .monospaced))
                            .kerning(0.5)
                            .foregroundColor(v2.ink)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    } else {
                        Text(entry.relativeTime)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(v2.faint)
                    }
                }
                HStack(spacing: 7) {
                    V2ProviderBadge(provider: entry.provider, density: .compact, style: .plain)
                    Text(entry.projectName)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.meta.isEmpty {
                        Text(entry.meta)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(v2.faint)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 15)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(entry.isActive ? v2.card : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if entry.isActive {
                    Rectangle().fill(v2.providerAccent(entry.provider)).frame(width: 2)
                }
            }
        }
        .buttonStyle(V2RowPressStyle())
        .help("\(entry.projectCwd) · \(entry.provider.displayName) \(String(entry.sessionId.prefix(8)))")
    }
}

// MARK: - Model

struct V2HistoryEntry: Identifiable {
    let id: String  // provider-prefixed native id
    let sessionId: String
    let provider: V2AgentProvider
    let projectCwd: String
    let projectName: String
    let title: String
    let lastActivity: Date
    let isActive: Bool
    let meta: String  // extra suffix (turn count, etc.) when we have it; currently empty

    var relativeTime: String { Self.formatRelative(lastActivity) }

    static func collect(from projects: [Project]) -> [V2HistoryEntry] {
        projects.flatMap { project in
            project.sessions.map { s in
                V2HistoryEntry(
                    id: "claude:\(s.id)",
                    sessionId: s.id,
                    provider: .claude,
                    projectCwd: project.cwd,
                    projectName: project.displayName,
                    title: titleFor(session: s),
                    lastActivity: s.lastActivity,
                    isActive: s.isActive,
                    meta: ""
                )
            }
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }

    static func bucket(_ entries: [V2HistoryEntry]) -> [V2HistoryGroup] {
        let cal = Calendar.current
        let now = Date()
        let startOfToday = cal.startOfDay(for: now)
        guard let startOfYesterday = cal.date(byAdding: .day, value: -1, to: startOfToday),
              let startOfWeek = cal.date(byAdding: .day, value: -7, to: startOfToday) else {
            return [V2HistoryGroup(label: "All", entries: entries)]
        }
        var today: [V2HistoryEntry] = []
        var yesterday: [V2HistoryEntry] = []
        var thisWeek: [V2HistoryEntry] = []
        var older: [V2HistoryEntry] = []
        for e in entries {
            if e.lastActivity >= startOfToday { today.append(e) }
            else if e.lastActivity >= startOfYesterday { yesterday.append(e) }
            else if e.lastActivity >= startOfWeek { thisWeek.append(e) }
            else { older.append(e) }
        }
        var groups: [V2HistoryGroup] = []
        if !today.isEmpty { groups.append(.init(label: "Today", entries: today)) }
        if !yesterday.isEmpty { groups.append(.init(label: "Yesterday", entries: yesterday)) }
        if !thisWeek.isEmpty { groups.append(.init(label: "This week", entries: thisWeek)) }
        if !older.isEmpty { groups.append(.init(label: "Older", entries: older)) }
        return groups
    }

    static func titleFor(session s: Session) -> String {
        if let slug = s.slug, !slug.isEmpty { return slug.replacingOccurrences(of: "-", with: " ") }
        let preview = s.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty { return String(preview.prefix(72)) }
        return "session \(String(s.id.prefix(8)))"
    }

    private static func formatRelative(_ d: Date) -> String {
        let secs = Int(Date().timeIntervalSince(d))
        if secs < 60 { return "\(max(secs, 1))s" }
        let mins = secs / 60
        if mins < 60 { return "\(mins)m" }
        let hours = mins / 60
        if hours < 48 { return "\(hours)h" }
        let days = hours / 24
        if days < 14 { return "\(days)d" }
        let weeks = days / 7
        if weeks < 8 { return "\(weeks)w" }
        let months = days / 30
        return "\(months)mo"
    }
}

extension V2HistoryEntry {
    init(_ thread: CodexThreadSummary) {
        id = "codex:\(thread.id)"
        sessionId = thread.id
        provider = .codex
        projectCwd = thread.cwd
        projectName = (thread.cwd as NSString).lastPathComponent
        title = thread.title
        lastActivity = thread.updatedAt
        isActive = false
        meta = ""
    }
}

struct V2HistoryGroup {
    let label: String
    let entries: [V2HistoryEntry]
}
