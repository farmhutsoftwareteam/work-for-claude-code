// Skill marketplace browsing (#64) — the "Skill Packs" discovery surface (#11).
// Leads with a curated featured-packs section driven by the `claude plugin` CLI:
// packs install as plugins (auto-enabled at user scope) and stay updatable.
//
// The add flow is a real state machine — adding → installing → done/failed —
// with the marketplace resolved by REPO, not a guessed name (the earlier bug:
// a wrong name matched nothing, installed nothing, and the button silently
// reverted with no success or error). Zero resolvable plugins now throws a
// visible error instead of a silent no-op.
//
// Below the featured section, the original per-skill sources remain: install a
// single skill from a registered marketplace (cloneToPersonal), or add a whole
// pack / single skill from a repo.

import SwiftUI
import Inject

private enum PackPhase: Equatable {
    case idle
    case adding        // registering the marketplace
    case installing    // installing + enabling the pack's plugins
    case failed(String)
}

struct V2SkillsMarketplaceSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState

    var onInstalled: () -> Void

    @State private var installedFlash: Set<String> = []
    @State private var showingAddFromRepo = false

    // Featured-packs state
    @State private var registered: [Marketplace] = []          // MarketplaceLoader.loadAll() — offered plugins + header count
    @State private var marketplaceNameByRepo: [String: String] = [:]  // repo → real registered name (from CLI --json)
    @State private var phase: [String: PackPhase] = [:]        // pack.id → phase
    @State private var expandedPacks: Set<String> = []
    @State private var actionError: String?
    @State private var reloadNote: String?
    @State private var addPackField = ""
    @State private var addingPack = false

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    featuredSection
                    pluginMarketplaceSection
                    communitySection
                }
                .padding(.bottom, 20)
            }
            if reloadNote != nil { reloadNoteBar }
        }
        .frame(width: 860, height: 640)
        .background(v2.paper2)
        .task { await reloadRegistered() }
        .sheet(isPresented: $showingAddFromRepo) {
            V2AddSkillFromRepoSheet(onInstalled: onInstalled)
        }
        .alert("Couldn't complete that action", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(actionError ?? "")
        }
        .enableInjection()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Skill Packs")
                .font(.system(size: 15.5, weight: .medium))
                .kerning(-0.15)
            Text("\(totalMarketSkills) skills across \(registered.count) marketplace\(registered.count == 1 ? "" : "s")")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(v2.mute)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Featured packs

    private var featuredSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("featured packs", icon: "sparkles")
            essentialsHero
            ForEach(SkillPack.catalog) { packCard($0) }
        }
        .padding(.top, 20)
        .padding(.bottom, 26)
    }

    private var essentialsBusy: Bool {
        SkillPack.essentials.contains { isBusy($0) }
    }

    private var essentialsHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Set up the essentials")
                        .font(.system(size: 15, weight: .medium))
                        .kerning(-0.15)
                    Text("Add the recommended packs — \(SkillPack.essentials.map(\.title).joined(separator: ", ")) — in one click. Skills stay updatable through Claude.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if essentialsBusy {
                    progressChip("setting up…")
                } else {
                    V2ChipButton(label: "set up essentials", prominent: true) { setUpEssentials() }
                }
            }
            Text("Skills can run tools and read files in your projects. Review a pack before enabling it.")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(16)
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .padding(.horizontal, 26)
    }

    private func packCard(_ pack: SkillPack) -> some View {
        let plugins = packPlugins(pack)
        let installedCount = plugins.count
        let enabledCount = plugins.filter(\.isEnabled).count
        let expanded = expandedPacks.contains(pack.id)
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(pack.title)
                            .font(.system(size: 13.5, weight: .medium))
                            .kerning(-0.13)
                        badgeChip(pack.badge)
                        if let license = pack.license {
                            Text(license)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(v2.mute)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        }
                    }
                    Text(pack.blurb)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    statusLine(pack, installedCount: installedCount, enabledCount: enabledCount)
                }
                Spacer(minLength: 8)
                packControl(pack, installedCount: installedCount, enabledCount: enabledCount)
            }
            .padding(14)
            .contentShape(Rectangle())
            .onTapGesture { toggleExpand(pack) }

            if expanded { previewList(pack) }
        }
        .background(v2.card)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        .padding(.horizontal, 26)
        .padding(.bottom, 10)
    }

    private func badgeChip(_ badge: SkillPack.Badge) -> some View {
        let color: Color
        switch badge {
        case .verified:  color = v2.add
        case .official:  color = v2.claude
        case .community: color = v2.mute
        }
        return Text(badge.rawValue)
            .font(.system(size: 9, design: .monospaced))
            .kerning(0.5)
            .foregroundColor(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Rectangle().stroke(color.opacity(0.6), lineWidth: 1))
    }

    /// The status line under the blurb: an error message when the last add
    /// failed, an enabled/update state when installed, otherwise a teaser.
    @ViewBuilder
    private func statusLine(_ pack: SkillPack, installedCount: Int, enabledCount: Int) -> some View {
        if case .failed(let msg) = phase[pack.id] {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 9)).foregroundColor(v2.del)
                Text(msg)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundColor(v2.del)
                    .lineLimit(2)
            }
        } else if enabledCount > 0 {
            HStack(spacing: 8) {
                Circle().fill(v2.add).frame(width: 6, height: 6)
                Text("enabled")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(v2.add)
                Text("·").font(.system(size: 9, design: .monospaced)).foregroundColor(v2.faint)
                Text(pack.autoUpdatesByDefault ? "auto-updates on" : "updates: manual")
                    .font(.system(size: 9, design: .monospaced)).foregroundColor(v2.mute)
                if !pack.autoUpdatesByDefault, !isBusy(pack) {
                    Button { checkUpdates(pack) } label: {
                        Text("check for updates")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(v2.ink).underline()
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            Text(pack.skillCount > 0 ? "~\(pack.skillCount) skills · \(pack.publisher)" : "by \(pack.publisher)")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(v2.mute)
        }
    }

    /// The primary control on the right: a live spinner while working, a
    /// "try again" on failure, or add/enable/enabled from the real state.
    @ViewBuilder
    private func packControl(_ pack: SkillPack, installedCount: Int, enabledCount: Int) -> some View {
        switch phase[pack.id] ?? .idle {
        case .adding:
            progressChip("adding…")
        case .installing:
            progressChip("installing…")
        case .failed:
            V2ChipButton(label: "try again", prominent: true) { triggerAdd(pack) }
        case .idle:
            let fullyEnabled = installedCount > 0 && enabledCount == installedCount
            if fullyEnabled {
                Text("enabled ✓")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.add)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .overlay(Rectangle().stroke(v2.add.opacity(0.6), lineWidth: 1))
            } else if installedCount > 0 {
                V2ChipButton(label: "enable", prominent: true) { triggerAdd(pack) }
            } else {
                V2ChipButton(label: "add pack", prominent: true) { triggerAdd(pack) }
            }
        }
    }

    private func progressChip(_ label: String) -> some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(label)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }

    @ViewBuilder
    private func previewList(_ pack: SkillPack) -> some View {
        let items = pack.previewSkills.isEmpty ? livePreview(pack) : pack.previewSkills
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(v2.line).frame(height: 1)
            if items.isEmpty {
                Text("Add the pack to see its skills and commands.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(14)
            } else {
                Text("type the command to run a skill — or let the agent pick it automatically when it fits")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 4)
                ForEach(items) { skill in
                    HStack(spacing: 9) {
                        Text(skill.command)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(v2.del)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .overlay(Rectangle().stroke(v2.del.opacity(0.5), lineWidth: 1))
                        Text(skill.title)
                            .font(.system(size: 11))
                            .foregroundColor(v2.ink)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 5)
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Plugin marketplace section (per-skill clone — unchanged behavior)

    private var pluginMarketplaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("all registered marketplaces · \(totalMarketSkills) skills", icon: "powerplug")
            if marketplaceRows.isEmpty {
                Text("No marketplaces registered yet — add a featured pack above, or paste a repo below.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .padding(.horizontal, 26)
            } else {
                VStack(spacing: 0) {
                    ForEach(marketplaceRows, id: \.skill.id) { entry in
                        marketplaceRow(entry)
                        if entry.skill.id != marketplaceRows.last?.skill.id {
                            Rectangle().fill(v2.line).frame(height: 1)
                        }
                    }
                }
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                .padding(.horizontal, 26)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 26)
    }

    private func marketplaceRow(_ entry: (pluginId: String, skill: ClaudeSkill)) -> some View {
        let displayPlugin = entry.pluginId.split(separator: "@").first.map(String.init) ?? entry.pluginId
        let alreadyPersonal = store.standaloneSkills.contains { $0.name == entry.skill.name }
        let justInstalled = installedFlash.contains(entry.skill.id)
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(entry.skill.name)
                        .font(.system(size: 13.5, weight: .medium))
                        .kerning(-0.13)
                    Text(displayPlugin)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Text(entry.skill.skillDescription)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                do {
                    _ = try SkillOperations.cloneToPersonal(entry.skill, pluginId: entry.pluginId)
                    installedFlash.insert(entry.skill.id)
                    onInstalled()
                } catch {
                    actionError = error.localizedDescription
                }
            } label: {
                Text(justInstalled ? "installed ✓" : (alreadyPersonal ? "reinstall" : "install"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(v2.paper2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(justInstalled)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: - Community section (add a pack, or a single skill, from a repo)

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("add from a repo", icon: "point.3.connected.trianglepath.dotted")

            VStack(alignment: .leading, spacing: 10) {
                Text("Add a pack (marketplace)")
                    .font(.system(size: 13, weight: .medium))
                Text("Paste an owner/repo or git URL — registers the whole marketplace so its plugins become installable.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    TextField("owner/repo", text: $addPackField)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        .onSubmit { addPackFromRepo() }
                    if addingPack {
                        progressChip("adding…")
                    } else {
                        V2ChipButton(label: "add pack", prominent: true) { addPackFromRepo() }
                    }
                }
            }
            .padding(14)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .padding(.horizontal, 26)

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add a single skill")
                        .font(.system(size: 13, weight: .medium))
                    Text("Clones a GitHub/GitLab repo and finds every skill inside, even ones nested a few folders deep.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Spacer()
                Button { showingAddFromRepo = true } label: {
                    Text("add skill →")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(v2.paper2)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(14)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .padding(.horizontal, 26)
        }
    }

    private func sectionLabel(_ text: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(v2.mute)
            Text(text)
                .font(.system(size: 9.5, design: .monospaced))
                .kerning(1.0)
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 4)
    }

    // MARK: - Restart hint

    private var reloadNoteBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(v2.add)
            Text(reloadNote ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.ink)
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(v2.addBg)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Data

    private var totalMarketSkills: Int { marketplaceRows.count }

    private var marketplaceRows: [(pluginId: String, skill: ClaudeSkill)] {
        store.pluginSkills.keys.sorted().flatMap { pluginId in
            (store.pluginSkills[pluginId] ?? []).map { (pluginId, $0) }
        }
    }

    private func isBusy(_ pack: SkillPack) -> Bool {
        switch phase[pack.id] ?? .idle {
        case .adding, .installing: return true
        default: return false
        }
    }

    /// The installed plugins that belong to this pack — resolved via the pack's
    /// REPO → real marketplace name map, then filtered to the named subset when
    /// the pack targets specific plugins in a larger marketplace.
    private func packPlugins(_ pack: SkillPack) -> [ClaudePlugin] {
        guard let name = marketplaceNameByRepo[pack.repo] else { return [] }
        return store.plugins.filter { plugin in
            store.installedPluginIds.contains(plugin.id)
                && plugin.marketplace == name
                && (pack.pluginNames.map { $0.contains(plugin.name) } ?? true)
        }
    }

    /// Live skill teaser for a pack with no curated preview — deduped by
    /// command, capped so the card stays compact.
    private func livePreview(_ pack: SkillPack) -> [SkillPack.PreviewSkill] {
        let ids = Set(packPlugins(pack).map(\.id))
        var seen = Set<String>()
        var out: [SkillPack.PreviewSkill] = []
        for id in ids.sorted() {
            for skill in store.pluginSkills[id] ?? [] {
                let command = "/\(skill.name)"
                if seen.insert(command).inserted {
                    out.append(.init(command: command, title: skill.skillDescription))
                }
                if out.count >= 10 { return out }
            }
        }
        return out
    }

    // MARK: - Actions

    private func toggleExpand(_ pack: SkillPack) {
        if expandedPacks.contains(pack.id) { expandedPacks.remove(pack.id) }
        else { expandedPacks.insert(pack.id) }
    }

    private func reloadRegistered() async {
        let markets = await MarketplaceInstaller.listMarketplaces()
        var map: [String: String] = [:]
        for m in markets { if let repo = m.repo { map[repo] = m.name } }
        marketplaceNameByRepo = map
        registered = await Task.detached { MarketplaceLoader.loadAll() }.value
    }

    /// Add a featured pack, resolving the marketplace by REPO (never a guessed
    /// name): register it if needed, read the plugins it actually offers,
    /// install + enable the pack's subset. Throws (→ visible .failed state) if
    /// the marketplace can't be registered or exposes no matching plugins —
    /// never a silent no-op.
    @discardableResult
    private func addPack(_ pack: SkillPack) async -> Bool {
        phase[pack.id] = .adding
        // Machine-readable failure phase for the redacted diagnostics timeline
        // (Report a Problem → export). No error text, names, or paths — just
        // WHERE the add stopped, so "works here, broken there" is diagnosable.
        var failCode = "marketplace-add-failed"
        do {
            // 1. Resolve the marketplace name from the repo — registering it if
            //    it isn't already present.
            var markets = await MarketplaceInstaller.listMarketplaces()
            var marketName = markets.first { $0.repo == pack.repo }?.name
            if marketName == nil {
                _ = try await MarketplaceInstaller.addMarketplace(pack.repo)
                markets = await MarketplaceInstaller.listMarketplaces()
                marketName = markets.first { $0.repo == pack.repo }?.name
            }
            failCode = "resolve-name-failed"
            guard let marketName else {
                throw SkillPackError.message("Couldn't register this pack's marketplace — check your connection.")
            }

            // 2. Which plugins does the (now-cloned) marketplace actually offer?
            let offered = await Task.detached { MarketplaceLoader.loadAll() }.value
                .first { $0.name == marketName }?.plugins ?? []
            let targets = pack.pluginNames.map { names in offered.filter { names.contains($0.name) } } ?? offered
            failCode = "no-plugins-resolved"
            guard !targets.isEmpty else {
                throw SkillPackError.message("No installable skills found in this pack.")
            }

            // 3. Install (auto-enables) any not already installed, then ensure
            //    each is enabled.
            phase[pack.id] = .installing
            failCode = "plugin-install-failed"
            let installedIds = Set(store.plugins.map(\.id))
            for plugin in targets {
                let pid = "\(plugin.name)@\(marketName)"
                if !installedIds.contains(pid) {
                    _ = try await MarketplaceInstaller.run(.install, plugin: plugin)
                }
                try? SkillOperations.setPluginEnabled(true, pluginId: pid)
            }

            await store.loadExtensions()
            await reloadRegistered()
            phase[pack.id] = .idle
            onInstalled()
            Diagnostics.record(subsystem: .plugins, operation: .packAdd, outcome: .succeeded,
                               code: "pack-added", measurements: ["plugins": targets.count])
            return true
        } catch {
            phase[pack.id] = .failed(error.localizedDescription)
            Diagnostics.record(severity: .warning, subsystem: .plugins, operation: .packAdd,
                               outcome: .failed, code: failCode)
            return false
        }
    }

    private func triggerAdd(_ pack: SkillPack) {
        Task {
            if await addPack(pack) { await reloadActiveSession() }
        }
    }

    private func setUpEssentials() {
        Task {
            var added = false
            for pack in SkillPack.essentials { if await addPack(pack) { added = true } }
            if added { await reloadActiveSession() }
        }
    }

    /// Auto-reload the active session so newly added skills come live — no
    /// "please restart" button to press. Guarded so it never kills a turn
    /// that's mid-stream (reconnectSessions restarts with --resume, which for
    /// a live .working session would throw away the in-flight reply).
    private func reloadActiveSession() async {
        guard let tab = appState.activeTab, let session = tab.streamSession else { return }
        switch session.state {
        case .ready, .hibernated:
            let n = appState.reconnectSessions(
                inProject: tab.projectCwd, afterAuthOf: "skill-packs",
                note: "skills added — session reloaded."
            )
            flashReloadNote(n > 0 ? "session reloaded ✓ — new skills are live" : "added ✓")
        case .idle, .terminated:
            flashReloadNote("added ✓ — skills load when you start a session")
        default:
            // Mid-turn — don't interrupt the stream; they load next session.
            flashReloadNote("added ✓ — new skills load on your next session")
        }
    }

    private func flashReloadNote(_ note: String) {
        reloadNote = note
        Task {
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if reloadNote == note { reloadNote = nil }
        }
    }

    /// Pull the pack's marketplace from source, then update each installed
    /// plugin. Best-effort per plugin — one already-current plugin shouldn't
    /// abort the batch.
    private func checkUpdates(_ pack: SkillPack) {
        guard let marketName = marketplaceNameByRepo[pack.repo] else { return }
        phase[pack.id] = .installing
        Task {
            do {
                _ = try await MarketplaceInstaller.updateMarketplace(marketName)
                for plugin in store.plugins where plugin.marketplace == marketName {
                    let mp = MarketplacePlugin(
                        id: plugin.id, marketplace: marketName, name: plugin.name,
                        description: "", category: nil, author: nil, homepage: nil
                    )
                    _ = try? await MarketplaceInstaller.run(.update, plugin: mp)
                }
                await store.loadExtensions()
                await reloadRegistered()
                phase[pack.id] = .idle
                await reloadActiveSession()
            } catch {
                phase[pack.id] = .failed(error.localizedDescription)
            }
        }
    }

    private func addPackFromRepo() {
        let source = addPackField.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty, !addingPack else { return }
        addingPack = true
        Task {
            do {
                _ = try await MarketplaceInstaller.addMarketplace(source)
                await store.loadExtensions()
                await reloadRegistered()
                addPackField = ""
                onInstalled()
            } catch {
                actionError = error.localizedDescription
            }
            addingPack = false
        }
    }
}
