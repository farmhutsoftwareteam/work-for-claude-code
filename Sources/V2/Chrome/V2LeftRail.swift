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
    @State private var search: String = ""
    @State private var showingHooksEditor = false

    var body: some View {
        VStack(spacing: 0) {
            searchBox
            railTabs
            railContent
            workbenchRail
        }
        .background(v2.paper2)
        .overlay(alignment: .trailing) {
            Rectangle().fill(v2.line).frame(width: 1)
        }
        .sheet(isPresented: $showingHooksEditor) {
            V2HooksEditorSheet(onClose: { showingHooksEditor = false })
                .environmentObject(store)
        }
        .enableInjection()
    }

    // MARK: - Search

    private var searchBox: some View {
        Button { appState.searchOpen = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(v2.faint)
                Text("Search sessions…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                Spacer()
                Text("⌘K")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
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
        switch appState.railTab {
        case .projects:
            VStack(spacing: 0) {
                projectsHeader
                projectList
            }
        case .history:
            V2HistoryRail()
                .frame(maxHeight: .infinity)
        }
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
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    // MARK: - Workbench

    private var workbenchRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WORKBENCH")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)

            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 1), GridItem(.flexible(), spacing: 1)],
                spacing: 1
            ) {
                ForEach(V2Mock.workbenchTiles) { tile in
                    V2WorkbenchTileButton(tile: tile, onTap: { tap(tile: tile) })
                }
            }
            .background(v2.line)
            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
        }
        .padding(14)
        .background(v2.paper3)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    private func tap(tile: V2WorkbenchTile) {
        switch tile.label {
        case "Hooks":
            showingHooksEditor = true
        default:
            // Other tiles route through the v1 ExtensionsView for now.
            break
        }
    }
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

// MARK: - Workbench tile

private struct V2WorkbenchTileButton: View {
    @Environment(\.v2) private var v2
    let tile: V2WorkbenchTile
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(tile.label)
                        .font(.system(size: 12.5, weight: .medium))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                    Spacer()
                    Text(tile.count)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Text(tile.hint)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper2)
        }
        .buttonStyle(.plain)
    }
}
