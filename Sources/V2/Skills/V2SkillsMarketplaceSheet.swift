// Skill marketplace browsing (#64) — the marketplace overlay from
// "Skills management.dc.html", promoted to the "Skill Packs" discovery surface
// (#11). Leads with a curated featured-packs section (essentials one-click +
// verified/official/community pack cards) driven by the `claude plugin` CLI, so
// packs install as plugins and stay claude-updatable. Below it, the original
// two real sources remain:
//   1. Registered Claude plugin marketplaces (MarketplaceLoader scans
//      ~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json) crossed
//      with store.pluginSkills for skill-level "install just this one" via
//      SkillOperations.cloneToPersonal (a static, editable fork).
//   2. Add a whole pack from a repo (`claude plugin marketplace add`) or a
//      single skill from a repo (V2AddSkillFromRepoSheet git-clone).

import SwiftUI
import Inject

struct V2SkillsMarketplaceSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store

    var onInstalled: () -> Void

    @State private var installedFlash: Set<String> = []
    @State private var showingAddFromRepo = false

    // Featured-packs state
    @State private var registered: [Marketplace] = []   // cached MarketplaceLoader.loadAll()
    @State private var busyPacks: Set<String> = []       // pack ids mid add/update
    @State private var expandedPacks: Set<String> = []
    @State private var actionError: String?
    @State private var showRestartHint = false
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
            if showRestartHint { restartBar }
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
        SkillPack.essentials.contains { busyPacks.contains($0.id) }
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
                V2ChipButton(label: essentialsBusy ? "setting up…" : "set up essentials", prominent: true) {
                    setUpEssentials()
                }
                .disabled(essentialsBusy)
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
        let busy = busyPacks.contains(pack.id)
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
                primaryButton(pack, busy: busy, installedCount: installedCount, enabledCount: enabledCount)
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

    @ViewBuilder
    private func statusLine(_ pack: SkillPack, installedCount: Int, enabledCount: Int) -> some View {
        HStack(spacing: 8) {
            if enabledCount > 0 {
                Circle().fill(v2.add).frame(width: 6, height: 6)
                Text("enabled")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(v2.add)
                Text("·").font(.system(size: 9, design: .monospaced)).foregroundColor(v2.faint)
                Text(pack.autoUpdatesByDefault ? "auto-updates on" : "updates: manual")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(v2.mute)
                if !pack.autoUpdatesByDefault {
                    Button { checkUpdates(pack) } label: {
                        Text("check for updates")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .disabled(busyPacks.contains(pack.id))
                }
            } else {
                Text(pack.skillCount > 0 ? "~\(pack.skillCount) skills · \(pack.publisher)" : "by \(pack.publisher)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
        }
    }

    private func primaryButton(_ pack: SkillPack, busy: Bool, installedCount: Int, enabledCount: Int) -> some View {
        let fullyEnabled = installedCount > 0 && enabledCount == installedCount
        let label: String
        if busy { label = "adding…" }
        else if fullyEnabled { label = "enabled ✓" }
        else if installedCount > 0 { label = "enable" }
        else { label = "add pack" }
        return V2ChipButton(label: label, prominent: !fullyEnabled) {
            if !fullyEnabled && !busy { triggerAdd(pack) }
        }
        .disabled(busy || fullyEnabled)
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

            // Add a whole pack (marketplace) — the old dead-end ("do it in a
            // terminal") is now a working field.
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
                    V2ChipButton(label: addingPack ? "adding…" : "add pack", prominent: true) {
                        addPackFromRepo()
                    }
                    .disabled(addingPack || addPackField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(14)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            .padding(.horizontal, 26)

            // Add a single skill (git clone into personal) — existing flow.
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

    private var restartBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(v2.mute)
            Text("Restart your session to load newly enabled skills.")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.ink)
            Spacer()
            Button { showRestartHint = false } label: {
                Text("dismiss")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(v2.addBg)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    // MARK: - Data

    private var totalMarketSkills: Int { marketplaceRows.count }

    /// One row per (plugin, skill) — flattens store.pluginSkills, which already
    /// covers every registered plugin regardless of enabled state.
    private var marketplaceRows: [(pluginId: String, skill: ClaudeSkill)] {
        store.pluginSkills.keys.sorted().flatMap { pluginId in
            (store.pluginSkills[pluginId] ?? []).map { (pluginId, $0) }
        }
    }

    /// Live skill teaser for a pack with no curated preview — pulled from the
    /// already-parsed pluginSkills for the pack's marketplace, deduped by
    /// command so ForEach ids stay unique, capped so the card stays compact.
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

    /// The installed plugins that belong to this pack — the whole marketplace,
    /// or just the named subset when the pack targets specific plugins in a
    /// larger marketplace (e.g. the official one). Drives card counts + preview.
    private func packPlugins(_ pack: SkillPack) -> [ClaudePlugin] {
        store.plugins.filter { plugin in
            plugin.marketplace == pack.marketplace
                && (pack.pluginNames.map { $0.contains(plugin.name) } ?? true)
        }
    }

    // MARK: - Actions

    private func toggleExpand(_ pack: SkillPack) {
        if expandedPacks.contains(pack.id) { expandedPacks.remove(pack.id) }
        else { expandedPacks.insert(pack.id) }
    }

    private func reloadRegistered() async {
        registered = await Task.detached { MarketplaceLoader.loadAll() }.value
    }

    /// Add a featured pack: register its marketplace if needed, then install +
    /// enable every plugin it ships. Idempotent — skips the add when already
    /// registered and skips install for plugins already present, so re-running
    /// (or the essentials loop hitting an already-added pack) is safe.
    private func addPack(_ pack: SkillPack) async {
        do {
            if let repo = pack.repo, !registered.contains(where: { $0.name == pack.marketplace }) {
                _ = try await MarketplaceInstaller.addMarketplace(repo)
                await store.loadExtensions()
                await reloadRegistered()
            }
            let available = registered.first { $0.name == pack.marketplace }?.plugins ?? []
            let plugins = pack.pluginNames.map { names in available.filter { names.contains($0.name) } } ?? available
            let installedIds = Set(store.plugins.map(\.id))
            for plugin in plugins {
                let pid = "\(plugin.name)@\(pack.marketplace)"
                if !installedIds.contains(pid) {
                    _ = try await MarketplaceInstaller.run(.install, plugin: plugin)
                }
                try SkillOperations.setPluginEnabled(true, pluginId: pid)
            }
            await store.loadExtensions()
            await reloadRegistered()
            onInstalled()
            showRestartHint = true
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func triggerAdd(_ pack: SkillPack) {
        busyPacks.insert(pack.id)
        Task {
            await addPack(pack)
            busyPacks.remove(pack.id)
        }
    }

    private func setUpEssentials() {
        Task {
            for pack in SkillPack.essentials {
                busyPacks.insert(pack.id)
                await addPack(pack)
                busyPacks.remove(pack.id)
            }
        }
    }

    /// Pull the pack's marketplace from source, then update each of its
    /// installed plugins. `.update` per plugin is best-effort — a plugin already
    /// current isn't a failure worth aborting the batch for.
    private func checkUpdates(_ pack: SkillPack) {
        busyPacks.insert(pack.id)
        Task {
            do {
                _ = try await MarketplaceInstaller.updateMarketplace(pack.marketplace)
                for plugin in store.plugins where plugin.marketplace == pack.marketplace {
                    let mp = MarketplacePlugin(
                        id: plugin.id, marketplace: pack.marketplace, name: plugin.name,
                        description: "", category: nil, author: nil, homepage: nil
                    )
                    _ = try? await MarketplaceInstaller.run(.update, plugin: mp)
                }
                await store.loadExtensions()
                await reloadRegistered()
                showRestartHint = true
            } catch {
                actionError = error.localizedDescription
            }
            busyPacks.remove(pack.id)
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
