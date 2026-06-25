// History list shown inside the left rail when the user flips the
// projects/history toggle. Sessions are pulled from Store.projects, flattened
// across all projects, then grouped into time buckets per the design
// (Atelier+app.dc.html → historyData).
//
// Each row is a button that calls V2AppState.openHistorySession, which spawns
// a Mode-B tab with --resume <session-id>.

import SwiftUI
import Inject

struct V2HistoryRail: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if entries.isEmpty {
                    emptyState
                } else {
                    ForEach(groups, id: \.label) { group in
                        groupHeader(group.label)
                        ForEach(group.entries) { entry in
                            V2HistoryRow(entry: entry) {
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
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .enableInjection()
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

    private var entries: [V2HistoryEntry] {
        let all = V2HistoryEntry.collect(from: store.projects)
        let q = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.title.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.sessionId.lowercased().contains(q)
        }
    }

    private var groups: [V2HistoryGroup] {
        V2HistoryEntry.bucket(entries)
    }
}

// MARK: - Row

private struct V2HistoryRow: View {
    @Environment(\.v2) private var v2
    let entry: V2HistoryEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(entry.isActive ? v2.ink : Color.clear)
                        .overlay(Circle().stroke(entry.isActive ? Color.clear : v2.line2, lineWidth: 1))
                        .frame(width: 7, height: 7)
                    Text(entry.title)
                        .font(.system(size: 13, weight: entry.isActive ? .medium : .regular))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(entry.relativeTime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                HStack(spacing: 7) {
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
            .overlay(alignment: .leading) {
                if entry.isActive {
                    Rectangle().fill(v2.ink).frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help("\(entry.projectCwd) · session \(String(entry.sessionId.prefix(8)))")
    }
}

// MARK: - Model

struct V2HistoryEntry: Identifiable {
    let id: String  // sessionId, unique
    let sessionId: String
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
                    id: s.id,
                    sessionId: s.id,
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

struct V2HistoryGroup {
    let label: String
    let entries: [V2HistoryEntry]
}
