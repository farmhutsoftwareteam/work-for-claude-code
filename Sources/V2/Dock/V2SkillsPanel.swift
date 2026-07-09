// Skills dock panel (#61) — implements the dock surface from
// "Skills management.dc.html". Reads Store's already-populated
// standaloneSkills/projectSkills/pluginSkills (loadExtensions() does the
// real disk parsing; this panel adds no new discovery logic) and wires row
// actions straight to SkillOperations — no intermediate state to drift from
// what's actually on disk.

import SwiftUI
import Inject

struct V2SkillsPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @EnvironmentObject private var store: Store

    @State private var expandedPlugins: Set<String> = []
    @State private var editing: EditTarget?
    @State private var showingMarketplace = false
    @State private var justCleanedUp: Int?
    struct UpdateDiffTarget: Identifiable {
        let skill: ClaudeSkill
        let newContent: String
        var id: String { skill.id }
    }
    @State private var showingUpdateDiff: UpdateDiffTarget?

    /// skill id -> the plugin's current SKILL.md content, ONLY when it
    /// differs from what's on disk locally. Populated lazily per row (file
    /// reads, kept out of body — same discipline as Store's firstPrompt/slug
    /// lazy loaders) and only for skills carrying an Atelier clone-provenance
    /// marker, so a coincidental name match never falsely flags an update.
    @State private var updatesAvailable: [String: String] = [:]

    /// Skill id → its real trash round-trip info, kept only while the undo
    /// strip is showing. The delete already happened (real Trash move) the
    /// moment the row shows this — reload() is deliberately deferred until
    /// the undo window closes, so the row (and the undo option) stays valid.
    @State private var pendingDeletes: [String: (skill: ClaudeSkill, originalPath: URL, trashedAt: URL)] = [:]

    enum EditTarget: Identifiable {
        case new
        case edit(ClaudeSkill)
        var id: String {
            switch self {
            case .new: return "new"
            case .edit(let s): return "edit-\(s.id)"
            }
        }
    }

    private var projectCwd: String? { appState.activeTab?.projectCwd }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if personalSkills.isEmpty && (projectSkills?.isEmpty ?? true) && store.pluginSkills.isEmpty {
                        emptyState
                    } else {
                        if !duplicateArchives.isEmpty { duplicateBanner }
                        section(title: "personal · \(personalSkills.count)", skills: personalSkills, badge: "personal")
                        if let projectSkills, !projectSkills.isEmpty {
                            section(
                                title: "project · \(projectName) · \(projectSkills.count)",
                                skills: projectSkills, badge: "project", topRule: true
                            )
                        }
                        ForEach(enabledPluginSkillKeys, id: \.self) { pluginId in
                            pluginSection(pluginId: pluginId, skills: store.pluginSkills[pluginId] ?? [])
                        }
                    }
                }
            }
            footer
        }
        .background(v2.paper2)
        .sheet(item: $editing) { target in
            switch target {
            case .new:
                V2SkillEditorSheet(mode: .new, onSaved: { reload() })
            case .edit(let skill):
                V2SkillEditorSheet(mode: .edit(skill), onSaved: { reload() })
            }
        }
        .sheet(isPresented: $showingMarketplace) {
            V2SkillsMarketplaceSheet(onInstalled: { reload() })
        }
        .sheet(item: $showingUpdateDiff) { target in
            V2SkillUpdateDiffSheet(
                skill: target.skill,
                newContent: target.newContent,
                onApplied: {
                    updatesAvailable[target.skill.id] = nil
                    reload()
                }
            )
        }
        .enableInjection()
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Skills")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            Spacer()
            Button { editing = .new } label: {
                Text("+ new")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Create a new skill — by hand or let Claude draft it from a description")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No skills found.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Drop a folder with SKILL.md into ~/.claude/skills/, or click + new above.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
        }
        .padding(18)
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(title: String, skills: [ClaudeSkill], badge: String, topRule: Bool = false) -> some View {
        Text(title)
            .font(.system(size: 9.5, design: .monospaced))
            .kerning(1.0)
            .foregroundColor(v2.faint)
            .padding(.horizontal, 18)
            .padding(.top, topRule ? 14 : 12)
            .padding(.bottom, 4)
            .overlay(alignment: .top) {
                if topRule { Rectangle().fill(v2.line).frame(height: 1) }
            }
        ForEach(skills) { skill in
            row(skill, badge: badge, pluginId: nil, indent: false)
        }
    }

    private func pluginSection(pluginId: String, skills: [ClaudeSkill]) -> some View {
        // pluginId is "name@marketplace" (ClaudePlugin.id shape) — show just
        // the name, keep the full id for the expand-state key.
        let displayName = pluginId.split(separator: "@").first.map(String.init) ?? pluginId
        let expanded = expandedPlugins.contains(pluginId)
        return VStack(spacing: 0) {
            Button {
                if expanded { expandedPlugins.remove(pluginId) } else { expandedPlugins.insert(pluginId) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(v2.mute)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    Text("plugin · \(displayName) · \(skills.count)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .kerning(1.0)
                        .foregroundColor(v2.faint)
                    Spacer()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }

            if expanded {
                ForEach(skills) { skill in
                    row(skill, badge: displayName, pluginId: pluginId, indent: true)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ skill: ClaudeSkill, badge: String, pluginId: String?, indent: Bool) -> some View {
        let disabled = skill.disableModelInvocation
        let confirming = pendingDeletes[skill.id] != nil
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Circle()
                    .fill(disabled ? Color.clear : v2.add)
                    .overlay(Circle().stroke(disabled ? v2.line2 : Color.clear, lineWidth: 1))
                    .frame(width: 7, height: 7)
                    .padding(.top, 5)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 7) {
                        Text(skill.name)
                            .font(.system(size: indent ? 13 : 13.5, weight: .medium))
                            .kerning(-0.13)
                            .foregroundColor(disabled ? v2.faint : v2.ink)
                        if disabled {
                            Text("disabled")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(v2.faint)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        }
                        if let newContent = updatesAvailable[skill.id] {
                            Button { showingUpdateDiff = UpdateDiffTarget(skill: skill, newContent: newContent) } label: {
                                Text("update available")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(v2.add)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .overlay(Rectangle().stroke(v2.add, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text(skill.skillDescription)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(badge)
                    .font(.system(size: 9, design: .monospaced))
                    .kerning(0.5)
                    .foregroundColor(v2.mute)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .padding(.horizontal, 18)
            .padding(.leading, indent ? 12 : 0)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .onTapGesture { editing = .edit(skill) }
            .overlay(alignment: .trailing) { rowActions(skill, pluginId: pluginId, disabled: disabled) }
            .task(id: skill.id) { await checkForUpdate(skill) }

            if confirming {
                HStack(spacing: 10) {
                    Text("moved “\(skill.name)” to Trash")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.del)
                    Spacer()
                    Button("undo") { undoDelete(skill) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .underline()
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(v2.delBg)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
            }
        }
        .background(RowHover(v2: v2))
    }

    private func rowActions(_ skill: ClaudeSkill, pluginId: String?, disabled: Bool) -> some View {
        HStack(spacing: 3) {
            actionButton("pencil", help: "Edit") { editing = .edit(skill) }
            actionButton(disabled ? "power" : "power", help: disabled ? "Enable" : "Disable") {
                toggleDisabled(skill)
            }
            if case .plugin = skill.source {
                actionButton("doc.on.doc", help: "Clone to personal") { clone(skill, pluginId: pluginId) }
            }
            actionButton("trash", help: "Delete") { delete(skill) }
        }
        .padding(.trailing, 14)
        .opacity(0)   // shown via .rowHover below (hover-reveal, matches design's opacity:var(--rowshow,0))
        .modifier(RevealOnHover())
    }

    private func actionButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(v2.mute)
                .frame(width: 22, height: 22)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Footer

    private var footer: some View {
        let enabledKeys = enabledPluginSkillKeys
        let total = personalSkills.count + (projectSkills?.count ?? 0)
            + enabledKeys.reduce(0) { $0 + (store.pluginSkills[$1]?.count ?? 0) }
        let sources = 1 + (projectSkills?.isEmpty == false ? 1 : 0) + enabledKeys.count
        return HStack(spacing: 10) {
            Text("\(total) skills across \(max(sources, 1)) source\(sources == 1 ? "" : "s")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
            Button { showingMarketplace = true } label: {
                Text("browse marketplace →")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Data

    /// store.pluginSkills includes EVERY registered plugin's skills — even
    /// ones the user never enabled/installed (parsePlugins scans every
    /// marketplace-registered plugin directory unconditionally). The dock
    /// only lists what's actually active; browsing the rest for install is
    /// the Marketplace sheet's job.
    private var enabledPluginSkillKeys: [String] {
        let enabled = Set(store.plugins.filter(\.isEnabled).map(\.id))
        return store.pluginSkills.keys.filter { enabled.contains($0) }.sorted()
    }

    /// The redundant .skill archives dedupedByPackaging drops from the list —
    /// surfaced here so there's a real cleanup action, not just a display-
    /// layer hide. Confirmed present on the reference machine (lead-eng/ +
    /// lead-eng.skill both on disk for the same logical skill).
    private var duplicateArchives: [ClaudeSkill] {
        var byName: [String: [ClaudeSkill]] = [:]
        for skill in store.standaloneSkills { byName[skill.name, default: []].append(skill) }
        return byName.values
            .filter { $0.contains { $0.packaging == .directory } && $0.contains { $0.packaging == .zipArchive } }
            .compactMap { $0.first { $0.packaging == .zipArchive } }
    }

    private var duplicateBanner: some View {
        HStack(spacing: 10) {
            if let justCleanedUp {
                Text("cleaned up \(justCleanedUp) ✓")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.add)
            } else {
                Text("\(duplicateArchives.count) skill\(duplicateArchives.count == 1 ? "" : "s") installed twice (a live copy + its old .skill archive)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            Spacer()
            if justCleanedUp == nil {
                Button("clean up") { cleanUpDuplicates() }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .underline()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(v2.card)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    /// Real, direct trash (not routed through the per-row delete+undo
    /// mechanism — these archives never render as their own row, so that
    /// undo strip would never be visible). Reloads IMMEDIATELY instead of
    /// the per-row action's 5s-deferred reload: the previous version left
    /// the banner and "clean up" button showing unchanged for up to 5
    /// seconds after the files were already gone, with zero indication
    /// anything happened — reads as "the button doesn't work" even though
    /// the deletion genuinely succeeded. A visible "cleaned up ✓" beat,
    /// then the banner disappearing once data refreshes, replaces that
    /// silence with real confirmation.
    private func cleanUpDuplicates() {
        let targets = duplicateArchives
        for archive in targets { _ = try? SkillOperations.deleteSkill(archive) }
        justCleanedUp = targets.count
        reload()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            justCleanedUp = nil
        }
    }

    private var personalSkills: [ClaudeSkill] { dedupedByPackaging(store.standaloneSkills) }
    private var projectSkills: [ClaudeSkill]? {
        guard let cwd = projectCwd else { return nil }
        return store.projectSkills[cwd].map(dedupedByPackaging)
    }
    private var projectName: String {
        projectCwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "project"
    }

    /// A skill can exist as both a live directory and its packaging archive
    /// (e.g. lead-eng/ + lead-eng.skill) — confirmed on real disk data during
    /// the epic's research. Dedupe by name, preferring the editable directory.
    private func dedupedByPackaging(_ skills: [ClaudeSkill]) -> [ClaudeSkill] {
        var byName: [String: ClaudeSkill] = [:]
        for skill in skills {
            if let existing = byName[skill.name] {
                if existing.packaging == .zipArchive && skill.packaging == .directory {
                    byName[skill.name] = skill
                }
            } else {
                byName[skill.name] = skill
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    // MARK: - Actions

    private func reload() {
        Task { await store.loadExtensions() }
    }

    private func toggleDisabled(_ skill: ClaudeSkill) {
        try? SkillOperations.setDisableModelInvocation(!skill.disableModelInvocation, for: skill)
        reload()
    }

    private func clone(_ skill: ClaudeSkill, pluginId: String?) {
        _ = try? SkillOperations.cloneToPersonal(skill, pluginId: pluginId)
        reload()
    }

    /// Lazy, per-row update check: only runs for skills carrying an Atelier
    /// clone-provenance marker (never a coincidental name match), reads two
    /// small files, and only publishes when the content genuinely differs.
    private func checkForUpdate(_ skill: ClaudeSkill) async {
        guard case .standalone = skill.source else { return }   // only ever the personal copy
        guard let provenance = SkillOperations.cloneProvenance(for: skill) else { return }
        guard let currentUpstream = store.pluginSkills[provenance.pluginId]?.first(where: { $0.name == provenance.skillName })
        else { return }   // plugin no longer registered/enabled, or skill renamed upstream — nothing to compare
        guard let mine = try? String(contentsOf: skill.path.appendingPathComponent("SKILL.md"), encoding: .utf8),
              let theirs = try? String(contentsOf: currentUpstream.path.appendingPathComponent("SKILL.md"), encoding: .utf8)
        else { return }
        if mine != theirs {
            updatesAvailable[skill.id] = theirs
        } else {
            updatesAvailable[skill.id] = nil
        }
    }

    /// Moves the skill to Trash immediately (real operation, matches the
    /// convention everywhere else in this app), but does NOT reload the
    /// panel right away — the row stays put, showing the undo strip, until
    /// the window closes on its own. Reloading immediately would make undo
    /// meaningless: the row it applies to would already be gone.
    private func delete(_ skill: ClaudeSkill) {
        guard let result = try? SkillOperations.deleteSkill(skill) else { return }
        pendingDeletes[skill.id] = (skill, result.originalPath, result.trashedAt)
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard pendingDeletes[skill.id] != nil else { return }   // already undone
            pendingDeletes[skill.id] = nil
            reload()
        }
    }

    private func undoDelete(_ skill: ClaudeSkill) {
        guard let pending = pendingDeletes[skill.id] else { return }
        try? SkillOperations.restoreFromTrash(originalPath: pending.originalPath, trashedAt: pending.trashedAt)
        pendingDeletes[skill.id] = nil
    }
}

/// Row-hover background — a plain overlay color shift on hover, matching
/// the design's `style-hover` convention used elsewhere in the app.
private struct RowHover: View {
    let v2: V2Palette
    @State private var hover = false
    var body: some View {
        Rectangle()
            .fill(hover ? v2.card.opacity(0.6) : Color.clear)
            .onHover { hover = $0 }
    }
}

/// Reveals its content only on hover of the enclosing row — used for the
/// row action buttons, which should stay hidden at rest (design: opacity 0
/// → 1 on row hover) without needing per-button hover state.
private struct RevealOnHover: ViewModifier {
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .opacity(hover ? 1 : 0)
            .background(HoverCatcher(hover: $hover))
    }
}

private struct HoverCatcher: NSViewRepresentable {
    @Binding var hover: Bool
    func makeNSView(context: Context) -> NSView {
        let v = TrackingView()
        v.onHover = { hover = $0 }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class TrackingView: NSView {
        var onHover: (Bool) -> Void = { _ in }
        private var area: NSTrackingArea?
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let area { removeTrackingArea(area) }
            let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(a)
            area = a
        }
        override func mouseEntered(with event: NSEvent) { onHover(true) }
        override func mouseExited(with event: NSEvent) { onHover(false) }
    }
}
