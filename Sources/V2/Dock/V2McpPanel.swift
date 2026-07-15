// MCP panel — Mode-B contextual view of the servers Claude actually loaded
// for this session. Reads V2AppState.activeSession.mcpServers — sourced from
// the `system/init` event the binary emits at session start.
//
// Different from the deep MCPEditor in v1's ExtensionsView (which is the full
// CRUD surface over ~/.claude.json). This panel is read-mostly + at-a-glance.

import SwiftUI
import AppKit
import Darwin
import Inject

/// The three real MCP scopes, named exactly the way `claude mcp add --scope`
/// itself names them — not an invented taxonomy. Previously this panel only
/// drew ONE boundary (project+local merged into "this project" vs. global+
/// plugin as "everywhere"), which silently flattened two scopes that behave
/// completely differently (checked-in and team-shared vs. private-to-you)
/// into one bucket distinguished only by a quiet subtext line. User
/// feedback, verbatim (2026-07-14): "we still havent properly seprated
/// proejct mcp and worspace mcp or the mcps available to the whole computer
/// on my user, like its so confusing and not even onbious."
enum V2McpScopeTier {
    /// `<cwd>/.mcp.json` — checked into git, shared with the team.
    case project
    /// `~/.claude.json` → `projects.<cwd>` — private to you, this project only.
    case local
    /// `~/.claude.json` top-level, or a plugin — every project on this Mac.
    case user

    static func of(_ s: MCPServer.Source) -> V2McpScopeTier {
        switch s {
        case .project:        return .project
        case .localUser:      return .local
        case .global, .plugin: return .user
        }
    }

    var title: String {
        switch self {
        case .project: return "Project"
        case .local:   return "Local"
        case .user:    return "User"
        }
    }
    var subtitle: String {
        switch self {
        case .project: return "In .mcp.json — checked in, shared with your team."
        case .local:   return "Just this project, just you — not shared, not checked in."
        case .user:    return "Every project on this Mac, not just this one."
        }
    }
}

struct V2McpPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var store: Store
    @State private var addingMCP = false
    // Marketplace-driven add (#NN — "super easy" add flow): browsing is now
    // the DEFAULT "+ add" action, not a hidden toolbar button only the v1
    // window exposed. MCPMarketplaceView + MCPRegistry.makeDraft already
    // existed, fully working, wired only into the legacy v1 ExtensionsView
    // — a window that never auto-opens. Same two-sheet sequencing v1 uses
    // (SwiftUI won't present two sheets at once): the marketplace's
    // onInstall stashes a draft, then onDismiss opens the pre-filled editor.
    @State private var showingMarketplace = false
    @State private var pendingMarketplaceDraft: MCPDraft?
    @State private var marketplaceInstallDraft: MCPDraft?
    /// "Use in this project" (scope copy-down): the user-scope server being
    /// copied to this project's local scope with the same name — Claude
    /// Code's precedence (local > project > user) makes it a per-project
    /// override, e.g. supabase pointed at THIS project's project_ref.
    @State private var useInProjectServer: MCPServer?
    /// Delete — existed all along (MCPConfigWriter.delete), same story as
    /// the marketplace: wired only into the legacy v1 ExtensionsView, a
    /// window that never auto-opens. The v2 panel had no way to remove a
    /// server at all, which is exactly what stood between "this one's
    /// broken" and "delete it and set it up properly."
    @State private var pendingDelete: (name: String, scope: MCPConfigWriter.Scope)?
    @State private var deleteError: String?
    /// Names currently mid-delete — drives the row's "deleting…" indicator.
    /// Cleared in a `defer` so it resets on both success (row then vanishes
    /// on the next `store.load()`) and failure (row reverts, alert explains).
    @State private var deletingServers: Set<String> = []
    /// Edit an existing server in place — fixing a broken one (wrong/empty
    /// credential) without losing its identity, vs. delete-then-recreate.
    @State private var editingServer: (server: MCPServer, scope: MCPConfigWriter.Scope)?
    /// Supabase project picker: sign in first (reuses authenticate(_:)),
    /// then list_projects, then hand the pick straight into the SAME
    /// prefilled-editor flow the marketplace already uses.
    @State private var showingSupabasePicker = false
    @State private var supabasePickerError: String?
    @State private var authing: Set<String> = []   // servers mid sign-in
    @State private var authHandles: [String: V2AuthHandle] = [:]   // cancel handles
    @State private var authFailedServer: String?   // last server whose sign-in failed
    @State private var authNote: String?
    /// "Available everywhere" starts collapsed — project-scoped servers are
    /// the ones actually in play for whatever you're looking at (user
    /// feedback, 2026-07-14).
    @State private var showEverywhere = false
    /// One well-designed modal replacing the split between a single inline
    /// button (only ever one action visible at a time) and a right-click
    /// context menu — tapping a configured row opens this with every real
    /// action (sign in / use in project / edit / delete) in one place.
    @State private var actionSheetServer: MCPServer?

    /// Split from `body` because a single modifier chain this long makes the
    /// type checker time out — two smaller expressions check independently.
    var body: some View {
        withPickerSheets(baseBody)
            .enableInjection()
    }

    private var baseBody: some View {
        VStack(spacing: 0) {
            header
            if let note = authNote { authBanner(note) }
            content
        }
        .sheet(isPresented: $addingMCP) {
            MCPEditor(mode: .add(defaultScope: .user),
                      onSavedDraft: { draft, _ in maybeAutoSignIn(draft) }) {
                addingMCP = false
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .sheet(
            isPresented: $showingMarketplace,
            onDismiss: {
                if let draft = pendingMarketplaceDraft {
                    pendingMarketplaceDraft = nil
                    marketplaceInstallDraft = draft
                }
            }
        ) {
            MCPMarketplaceView { draft in
                pendingMarketplaceDraft = draft
            }
        }
        .sheet(item: Binding(
            get: { marketplaceInstallDraft.map(MarketplaceInstall.init) },
            set: { marketplaceInstallDraft = $0?.draft }
        )) { install in
            // Default marketplace installs to LOCAL scope when a project is
            // selected — project-first is the working model here (a server
            // usually binds to one project's resources), and it matches
            // `claude mcp add`'s own default. The editor's scope picker
            // still offers user scope for the genuinely-global ones.
            MCPEditor(mode: .addFromMarketplace(
                draft: install.draft,
                defaultScope: projectCwd.map { .local(cwd: $0) } ?? .user
            ), onSavedDraft: { draft, _ in maybeAutoSignIn(draft) }) {
                marketplaceInstallDraft = nil
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .sheet(item: Binding(
            get: { editingServer.map { EditTarget(server: $0.server, scope: $0.scope) } },
            set: { editingServer = $0.map { ($0.server, $0.scope) } }
        )) { target in
            MCPEditor(mode: .edit(target.server, scope: target.scope),
                      onSavedDraft: { draft, _ in maybeAutoSignIn(draft) }) {
                editingServer = nil
                Task { await store.load() }
            }
            .environmentObject(store)
            .frame(minWidth: 560, minHeight: 600)
        }
        .confirmationDialog(
            "Delete this MCP server?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let pending = pendingDelete {
                Button("Delete \"\(pending.name)\"", role: .destructive) {
                    let (name, scope) = pending
                    pendingDelete = nil
                    deletingServers.insert(name)
                    Task {
                        do {
                            try await Task.detached(priority: .userInitiated) {
                                try MCPConfigWriter.delete(name: name, scope: scope)
                            }.value
                            // Clear "deleting…" the instant the write
                            // succeeds — the old `defer` kept the row stuck
                            // until store.load() (a full re-parse of every
                            // known project's config) ALSO finished, so the
                            // row's stuck duration was however long that
                            // reload happened to take — "very very flaky"
                            // (user report, 2026-07-14). Same fix as
                            // MCPEditor.performSave's save button.
                            deletingServers.remove(name)
                            await store.load()
                        } catch {
                            deletingServers.remove(name)
                            deleteError = "Couldn't delete \"\(name)\": \(error.localizedDescription)"
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("Removed from your config — this can't be undone from the app.")
        }
        .alert("Delete failed", isPresented: Binding(get: { deleteError != nil }, set: { if !$0 { deleteError = nil } })) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .sheet(item: $actionSheetServer) { server in
            let oauth = isOAuthCapable(server.transport)
            let needsAuth = oauth && store.mcpNeedsAuth.contains(server.name)
            V2McpServerActionSheet(
                server: server,
                scopeLabel: "\(scopeLabel(server.source)) · \(transportLabel(server.transport))",
                isOAuth: oauth,
                needsAuth: needsAuth,
                isSupabasePlugin: isSupabasePluginServer(server) && projectCwd != nil,
                canCopyToProject: canCopyToProject(server),
                canEditOrDelete: scope(for: server) != nil,
                isDeleting: deletingServers.contains(server.name),
                onSignIn: { authenticate(server.name) },
                onConnectSupabase: { connectSupabaseWithPicker() },
                onUseInProject: { useInProjectServer = server },
                onEdit: {
                    if let scope = scope(for: server) { editingServer = (server, scope) }
                },
                onDelete: {
                    if let scope = scope(for: server) { pendingDelete = (name: server.name, scope: scope) }
                }
            )
        }
    }

    @ViewBuilder
    private func withPickerSheets<Content: View>(_ content: Content) -> some View {
        content
            .sheet(isPresented: $showingSupabasePicker) {
                if let binary = appState.claudeBinary {
                    V2SupabaseProjectPicker(claudeBinary: binary) { project, readOnly in
                        var url = "https://mcp.supabase.com/mcp?project_ref=\(project.id)"
                        if readOnly { url += "&read_only=true" }
                        let slug = project.name
                            .lowercased()
                            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
                            .reduce(into: "") { $0.append($1) }
                        marketplaceInstallDraft = MCPDraft(name: "supabase-\(slug)", transport: .http(url: url))
                    }
                }
            }
            .alert("Couldn't list your Supabase projects", isPresented: Binding(
                get: { supabasePickerError != nil },
                set: { if !$0 { supabasePickerError = nil } }
            )) {
                Button("OK") { supabasePickerError = nil }
            } message: {
                Text(supabasePickerError ?? "")
            }
            .sheet(item: $useInProjectServer) { server in
                if let cwd = projectCwd {
                    MCPEditor(mode: .useInProject(draft: .from(server), cwd: cwd),
                              onSavedDraft: { draft, _ in maybeAutoSignIn(draft) }) {
                        useInProjectServer = nil
                        Task { await store.load() }
                    }
                    .environmentObject(store)
                    .frame(minWidth: 560, minHeight: 600)
                }
            }
    }

    /// `.sheet(item:)` needs Identifiable; MCPDraft doesn't conform (it's a
    /// plain form-state struct reused by manual add and edit too), so this
    /// wraps it rather than adding an identity concept it doesn't need
    /// elsewhere.
    private struct MarketplaceInstall: Identifiable {
        let draft: MCPDraft
        var id: String { draft.name }
    }

    private struct EditTarget: Identifiable {
        let server: MCPServer
        let scope: MCPConfigWriter.Scope
        var id: String { server.name }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("MCP servers")
                    .font(.system(size: 15, weight: .medium))
                    .kerning(-0.15)
                Spacer()
                if serverCount > 0 {
                    Text("\(serverCount)")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                // Manual entry demoted to a small secondary link — the
                // marketplace (search → one-click install, prefilled
                // command/url/env) is the easy default now. Advanced/custom
                // servers not in the registry still need the raw form.
                Button { addingMCP = true } label: {
                    Text("manual")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .buttonStyle(.plain)
                .help("Add a server by hand (command/URL you already know)")
                Button { showingMarketplace = true } label: {
                    Text("+ add")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Browse the MCP marketplace — search and install")
            }
            Text("Tool providers claude loads on spawn — filesystem, github, etc.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineSpacing(2)
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    // MARK: - Content (binds to active session)

    @ViewBuilder
    private var content: some View {
        if let session = appState.activeSession, isInitializing(session.state) {
            initializingState
        } else if let session = appState.activeSession, isRunning(session.state), !session.mcpServers.isEmpty {
            liveContent(for: session)
        } else {
            // No live session data — show what's CONFIGURED for this project
            // (.mcp.json + ~/.claude.json local + global) so the project home
            // reflects reality instead of looking empty.
            configuredContent
        }
    }

    private func isInitializing(_ s: StreamSession.LifecycleState) -> Bool {
        switch s { case .spawning, .initializing: return true; default: return false }
    }
    private func isRunning(_ s: StreamSession.LifecycleState) -> Bool {
        switch s { case .working, .ready, .awaitingPermission: return true; default: return false }
    }

    // MARK: - Configured servers (from project + user config)

    /// The active TAB's own project wins whenever a tab is open — clicking a
    /// tab in the strip (V2AppState.activate(tabId:)) updates activeTabId but
    /// deliberately never touches selectedProjectCwd (that's the LEFT RAIL's
    /// own selection, set only by clicking a project there). Reading
    /// selectedProjectCwd first meant this panel kept showing whichever
    /// project was last clicked in the rail — completely unrelated to
    /// whichever tab you'd since switched to — e.g. open the rail's "munga"
    /// project once, then click between already-open "hubflo" and "munga"
    /// TABS, and the panel showed munga's servers under the hubflo tab and
    /// vice versa (user report, 2026-07-14: "really crazy"). selectedProjectCwd
    /// is only the right source when there's genuinely no active tab (the
    /// project-home screen — see selectProject's own activeTabId = nil).
    private var projectCwd: String? {
        appState.activeTab?.projectCwd ?? appState.selectedProjectCwd?.path
    }

    /// MCPs configured for this project — `<cwd>/.mcp.json` (team, "project"),
    /// `~/.claude.json projects.<cwd>` (private, "local"), and the top-level
    /// global servers that load everywhere. Deduped by name (project first).
    private var configuredServers: [MCPServer] {
        var out: [MCPServer] = []
        var seen = Set<String>()
        func add(_ list: [MCPServer]) { for s in list where seen.insert(s.name).inserted { out.append(s) } }
        if let cwd = projectCwd {
            add(store.projectMCPs[cwd] ?? [])
            add(store.localUserMCPs[cwd] ?? [])
        }
        add(store.standaloneMCPs)
        // Plugin-provided servers (e.g. the official Supabase plugin's
        // remote OAuth server) — previously invisible here, they only ever
        // appeared in the LIVE view once a session loaded them. Shown so
        // they're discoverable pre-session and so "→ project" can copy one
        // down as a project-scoped variant (the per-project OAuth pattern:
        // same remote URL + a binding param like ?project_ref=…, no tokens
        // on disk). Added last: a project/local/user entry of the same name
        // wins the dedupe, matching the project-first mental model.
        for (_, servers) in store.pluginMCPs.sorted(by: { $0.key < $1.key }) { add(servers) }
        return out
    }

    /// "→ project" copy-down applies to servers that live ABOVE the current
    /// project: user-scope and plugin-provided. Project/local entries are
    /// already project-bound.
    private func canCopyToProject(_ server: MCPServer) -> Bool {
        guard projectCwd != nil else { return false }
        return V2McpScopeTier.of(server.source) == .user
    }

    /// Same everywhere-vs-this-project split as configuredContent, applied
    /// to a LIVE session row. Resolves scope via the matching configured
    /// entry by name (same lookup serviceKey(live:) already does) — falls
    /// back to "user" (everywhere) when there's no local config match at all
    /// (e.g. a claude.ai connector, which is account-wide by nature, never
    /// project-scoped).
    private func scopeTier(live server: MCPServerInfo) -> V2McpScopeTier {
        guard let cfg = configuredServers.first(where: { $0.name == server.name }) else { return .user }
        return V2McpScopeTier.of(cfg.source)
    }

    /// The scope MCPConfigWriter needs to edit/delete this row. v1
    /// (ExtensionsView) gets this for free by iterating already-bucketed
    /// per-scope lists; v2's configuredServers flattens them, so it's
    /// reconstructed from `.source` — safe because configuredServers only
    /// ever draws .localUser/.project rows from THIS project's own
    /// dictionaries. nil for plugin-provided servers: nothing to edit or
    /// delete, they're baked into the plugin.
    private func scope(for server: MCPServer) -> MCPConfigWriter.Scope? {
        switch server.source {
        case .global: return .user
        case .localUser: return projectCwd.map { .local(cwd: $0) }
        case .project: return projectCwd.map { .project(cwd: $0) }
        case .plugin: return nil
        }
    }

    private var serverCount: Int {
        if let s = appState.activeSession, isRunning(s.state), !s.mcpServers.isEmpty { return s.mcpServers.count }
        return configuredServers.count
    }

    private var configuredContent: some View {
        let servers = configuredServers
        let project = servers.filter { V2McpScopeTier.of($0.source) == .project }
        let local = servers.filter { V2McpScopeTier.of($0.source) == .local }
        let user = servers.filter { V2McpScopeTier.of($0.source) == .user }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if servers.isEmpty {
                    Text("No MCP servers configured for this project.")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 18).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    // Three real scopes get three sections, not two — Project
                    // and Local used to share one "This project" header,
                    // distinguished only by a quiet subtext line, which
                    // silently flattened "checked in, shared with your team"
                    // and "private to you, nobody else sees this" into what
                    // read as one bucket (/lawsofux pass, 2026-07-14: Law of
                    // Prägnanz — two visual buckets forced an incorrect
                    // simplification of three real categories). Project and
                    // Local both lead, expanded — both are genuinely specific
                    // to the project you're looking at. User (every project on
                    // this Mac) is the one that behaves unexpectedly outside
                    // this project's boundary, so it stays a distinct,
                    // collapsed-by-default disclosure rather than blending in.
                    if !project.isEmpty {
                        scopeSectionHeader(.project)
                        serverGroupRows(project)
                    }
                    if !local.isEmpty {
                        scopeSectionHeader(.local)
                        serverGroupRows(local)
                    }
                    if !user.isEmpty {
                        everywhereDisclosure(user)
                    }
                }
                Text("Project → .mcp.json · Local → ~/.claude.json (this project) · User → ~/.claude.json (every project). Start a session to see live connection status.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(10.5 * 0.6)
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18).padding(.vertical, 14)
            }
            .padding(.vertical, 8)
        }
    }

    /// The outer "which world does this belong to" division — the service
    /// grouping (linear-garman/hubflo/khayalo as one "linear" header) nests
    /// INSIDE each of these, so the hierarchy reads scope → service →
    /// account, biggest distinction first. Title/subtitle come straight off
    /// V2McpScopeTier — same three words `claude mcp add --scope` uses.
    private func scopeSectionHeader(_ tier: V2McpScopeTier) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(tier.title.uppercased())
                .font(.system(size: 10, design: .monospaced))
                .kerning(1.2)
                .foregroundColor(v2.mute)
            Text(tier.subtitle)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "User" scope — collapsed by default so it doesn't compete with the
    /// project's own servers, but marked with a solid (not hollow) dot
    /// unique to this section: this is the one tier that reaches OUTSIDE
    /// the project you're looking at, so it gets a visually distinct marker
    /// rather than just fading into gray-and-collapsed (/lawsofux pass,
    /// 2026-07-14 — Von Restorff Effect: the scope that behaves
    /// unexpectedly is the one that most needs to be noticed, not the one
    /// that most needs to be hidden). A quiet, click-to-expand row rather
    /// than a native DisclosureGroup, matching the chip/mono language the
    /// rest of the panel uses.
    private func everywhereDisclosure(_ servers: [MCPServer]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showEverywhere.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showEverywhere ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(v2.faint)
                    Circle().fill(v2.mute).frame(width: 5, height: 5)
                    Text(V2McpScopeTier.user.title.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .kerning(1.2)
                        .foregroundColor(v2.mute)
                    Text("· \(servers.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, showEverywhere ? 8 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showEverywhere {
                Text("\(V2McpScopeTier.user.subtitle) \"→ project\" on any of these moves it into Local.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                serverGroupRows(servers)
            }
        }
    }

    private func serverGroupRows(_ servers: [MCPServer]) -> some View {
        let groups = Self.grouped(servers) { self.serviceKey(configured: $0) }
        return ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let label = group.label {
                serviceHeader(label, count: group.members.count)
                let labels = Self.memberLabels(group.members.map(\.name))
                ForEach(Array(group.members.enumerated()), id: \.element.id) { idx, server in
                    configuredRow(server, memberLabel: labels[idx], indented: true)
                }
            } else {
                ForEach(group.members, id: \.id) { configuredRow($0) }
            }
        }
    }

    private func configuredRow(_ server: MCPServer, memberLabel: String? = nil, indented: Bool = false) -> some View {
        let oauth = isOAuthCapable(server.transport)
        let needsAuth = oauth && store.mcpNeedsAuth.contains(server.name)
        let signedIn = oauth && !needsAuth   // OAuth-capable and NOT in needs-auth cache
        let isDeleting = deletingServers.contains(server.name)
        // The whole row is one tap target now — opens V2McpServerActionSheet
        // with every real action (sign in / use in project / edit / delete)
        // in one well-designed modal, instead of a single inline button that
        // could only ever show ONE action depending on state, plus a
        // right-click menu most people never discover (user feedback,
        // 2026-07-14: "why can't I just click and choose what I want to do
        // with it"). Right-click kept as a power-user shortcut to the same
        // actions — harmless overlap, not a second source of truth.
        return Button {
            actionSheetServer = server
        } label: {
            HStack(spacing: 11) {
                // Grouped members indent under their service header and show
                // just the differentiating suffix ("garman", not
                // "linear-garman") — the header already names the service.
                if indented {
                    Spacer().frame(width: 16)
                }
                // Brand glyph, dimmed when the server still needs sign-in.
                V2ServiceLogo(name: server.name,
                              host: V2ServiceLogo.host(of: server.transport),
                              size: indented ? 14 : 17,
                              tint: needsAuth ? v2.faint : v2.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(memberLabel ?? server.name)
                        .font(.system(size: 13.5, weight: .medium)).kerning(-0.13)
                        .lineLimit(1).truncationMode(.tail)
                    Text("\(scopeLabel(server.source)) · \(transportLabel(server.transport))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer()
                if isDeleting {
                    HStack(spacing: 6) {
                        V2PulseDot(size: 6, color: v2.mute)
                        Text("deleting…")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(v2.mute)
                    }
                } else {
                    // Passive status only now — every action that used to
                    // live here (connect →, → project, sign in) moved into
                    // the modal this row opens.
                    Text(needsAuth ? "needs auth" : (signedIn ? "signed in" : "configured"))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(needsAuth ? v2.del.opacity(0.75) : (signedIn ? v2.mute : v2.faint))
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(isDeleting ? 0.5 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDeleting)
        .contextMenu {
            if !isDeleting {
                if isSupabasePluginServer(server), projectCwd != nil {
                    Button("Connect & choose project…") { connectSupabaseWithPicker() }
                } else if canCopyToProject(server) {
                    Button("Use in this project…") { useInProjectServer = server }
                }
                // Re-auth escape hatch: the inline button only exists while the
                // needs-auth cache flags the server, but "switch account" /
                // "token expired but cache hasn't noticed" are real cases.
                if oauth {
                    Button("Sign in again…") { authenticate(server.name) }
                }
                if let scope = scope(for: server) {
                    Button("Edit…") { editingServer = (server, scope) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        pendingDelete = (name: server.name, scope: scope)
                    }
                }
            }
        }
    }

    private func isOAuthCapable(_ t: MCPServer.Transport) -> Bool {
        switch t { case .http, .sse: return true; default: return false }
    }

    // MARK: - Service grouping (same service × several accounts)

    /// Multiple entries for one service — linear-garman / linear-hubflo /
    /// linear-khayalo — are one service with several accounts, configured
    /// as separate servers because that's the only mechanism the config
    /// format has. Presentation-only grouping: config on disk is untouched.
    /// Keyed by URL host for http/sse (the multi-account pattern is remote
    /// auth'd services); stdio servers never group ("npx" as a key would
    /// lump unrelated servers together).
    private func serviceKey(configured server: MCPServer) -> String? {
        V2ServiceLogo.host(of: server.transport).map(Self.serviceLabel(fromHost:))
    }

    /// Live rows only carry name + status; resolve the service through the
    /// configured entry of the same name. claude.ai connectors (account-
    /// side, no local config) group under their shared prefix.
    private func serviceKey(live server: MCPServerInfo) -> String? {
        if server.name.hasPrefix("claude.ai ") { return "claude.ai" }
        guard let cfg = configuredServers.first(where: { $0.name == server.name }) else { return nil }
        return serviceKey(configured: cfg)
    }

    /// "mcp.linear.app" → "linear"; "mcp.supabase.com" → "supabase".
    private static func serviceLabel(fromHost host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return host }
        return String(parts[parts.count - 2])
    }

    /// Partition into display groups, preserving first-appearance order.
    /// label == nil ⇒ a single ungrouped server; label != nil ⇒ a service
    /// header + indented member rows.
    private static func grouped<T>(_ items: [T], key: (T) -> String?) -> [(label: String?, members: [T])] {
        let keyed = items.map { (key($0), $0) }
        var counts: [String: Int] = [:]
        for (k, _) in keyed { if let k { counts[k, default: 0] += 1 } }
        var out: [(label: String?, members: [T])] = []
        var emitted = Set<String>()
        for (k, item) in keyed {
            if let k, counts[k, default: 0] > 1 {
                if emitted.insert(k).inserted {
                    out.append((k, keyed.filter { $0.0 == k }.map { $0.1 }))
                }
            } else {
                out.append((nil, [item]))
            }
        }
        return out
    }

    /// Per-member short labels: strip the group's common name prefix down
    /// to a separator boundary ("linear-garman" → "garman", "claude.ai
    /// Gmail" → "Gmail"). Falls back to the full name if stripping would
    /// leave nothing.
    private static func memberLabels(_ names: [String]) -> [String] {
        guard names.count > 1 else { return names }
        var prefix = names[0]
        for n in names.dropFirst() {
            prefix = String(zip(prefix, n).prefix(while: { $0.0 == $0.1 }).map { $0.0 })
        }
        if let lastSep = prefix.lastIndex(where: { "-_:. ".contains($0) }) {
            prefix = String(prefix[...lastSep])
        } else {
            prefix = ""
        }
        let separators = CharacterSet(charactersIn: "-_:. ")
        return names.map { n in
            let stripped = String(n.dropFirst(prefix.count)).trimmingCharacters(in: separators)
            return stripped.isEmpty ? n : stripped
        }
    }

    private func serviceHeader(_ label: String, count: Int) -> some View {
        HStack(spacing: 11) {
            V2ServiceLogo(name: label, size: 17, tint: v2.ink)
            Text(label.capitalized)
                .font(.system(size: 13.5, weight: .medium)).kerning(-0.13)
            Text(count == 1 ? "1 account" : "\(count) accounts")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
        }
        .padding(.horizontal, 18).padding(.top, 13).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Authenticate (claude mcp login)

    /// Status banner under the header. On failure it offers an explicit
    /// "open a terminal" escape hatch (for a server that genuinely needs the
    /// manual paste flow) instead of forcing a terminal on every error — and a
    /// dismiss so a stale note doesn't linger.
    @ViewBuilder
    private func authBanner(_ note: String) -> some View {
        let failed = authFailedServer
        HStack(alignment: .top, spacing: 10) {
            Text(note)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(failed != nil ? v2.del : v2.mute)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let failed {
                Button {
                    appState.openMCPLogin(serverName: failed)
                    authNote = nil; authFailedServer = nil
                } label: {
                    Text("terminal")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Open `claude mcp login` in a terminal to finish by hand")
            }
            Button { authNote = nil; authFailedServer = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.faint)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .background(v2.card)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func authButton(_ name: String) -> some View {
        let busy = authing.contains(name)
        // While in flight the button cancels (so you're never stuck waiting for
        // a callback that isn't coming); otherwise it starts / retries sign-in.
        return Button { busy ? cancelAuth(name) : authenticate(name) } label: {
            Text(busy ? "cancel" : "sign in")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(busy ? v2.mute : v2.ink)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(v2.card)
                .overlay(Rectangle().stroke(busy ? v2.line2 : v2.ink, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(busy ? "Cancel sign-in" : "Sign in to this MCP server (OAuth in your browser)")
    }

    private func cancelAuth(_ name: String) {
        authHandles[name]?.cancel()
    }

    /// The official Supabase plugin's OWN row — the one whose real name is
    /// exactly what SupabaseProjectDiscovery reuses for credential sharing.
    /// "Connect & choose project…" only makes sense here, not on a
    /// hand-typed http server that merely happens to point at the same host
    /// (its name won't match, so the discovery call's sign-in bet doesn't
    /// apply to it).
    private func isSupabasePluginServer(_ server: MCPServer) -> Bool {
        if case .plugin = server.source { return server.name == "plugin:supabase:supabase" }
        return false
    }

    /// Sign in to the account-wide connection first (list_projects needs
    /// it), THEN open the picker — reuses authenticate(_:)'s whole flow
    /// (browser, banner, cancel, stale-registration self-heal) rather than
    /// duplicating it.
    private func connectSupabaseWithPicker() {
        // Checked up front — the picker sheet has no "binary missing" body
        // of its own, so without this guard a nil binary here would present
        // a blank sheet instead of an explanation.
        guard appState.claudeBinary != nil else {
            supabasePickerError = "Can't find the claude binary."
            return
        }
        guard store.mcpNeedsAuth.contains("plugin:supabase:supabase") else {
            showingSupabasePicker = true
            return
        }
        authenticate("plugin:supabase:supabase") { result in
            switch result {
            case .ok, .connectorPending:
                showingSupabasePicker = true
            case .cancelled:
                break   // authNote already explains it; no extra alert
            case .timedOut, .failed:
                supabasePickerError = "Sign-in didn't complete, so there's no account to list projects from yet. Try \"sign in\" again, then re-open the picker."
            }
        }
    }

    /// Auto-start OAuth sign-in right after a remote server is saved —
    /// adding is the intent to use, and without this the sign-in button
    /// doesn't even EXIST yet (it's gated on claude's needs-auth cache,
    /// which only learns about a server after a session has failed
    /// against it). Skipped when the config carries an auth-ish header:
    /// that server is token-authenticated and the browser dance would be
    /// wrong. The existing banner shows progress and offers cancel.
    private func maybeAutoSignIn(_ draft: MCPDraft) {
        switch draft.transport {
        case .http, .sse: break
        default: return
        }
        let headerAuthed = draft.headers.keys.contains { k in
            let lk = k.lowercased()
            return lk.contains("authorization") || lk.contains("token") || lk.contains("key")
        }
        guard !headerAuthed else { return }
        authenticate(draft.name)
    }

    /// `onComplete` lets a caller wait for the OUTCOME (not just fire-and-
    /// forget the UI banner) — the Supabase project picker needs to know
    /// sign-in actually succeeded before it's safe to call list_projects.
    private func authenticate(_ name: String, onComplete: ((V2MCPAuthResult) -> Void)? = nil) {
        guard let binary = appState.claudeBinary else {
            authNote = "Can't find the claude binary."
            onComplete?(.failed(output: "claude binary not found"))
            return
        }
        let cwd = projectCwd ?? NSHomeDirectory()
        // ALWAYS reset the CLI's cached OAuth state (`claude mcp logout`)
        // before signing in. Providers expire the DYNAMIC CLIENT REGISTRATION
        // the CLI caches per server; a stale one makes every sign-in open a
        // perfectly-formed authorize URL the provider rejects with
        // "Unrecognized client_id" — which we only ever see as a timeout,
        // because the error happens in the browser. Verified live against
        // Supabase: logout → fresh registration → provider accepts (303 to
        // the consent page). This is safe unconditionally: the sign-in button
        // only appears for servers ALREADY in the needs-auth state, so there
        // are never credentials worth keeping — and it makes the stale-
        // registration case self-heal on the FIRST click, not a retry.
        let handle = V2AuthHandle()
        authHandles[name] = handle
        authing.insert(name)
        authFailedServer = nil
        authNote = "\(name): opening your browser — authorise there, or cancel."
        Task {
            await V2MCPAuth.logout(claudeBinary: binary, name: name, cwd: cwd)
            let result = await V2MCPAuth.login(claudeBinary: binary, name: name, cwd: cwd, handle: handle)
            authing.remove(name)
            authHandles[name] = nil
            onComplete?(result)
            switch result {
            case .ok:
                // Refresh auth state from claude's own cache FIRST (cheap, sync,
                // and immune to load()'s in-progress guard) so the row flips from
                // "sign in" → "signed in" immediately.
                store.loadMCPNeedsAuth()
                await store.load()
                // Reconnect the live session so the server just appears, folded
                // into the session's normal loading state.
                let reconnected = appState.reconnectSessions(inProject: cwd, afterAuthOf: name)
                authFailedServer = nil
                authNote = reconnected > 0
                    ? "\(name): signed in ✓ — reconnecting your session…"
                    : "\(name): signed in ✓ — connected."
            case .connectorPending:
                // claude.ai connector: we opened the claude.ai authorization
                // page; the grant lands account-side and applies when the next
                // session starts. NOT a failure — don't paint it red.
                authFailedServer = nil
                authNote = "\(name): finish authorizing in the browser — it connects on your next session."
                store.loadMCPNeedsAuth()
                await store.load()
            case .cancelled:
                authFailedServer = nil
                authNote = "\(name): sign-in cancelled. Click “sign in” to try again."
            case .timedOut:
                authFailedServer = name
                authNote = "\(name): didn’t hear back — the browser may have shown an error. “sign in” to retry."
            case .failed(let output):
                authFailedServer = name
                let reason = output.isEmpty ? "sign-in failed" : String(output.suffix(140))
                authNote = "\(name): \(reason) — “sign in” to retry."
            }
        }
    }

    /// Plain-language row subtext — no "user"/"local"/"project" internals.
    /// The section header already carries the everywhere-vs-this-project
    /// split; this distinguishes WHY within that (private vs shared, or
    /// which plugin it came from).
    private func scopeLabel(_ s: MCPServer.Source) -> String {
        switch s {
        case .global:        return "all projects"
        case .localUser:     return "private to you"
        case .project:       return "shared with team"
        case .plugin(let n): return "plugin: \(n)"
        }
    }

    private func transportLabel(_ t: MCPServer.Transport) -> String {
        switch t {
        case .stdio(let cmd, _): return (cmd as NSString).lastPathComponent
        case .http:              return "http"
        case .sse:               return "sse"
        case .sdk:               return "sdk"
        case .unknown(let type): return type
        }
    }

    private var initializingState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                V2Spinner(size: 11)
                Text("Waiting for system/init…")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func liveContent(for session: StreamSession) -> some View {
        let servers = session.mcpServers
        let project = servers.filter { scopeTier(live: $0) == .project }
        let local = servers.filter { scopeTier(live: $0) == .local }
        let user = servers.filter { scopeTier(live: $0) == .user }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !project.isEmpty {
                    scopeSectionHeader(.project)
                    liveServerGroupRows(project)
                }
                if !local.isEmpty {
                    scopeSectionHeader(.local)
                    liveServerGroupRows(local)
                }
                if !user.isEmpty {
                    liveEverywhereDisclosure(user)
                }
                if session.mcpServers.isEmpty {
                    Text("No MCP servers loaded for this session.")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("Live status, refreshed every few seconds while this panel is open.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineSpacing(10.5 * 0.6)
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
            }
            .padding(.vertical, 8)
        }
        // Live-status poll (#mcp_status): system/init's statuses are a
        // one-time snapshot — a server that was still "pending" at spawn
        // showed "starting" forever, even long after it connected or
        // failed, because nothing ever asked again. Poll the mcp_status
        // control request at 5s while the panel is visible; cancels with
        // the view, re-arms on session swap via instanceId (never
        // ObjectIdentifier — the address-reuse bug).
        .task(id: session.instanceId) {
            while !Task.isCancelled {
                session.refreshMCPStatus()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    // MARK: - Row

    private func serverRow(_ server: MCPServerInfo, memberLabel: String? = nil, indented: Bool = false) -> some View {
        let status = (server.status ?? "unknown").lowercased()
        let isConnected = status == "connected" || status == "ready"
        let needsAuth = status == "needs-auth"
        let isFailed = status == "failed" || status == "error"

        return HStack(spacing: 11) {
            if indented {
                Spacer().frame(width: 16)
            }
            // Brand glyph tinted by live status: ink = connected, faint =
            // pending/needs-auth, red = failed.
            V2ServiceLogo(name: server.name, size: indented ? 14 : 17,
                          tint: isConnected ? v2.ink : (isFailed ? v2.del : v2.faint))

            VStack(alignment: .leading, spacing: 2) {
                Text(memberLabel ?? displayName(server.name))
                    .font(.system(size: 13.5, weight: .medium))
                    .kerning(-0.13)
                    .lineLimit(1).truncationMode(.tail)
                Text(scopeHint(server.name))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer()
            if needsAuth {
                authButton(server.name)
            } else {
                Text(statusLabel(status))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(statusColor(isConnected: isConnected, needsAuth: needsAuth, failed: isFailed))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(isFailed ? 0.55 : 1.0)
        .overlay(alignment: .bottom) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }

    /// Live-row equivalent of serverGroupRows — same service grouping,
    /// MCPServerInfo instead of MCPServer.
    private func liveServerGroupRows(_ servers: [MCPServerInfo]) -> some View {
        let groups = Self.grouped(servers) { self.serviceKey(live: $0) }
        return ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
            if let label = group.label {
                serviceHeader(label, count: group.members.count)
                let labels = Self.memberLabels(group.members.map(\.name))
                ForEach(Array(group.members.enumerated()), id: \.element.name) { idx, server in
                    serverRow(server, memberLabel: labels[idx], indented: true)
                }
            } else {
                ForEach(group.members, id: \.name) { serverRow($0) }
            }
        }
    }

    /// Live-row equivalent of everywhereDisclosure — same collapsed-by-
    /// default treatment, shares showEverywhere so expand/collapse feels
    /// consistent whichever view (static or live) you land on.
    private func liveEverywhereDisclosure(_ servers: [MCPServerInfo]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { showEverywhere.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: showEverywhere ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(v2.faint)
                    Circle().fill(v2.mute).frame(width: 5, height: 5)
                    Text(V2McpScopeTier.user.title.uppercased())
                        .font(.system(size: 10, design: .monospaced))
                        .kerning(1.2)
                        .foregroundColor(v2.mute)
                    Text("· \(servers.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, showEverywhere ? 8 : 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showEverywhere {
                Text("\(V2McpScopeTier.user.subtitle) Live in this session too.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 8)
                liveServerGroupRows(servers)
            }
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "connected", "ready":   return "on"
        case "pending":              return "starting"
        case "needs-auth":           return "needs auth"
        case "failed", "error":      return "failed"
        default:                     return status
        }
    }

    private func statusColor(isConnected: Bool, needsAuth: Bool, failed: Bool) -> Color {
        if failed       { return v2.del }
        if needsAuth    { return v2.del.opacity(0.75) }
        if isConnected  { return v2.mute }
        return v2.faint
    }

    /// MCP names from system/init can be raw ("filesystem") or qualified
    /// ("plugin:supabase:supabase", "claude.ai Gmail"). Show the human-readable
    /// suffix in the title and the prefix as scope hint.
    private func displayName(_ name: String) -> String {
        if let colonIdx = name.lastIndex(of: ":") {
            return String(name[name.index(after: colonIdx)...])
        }
        return name
    }

    private func scopeHint(_ name: String) -> String {
        if name.hasPrefix("plugin:") {
            let parts = name.split(separator: ":")
            if parts.count >= 2 { return "plugin: \(parts[1])" }
            return "plugin"
        }
        if name.contains(":") {
            let parts = name.split(separator: ":")
            return parts.dropLast().joined(separator: " · ")
        }
        return "all projects"
    }
}

// MARK: - MCP OAuth via `claude mcp login` (hidden PTY)

/// Outcome of an MCP sign-in attempt, so the UI can say exactly what happened
/// and offer the right next step (retry / cancel / manual terminal).
enum V2MCPAuthResult {
    case ok(output: String)        // process exited 0 — signed in
    case failed(output: String)    // process exited non-zero — real error
    case timedOut                  // no callback within the timeout (often a
                                   // browser-side error the loopback never saw)
    case cancelled                 // user cancelled
    case connectorPending          // claude.ai connector: auth completes ON
                                   // claude.ai (no loopback) and takes effect
                                   // on the next session start — the CLI never
                                   // exits, so hitting the timeout is NOT an
                                   // error for this flow.
}

/// Cancellable handle for an in-flight sign-in. The panel holds one per server
/// so a Cancel button can terminate the underlying process; the login reader
/// then hits EOF and returns `.cancelled`.
final class V2AuthHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private(set) var wasCancelled = false

    /// Register the spawned process. Returns false if cancel already fired, so
    /// the caller can tear the just-spawned process down immediately.
    func attach(_ p: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if wasCancelled { return false }
        process = p
        return true
    }

    func cancel() {
        lock.lock(); let p = process; wasCancelled = true; lock.unlock()
        p?.terminate()
    }
}

enum V2MCPAuth {
    /// `claude mcp logout <name>` — clears the CLI's stored OAuth credentials
    /// AND its cached dynamic client registration for the server. Fast, no
    /// TTY needed; failures are ignored (nothing to clear is fine).
    static func logout(claudeBinary: URL, name: String, cwd: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = claudeBinary
                p.arguments = ["mcp", "logout", name]
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE") { env.removeValue(forKey: k) }
                p.environment = env
                p.standardOutput = Pipe(); p.standardError = Pipe()
                guard (try? p.run()) != nil else { cont.resume(); return }
                // Bounded wait — logout is instant; never let it wedge the UI.
                let deadline = Date().addingTimeInterval(10)
                while p.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
                if p.isRunning { p.terminate() }
                cont.resume()
            }
        }
    }

    /// Run `claude mcp login <name> --no-browser` attached to a HIDDEN
    /// pseudo-terminal — the CLI's TTY check passes, but nothing is rendered.
    /// We parse the authorization URL it prints and open the browser ourselves;
    /// the CLI's localhost loopback captures the callback and the process exits
    /// 0 on success. No paste, no visible terminal. Capped by `timeout`, and
    /// cancellable via `handle`.
    static func login(claudeBinary: URL, name: String, cwd: String, handle: V2AuthHandle, timeout: TimeInterval = 180) async -> V2MCPAuthResult {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                var master: Int32 = 0, slave: Int32 = 0
                // Allocate the PTY VERY WIDE. With a default (~80-col) window the
                // CLI wraps long OAuth authorize URLs — the ones carrying a full
                // scope list + PKCE challenge (Linear, Notion, Supabase, …) — by
                // inserting a newline mid-URL. extractAuthURL then reads only up
                // to that wrap and opens a truncated link, which the provider
                // rejects with "Unrecognized client_id". Short-URL servers fit
                // and worked, which is why it only hit *some* MCPs. A 4096-col
                // window guarantees the URL prints on one unbroken line.
                var winp = winsize(ws_row: 60, ws_col: 4096, ws_xpixel: 0, ws_ypixel: 0)
                guard openpty(&master, &slave, nil, nil, &winp) == 0 else {
                    cont.resume(returning: .failed(output: "couldn't allocate a terminal")); return
                }
                let p = Process()
                p.executableURL = claudeBinary
                p.arguments = ["mcp", "login", name, "--no-browser"]
                p.currentDirectoryURL = URL(fileURLWithPath: cwd)
                var env = ProcessInfo.processInfo.environment
                for k in env.keys where k == "CLAUDECODE" || k.hasPrefix("CLAUDE_CODE") { env.removeValue(forKey: k) }
                env["TERM"] = "xterm-256color"
                p.environment = env
                let slaveFH = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
                p.standardInput = slaveFH
                p.standardOutput = slaveFH
                p.standardError = slaveFH
                do { try p.run() } catch {
                    close(master); close(slave)
                    cont.resume(returning: .failed(output: "couldn't launch claude")); return
                }
                close(slave)   // child owns it; closing here lets master EOF on exit
                // If the user already hit Cancel before we got here, don't leave
                // an orphan running.
                guard handle.attach(p) else {
                    p.terminate(); p.waitUntilExit(); close(master)
                    cont.resume(returning: .cancelled); return
                }
                let masterFH = FileHandle(fileDescriptor: master, closeOnDealloc: false)

                let group = DispatchGroup()
                var outData = Data()
                var openedURL = false
                // Two flows `claude mcp login` has that DON'T end in a clean
                // exit — detected from output markers (verified against CLI
                // 2.1.199):
                // • claude.ai connectors: auth completes on claude.ai, no
                //   loopback, CLI prints "Once authorized on claude.ai …" and
                //   waits forever → reaching the timeout is expected, not an
                //   error.
                // • unknown server name: CLI prints "No MCP server named …"
                //   and then HANGS instead of exiting → fail fast with the
                //   real message instead of a 3-minute generic timeout.
                var isConnectorFlow = false
                var earlyFailure: String?
                group.enter()
                DispatchQueue.global().async {
                    var buffer = ""
                    while true {
                        let chunk = masterFH.availableData
                        if chunk.isEmpty { break }            // EOF — child closed slave
                        outData.append(chunk)
                        if let s = String(data: chunk, encoding: .utf8) {
                            buffer += s
                            if buffer.contains("Once authorized on claude.ai") {
                                isConnectorFlow = true
                            }
                            if earlyFailure == nil, buffer.contains("No MCP server named") {
                                earlyFailure = stripANSI(buffer)
                                    .trimmingCharacters(in: .whitespacesAndNewlines)
                                p.terminate()   // reader loop ends via EOF
                            }
                        }
                        if !openedURL, !buffer.isEmpty {
                            // Only extract from COMPLETE lines (up to the last
                            // newline). The auth URL streams over the PTY and can
                            // arrive split across reads — matching the partial
                            // buffer would open a half-formed URL with a truncated
                            // client_id, which the provider rejects with
                            // "Unrecognized client_id". A newline after the URL
                            // proves it's whole.
                            //
                            // NB: the CLI emits CRLF, and Swift treats "\r\n" as a
                            // SINGLE Character that is != "\n" and != "\r" — so we
                            // must test the Character's scalars, not the Character
                            // itself, or no line ending is ever found.
                            guard let lastNL = buffer.lastIndex(where: { $0.unicodeScalars.contains { $0 == "\n" || $0 == "\r" } }) else { continue }
                            let complete = stripANSI(String(buffer[..<lastNL]))
                            if let url = extractAuthURL(complete) {
                                openedURL = true
                                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
                            }
                        }
                    }
                    group.leave()
                }
                var timedOut = false
                var connectorHandoff = false
                let deadline = Date().addingTimeInterval(timeout)
                while group.wait(timeout: .now() + 1) == .timedOut {
                    // Connector flow: the CLI never exits — once the claude.ai
                    // page is open there is nothing to wait for locally. Give
                    // the reader a few seconds to settle, then hand off.
                    if isConnectorFlow && openedURL {
                        Thread.sleep(forTimeInterval: 2)
                        connectorHandoff = true
                        break
                    }
                    if Date() >= deadline { timedOut = true; break }
                }
                if timedOut || connectorHandoff {
                    p.terminate()
                    group.wait()
                }
                p.waitUntilExit()
                close(master)
                let clean = stripANSI(String(data: outData, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if handle.wasCancelled      { cont.resume(returning: .cancelled) }
                else if let msg = earlyFailure { cont.resume(returning: .failed(output: msg)) }
                else if connectorHandoff || (timedOut && isConnectorFlow) {
                    cont.resume(returning: .connectorPending)
                }
                else if timedOut            { cont.resume(returning: .timedOut) }
                else if p.terminationStatus == 0 { cont.resume(returning: .ok(output: clean)) }
                else                        { cont.resume(returning: .failed(output: clean)) }
            }
        }
    }

    private static func extractAuthURL(_ s: String) -> URL? {
        // Pull every https URL out of the (possibly prefixed/wrapped) output and
        // pick the OAuth one. Matches "Open this URL: https://…/authorize?…".
        guard let re = try? NSRegularExpression(pattern: "https://[^\\s\"'<>]+") else { return nil }
        let ns = s as NSString
        let matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for m in matches {
            let str = ns.substring(with: m.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,)]"))
            let lower = str.lowercased()
            // "start-auth": claude.ai connector URLs
            // (…/mcp/start-auth/mcpsrv_…) match none of the classic OAuth
            // markers — without it, connector sign-ins never opened a browser.
            if lower.contains("authorize") || lower.contains("oauth")
                || lower.contains("/auth") || lower.contains("start-auth"),
               let u = URL(string: str) {
                return u
            }
        }
        return nil
    }

    private static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
