// V2ProjectHome — the per-project landing screen (design: "Atelier project
// home.dc.html"). Shown in the main column when a project is selected but no
// session tab is open, replacing the old blank "pick a project" state.
//
// Phase 1 (this file): project header + stat strip + tab bar + the grouped
// Sessions list, wired to real history/usage data. The Changes (git) tab and
// the CLAUDE.md/Hooks/MCPs sidebar are stubbed for follow-on phases.

import SwiftUI
import AppKit
import Inject

struct V2ProjectHome: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState
    @StateObject private var git = V2GitModel()
    @State private var tab: Tab = .sessions

    private enum Tab { case sessions, changes }

    var body: some View {
        VStack(spacing: 0) {
            header
            statStrip
            tabBar
            Group {
                switch tab {
                case .sessions: sessionsBody
                case .changes:  changesView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(v2.paper)
        .task(id: cwd) { await git.load(cwd: cwd) }
        .enableInjection()
    }

    // MARK: - Data

    private var cwd: String { appState.selectedProjectCwd?.path ?? "" }
    private var projectName: String {
        appState.selectedProjectName.isEmpty
            ? (cwd as NSString).lastPathComponent
            : appState.selectedProjectName
    }
    private var project: Project? { store.projects.first { $0.cwd == cwd } }

    private var entries: [V2HistoryEntry] {
        guard let project else { return [] }
        return V2HistoryEntry.collect(from: [project])
    }
    private var groups: [V2HistoryGroup] { V2HistoryEntry.bucket(entries) }

    private var projectTokens: Int { store.usageTotals.byProject[cwd]?.usage.total ?? 0 }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            V2DovetailMark(size: 32).foregroundColor(v2.ink)
            VStack(alignment: .leading, spacing: 3) {
                Text(projectName)
                    .font(.system(size: 22, weight: .medium)).kerning(-0.44)
                    .foregroundColor(v2.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(subline)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Button(action: { appState.newTab() }) {
                    Text("+ New session")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.paper)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(v2.ink)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("n", modifiers: .command)
                Button(action: openInFinder) {
                    Text("Open in Finder")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 28).padding(.top, 20).padding(.bottom, 18)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var subline: String {
        var parts = [cwd]
        if let branch = git.status?.branch, branch != "—" { parts.append(branch) }
        if let last = entries.first?.relativeTime { parts.append("last active \(last) ago") }
        return parts.joined(separator: " · ")
    }

    // MARK: - Stat strip

    private var statStrip: some View {
        HStack(spacing: 0) {
            statCell("sessions", "\(project?.sessions.count ?? 0)", leadingPad: 28, last: false)
            statCell("total cost", "—", leadingPad: 20, last: false)
            statCell("tokens used", projectTokens > 0 ? V2Format.count(projectTokens) : "—", leadingPad: 20, last: false)
            statCell("avg turns", "—", leadingPad: 20, last: true)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func statCell(_ label: String, _ value: String, leadingPad: CGFloat, last: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 9.5, design: .monospaced)).kerning(1.1)
                .foregroundColor(v2.faint)
                .lineLimit(1).truncationMode(.tail)
            Text(value)
                .font(.system(size: 24, weight: .medium)).kerning(-0.48)
                .foregroundColor(v2.ink)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, leadingPad).padding(.trailing, 20).padding(.vertical, 14)
        .overlay(alignment: .trailing) {
            if !last { Rectangle().fill(v2.line).frame(width: 1) }
        }
    }

    // MARK: - Tab bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            tabButton("Sessions", .sessions, badge: nil)
            tabButton("Changes", .changes, badge: changeBadge)
            Spacer()
            // Branch as a token (ref), ahead/behind carry valence — agent
            // vocabulary's git refs.
            if let s = git.status, s.branch != "—" {
                HStack(spacing: 7) {
                    Circle().fill(v2.ink).frame(width: 6, height: 6)
                    V2Token(s.branch)
                    if s.ahead > 0 {
                        Text("↑\(s.ahead)").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.add)
                    }
                    if s.behind > 0 {
                        Text("↓\(s.behind)").font(.system(size: 11, design: .monospaced)).foregroundColor(v2.faint)
                    }
                }
                .frame(maxWidth: 280, alignment: .trailing)
            }
        }
        .padding(.horizontal, 20)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var changeBadge: String? {
        let n = git.status?.changeCount ?? 0
        return n > 0 ? "\(n)" : nil
    }

    private func tabButton(_ title: String, _ which: Tab, badge: String?) -> some View {
        let on = tab == which
        return Button(action: { tab = which }) {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 12, design: .monospaced)).kerning(0.24)
                    .foregroundColor(on ? v2.ink : v2.mute)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(on ? v2.ink : Color.clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sessions body

    /// Lookup so a row can reach the underlying Session (for firstPrompt and
    /// lazy loading) while still grouping/ordering via V2HistoryEntry.
    private var sessionsById: [String: Session] {
        Dictionary(project?.sessions.map { ($0.id, $0) } ?? [], uniquingKeysWith: { a, _ in a })
    }

    private var sessionsBody: some View {
        // Build the id→Session map ONCE, not once per row. sessionRow used to
        // read the computed `sessionsById`, which rebuilt the whole dictionary
        // for every visible row → O(n²) over the list.
        let byId = sessionsById
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if groups.isEmpty {
                    emptySessions
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        groupHeader(group.label)
                        ForEach(group.entries) { entry in
                            sessionRow(entry, session: byId[entry.sessionId])
                        }
                    }
                }
            }
        }
    }

    private func groupHeader(_ label: String) -> some View {
        Text(label.uppercased())
            .font(.system(size: 9.5, design: .monospaced)).kerning(1.1)
            .foregroundColor(v2.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.top, 14).padding(.bottom, 6)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func sessionRow(_ entry: V2HistoryEntry, session s: Session?) -> some View {
        let open = isOpen(entry)
        let title = rowTitle(entry, s)
        let subtitle = rowSubtitle(s)
        return Button(action: { openSession(entry) }) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 14, weight: open ? .semibold : .medium)).kerning(-0.2)
                        .foregroundColor(v2.ink)
                        .lineLimit(1).truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.faint)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if open { openBadge }
                // Fixed-width time column so every timestamp lines up — the
                // rows read as a table, not scattered text (Law of Similarity).
                Text("\(entry.relativeTime) ago")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(width: 76, alignment: .trailing)
            }
            .padding(.horizontal, 28).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(open ? v2.card : Color.clear)
            .overlay(alignment: .leading) { if open { Rectangle().fill(v2.ink).frame(width: 3) } }
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(V2RowPressStyle())
        .onAppear {
            if let s {
                Task { await store.loadSlug(for: s); await store.loadFirstPrompt(for: s) }
            }
        }
    }

    private var openBadge: some View {
        Text("open")
            .font(.system(size: 9.5, design: .monospaced)).kerning(0.6)
            .foregroundColor(v2.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(v2.ink, lineWidth: 1))
    }

    private var emptySessions: some View {
        Text("No sessions yet — “+ New session” to start one.")
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(v2.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28).padding(.vertical, 22)
    }

    /// What the session was ABOUT — the first human prompt wins (far better
    /// than the last message, which is often "/clear"). Falls back through a
    /// real last message, the session name, then the id.
    private func rowTitle(_ entry: V2HistoryEntry, _ s: Session?) -> String {
        if let fp = s?.firstPrompt, !fp.isEmpty { return fp }
        if let s {
            let p = s.lastMessagePreview.trimmingCharacters(in: .whitespacesAndNewlines)
            if !p.isEmpty && !p.hasPrefix("/") { return p }
            if let slug = s.slug, !slug.isEmpty { return humanize(slug) }
            if !p.isEmpty { return p }
        }
        return entry.title
    }

    /// A muted second line of clues so rows are never empty: model · tokens,
    /// plus the session's own name when the title is the opening prompt.
    private func rowSubtitle(_ s: Session?) -> String? {
        guard let s else { return nil }
        var bits: [String] = []
        if let u = store.usageTotals.bySession["\(cwd)::\(s.id)"] {
            if u.usage.total > 0 { bits.append("\(V2Format.count(u.usage.total)) tokens") }
            if let model = u.usage.byModel.max(by: { $0.value.total < $1.value.total })?.key {
                bits.append(model.replacingOccurrences(of: "claude-", with: ""))
            }
        }
        if let fp = s.firstPrompt, !fp.isEmpty, let slug = s.slug, !slug.isEmpty {
            bits.append(humanize(slug))
        }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private func humanize(_ slug: String) -> String {
        slug.replacingOccurrences(of: "-", with: " ")
    }

    private func isOpen(_ entry: V2HistoryEntry) -> Bool {
        appState.tabs.contains {
            appState.resumeIds[$0.id] == entry.sessionId || $0.streamSession?.sessionId == entry.sessionId
        }
    }

    private func openSession(_ entry: V2HistoryEntry) {
        appState.openHistorySession(
            sessionId: entry.sessionId,
            projectCwd: entry.projectCwd,
            projectName: projectName,
            title: entry.title
        )
    }

    private func openInFinder() {
        guard !cwd.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: cwd)])
    }

    // MARK: - Changes (real git)

    private var changesView: some View {
        V2ProjectChanges(git: git)
    }
}
