// Left rail (264px) — search input, scrollable project list pulled from the
// real Store, workbench tile grid at the bottom. Active project shows inset
// shadow + card bg. Clicking a project sets V2AppState.selectedProjectCwd.

import SwiftUI
import Inject

struct V2LeftRail: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchBox
            railTabs
            railContent
            // workbenchRail moved out — it was a dashboard tile grid
            // (Plugins · Skills · MCPs · Hooks · Usage · Market) that
            // mostly showed counters with no next-action. Counts live
            // in the title bar now; Hooks/Usage have dedicated surfaces
            // we still open from other places.
        }
        .background(v2.paper2)
        .overlay(alignment: .trailing) {
            Rectangle().fill(v2.line).frame(width: 1)
        }
        .enableInjection()
    }

    // MARK: - Search

    private var searchBox: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(v2.faint)
            TextField(searchPlaceholder, text: $appState.searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.ink)
                .onSubmit(openFirstMatch)
            if !appState.searchQuery.isEmpty {
                Button { appState.searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(v2.faint)
                }
                .buttonStyle(.plain)
            } else {
                Text("⌘K")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(v2.card)
        .overlay(Rectangle().stroke(searchFocused ? v2.ink : v2.line2, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        // ⌘K from anywhere in the v2 window focuses this field — that's it.
        // No modal pops up; the rail just lights up and the user starts
        // typing.
        .onChange(of: appState.searchOpen) { _, open in
            if open {
                searchFocused = true
                // Reset the flag — V2RootView toggles it, we consume it.
                appState.searchOpen = false
            }
        }
    }

    private var searchPlaceholder: String {
        switch appState.railTab {
        case .projects: return "Filter projects…"
        case .history:  return "Search sessions…"
        }
    }

    private func openFirstMatch() {
        guard appState.railTab == .history else { return }
        let entries = V2HistoryEntry.collect(from: store.projects)
        let q = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty,
              let first = entries.first(where: {
                  $0.title.lowercased().contains(q)
                      || $0.projectName.lowercased().contains(q)
                      || $0.sessionId.lowercased().contains(q)
              }) else { return }
        appState.openHistorySession(
            sessionId: first.sessionId,
            projectCwd: first.projectCwd,
            projectName: first.projectName,
            title: first.title
        )
        appState.searchQuery = ""
    }

    @ViewBuilder
    private var railTabs: some View {
        HStack(spacing: 0) {
            ForEach(V2AppState.RailTab.allCases) { tab in
                Button {
                    appState.railTab = tab
                } label: {
                    Text(tab.rawValue)
                        .font(.system(size: 11, design: .monospaced))
                        .kerning(0.22)
                        .foregroundColor(appState.railTab == tab ? v2.paper : v2.mute)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(appState.railTab == tab ? v2.ink : Color.clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var railContent: some View {
        // Wrapped in a Group + frame so the inner ScrollView (projectList /
        // V2HistoryRail) actually expands. Without an explicit
        // maxHeight: .infinity the ScrollView collapses to zero inside this
        // sibling VStack and the rail appears empty between the tabs and
        // the workbench grid.
        Group {
            switch appState.railTab {
            case .projects:
                VStack(spacing: 0) {
                    projectsHeader
                    projectList
                }
            case .history:
                V2HistoryRail()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var projectsHeader: some View {
        HStack {
            Text("PROJECTS")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)
            Spacer()
            Text("\(filtered.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filtered, id: \.id) { project in
                    V2ProjectRow(
                        name: project.displayName,
                        cwd: project.cwd,
                        sessionCount: project.sessions.count,
                        live: project.isActive,
                        isActive: appState.selectedProjectCwd?.path == project.cwd
                    ) {
                        appState.selectProject(cwd: project.cwd, name: project.displayName)
                    }
                }
                if filtered.isEmpty {
                    Text(store.projects.isEmpty ? "No Claude projects yet." : "No matches.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.vertical, 24)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
    }

    private var filtered: [Project] {
        let q = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = store.projects.sorted { l, r in
            // Live projects first, then alphabetical.
            if l.isActive != r.isActive { return l.isActive }
            return l.displayName.localizedCaseInsensitiveCompare(r.displayName) == .orderedAscending
        }
        guard !q.isEmpty else { return sorted }
        return sorted.filter {
            $0.displayName.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
        }
    }

    // Workbench tile grid removed — counts now live in the title bar
    // (V2TitleBar.statusLine). Hooks editor sheet hosting also moved out
    // since nothing in the rail surfaces it anymore.
}

// MARK: - Project row

private struct V2ProjectRow: View {
    @Environment(\.v2) private var v2
    let name: String
    let cwd: String
    let sessionCount: Int
    let live: Bool
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Circle()
                    .fill(live ? v2.ink : Color.clear)
                    .overlay(Circle().stroke(live ? Color.clear : v2.line2, lineWidth: 1))
                    .frame(width: 7, height: 7)
                Text(name)
                    .font(.system(size: 13.5, weight: isActive ? .medium : .regular))
                    .kerning(-0.13)
                    .foregroundColor(v2.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                Text(sessionCount > 0 ? "\(sessionCount)" : "")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? v2.card : Color.clear)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isActive {
                    Rectangle().fill(v2.ink).frame(width: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .help(cwd)
    }
}

