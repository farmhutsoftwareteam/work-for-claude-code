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
    @State private var showingHooksEditor = false
    @State private var showingMCPSheet = false

    // Sorted projects cached so we don't re-sort on every render. Sort is
    // O(n log n) over Store.projects (typically ~80 entries here), running
    // on every keystroke into the search field used to add measurable
    // jank. Recomputed only when the project set actually changes.
    @State private var sortedProjects: [Project] = []
    @State private var lastProjectSignature: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            searchBox
            railTabs
            railContent
            if appState.railTab == .projects {
                addProjectButton
            }
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
        .sheet(isPresented: $showingMCPSheet) {
            MCPEditor(mode: .add(defaultScope: .user)) {
                showingMCPSheet = false
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .onAppear { refreshProjectsIfNeeded() }
        .onChange(of: projectsSignature) { _, newSig in refreshProjectsIfNeeded(signature: newSig) }
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
        HStack(spacing: 8) {
            Text("PROJECTS")
                .font(.system(size: 10, weight: .regular, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.faint)
            Spacer()
            Text("\(filtered.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
            Button { appState.showAddProject = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(v2.mute)
                    .frame(width: 20, height: 20)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a project (⌘O)")
            .keyboardShortcut("o", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Prominent, always-visible add affordance at the foot of the project
    /// list (design: the dashed "Add project" button).
    private var addProjectButton: some View {
        Button { appState.showAddProject = true } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                Text("Add project").font(.system(size: 12, design: .monospaced))
            }
            .foregroundColor(v2.mute)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(v2.card)
            .overlay(
                Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundColor(v2.line2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(12)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
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
                        mcpAlert: store.projectHasUnconnectedMCP(project.cwd),
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
        // Sort is cached, filter runs against the cached list — cheap.
        let q = appState.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return sortedProjects }
        return sortedProjects.filter {
            $0.displayName.lowercased().contains(q) || $0.cwd.lowercased().contains(q)
        }
    }

    private var projectsSignature: Int {
        var hasher = Hasher()
        hasher.combine(store.projects.count)
        for project in store.projects {
            hasher.combine(project.id)
            hasher.combine(project.isActive)
            // Include recency so the list re-sorts when a project's last
            // activity changes (new session / message), not just on add.
            hasher.combine(projectRecency(project))
        }
        return hasher.finalize()
    }

    /// Most-recent activity for a project (latest session). Projects with no
    /// sessions sink to the bottom. O(1): `Store.buildProjects` keeps each
    /// project's `sessions` sorted by `lastActivity` descending, so the first
    /// element is the most recent — avoids a per-render scan + array allocation
    /// over every session of every project (this runs inside
    /// `projectsSignature`, which SwiftUI evaluates on every body pass).
    private func projectRecency(_ p: Project) -> Date {
        p.sessions.first?.lastActivity ?? .distantPast
    }

    private func refreshProjectsIfNeeded(signature: Int? = nil) {
        // Reuse the signature onChange already computed instead of hashing the
        // whole project set a second time.
        let sig = signature ?? projectsSignature
        if sig != lastProjectSignature || sortedProjects.isEmpty {
            // Precompute recency once per project, then sort: live projects
            // first, then most-recently-active on top, name as the final
            // tiebreak.
            sortedProjects = store.projects
                .map { (p: $0, r: projectRecency($0)) }
                .sorted { l, r in
                    if l.p.isActive != r.p.isActive { return l.p.isActive }
                    if l.r != r.r { return l.r > r.r }
                    return l.p.displayName.localizedCaseInsensitiveCompare(r.p.displayName) == .orderedAscending
                }
                .map(\.p)
            lastProjectSignature = sig
        }
    }

    // MARK: - Workbench

    /// Six-tile grid at the bottom of the rail. Real counts from Store,
    /// real destinations on click. Same chrome region the original v2
    /// design called for.
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
                ForEach(workbenchTiles) { tile in
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

    /// Live counts pulled from Store, not mocks. Order matches the design.
    private var workbenchTiles: [V2WorkbenchTile] {
        let totalSkills = store.standaloneSkills.count
            + store.pluginSkills.values.reduce(0) { $0 + $1.count }
        let totalMCPs = store.standaloneMCPs.count
            + store.pluginMCPs.values.reduce(0) { $0 + $1.count }
        return [
            V2WorkbenchTile(label: "Plugins", count: "\(store.plugins.count)", hint: "installed"),
            V2WorkbenchTile(label: "Skills",  count: "\(totalSkills)",          hint: "available"),
            V2WorkbenchTile(label: "MCPs",    count: "\(totalMCPs)",            hint: "connected"),
            V2WorkbenchTile(label: "Hooks",   count: "\(store.hooks.count)",    hint: "active"),
            V2WorkbenchTile(label: "Usage",   count: "—",                        hint: "this month"),
            V2WorkbenchTile(label: "Market",  count: "∞",                        hint: "browse"),
        ]
    }

    private func tap(tile: V2WorkbenchTile) {
        switch tile.label {
        case "Hooks":
            showingHooksEditor = true
        case "MCPs":
            showingMCPSheet = true
        case "Usage":
            appState.mainView = .usage
        case "Skills", "Market":
            // Market opens straight into the same panel's marketplace tab —
            // both tiles land on one surface, matching the design spec.
            appState.openDock(.skills)
        case "Plugins":
            // No v2 surface for this yet — still managed via the v1
            // Extensions window for now.
            break
        default:
            break
        }
    }
}

// MARK: - Project row

private struct V2ProjectRow: View {
    @Environment(\.v2) private var v2
    @ObservedObject private var iconLoader = ProjectIconLoader.shared
    let name: String
    let cwd: String
    let sessionCount: Int
    let live: Bool
    var mcpAlert: Bool = false
    let isActive: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                // Project logo when one passed the quality gates; the live dot
                // still wins the slot (status beats branding). No logo → the
                // original hollow/filled circle.
                if !live, let icon = iconLoader.icon(for: cwd) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 12, height: 12)
                } else {
                    Circle()
                        .fill(live ? v2.ink : Color.clear)
                        .overlay(Circle().stroke(live ? Color.clear : v2.line2, lineWidth: 1))
                        .frame(width: 7, height: 7)
                        .frame(width: 12)
                }
                Text(name)
                    .font(.system(size: 13.5, weight: isActive ? .medium : .regular))
                    .kerning(-0.13)
                    .foregroundColor(v2.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer()
                // Red dot when one of this project's own MCP servers needs
                // sign-in — a scannable "this project has a disconnected tool"
                // cue down the rail.
                if mcpAlert {
                    Circle().fill(v2.del).frame(width: 6, height: 6)
                        .help("An MCP server in this project needs sign-in")
                }
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
        .buttonStyle(V2RowPressStyle())
        .help(cwd)
    }
}

/// Instant press feedback for rail rows. The highlight + left bar appear on
/// mouse-DOWN — before any session spawns or content loads — so a click is
/// visibly acknowledged immediately and you don't click twice wondering if it
/// registered. Used by project rows and history rows.
struct V2RowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressBody(configuration: configuration)
    }
    private struct PressBody: View {
        @Environment(\.v2) private var v2
        let configuration: Configuration
        var body: some View {
            configuration.label
                // Force the styled row to fill its width and make the ENTIRE
                // rectangle the hit target — a custom ButtonStyle doesn't
                // inherit the label's contentShape, so without this only the
                // text/glyphs were clickable.
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(configuration.isPressed ? v2.ink.opacity(0.10) : Color.clear)
                .overlay(alignment: .leading) {
                    if configuration.isPressed {
                        Rectangle().fill(v2.ink).frame(width: 2)
                    }
                }
                .contentShape(Rectangle())
        }
    }
}

// MARK: - Workbench tile button

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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
