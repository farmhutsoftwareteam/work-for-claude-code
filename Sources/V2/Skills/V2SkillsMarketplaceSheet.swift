// Skill marketplace browsing (#64) — implements the marketplace overlay
// from "Skills management.dc.html". Two real sources, no fabricated catalog
// data:
//   1. Registered Claude plugin marketplaces (MarketplaceLoader scans
//      ~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json —
//      already real) crossed with store.pluginSkills (already parses every
//      registered plugin's skills, install state or not) for skill-level
//      "install just this one" via SkillOperations.cloneToPersonal.
//   2. The git-clone add-source flow for community skill repos lives in
//      V2AddSkillFromRepoSheet — reachable from here AND from the skills
//      panel's "+ new" chooser, one implementation shared by both.

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

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pluginMarketplaceSection
                    communitySection
                }
                .padding(.bottom, 20)
            }
        }
        .frame(width: 860, height: 640)
        .background(v2.paper2)
        .sheet(isPresented: $showingAddFromRepo) {
            V2AddSkillFromRepoSheet(onInstalled: onInstalled)
        }
        .enableInjection()
    }

    private var header: some View {
        HStack(spacing: 14) {
            Text("Marketplace")
                .font(.system(size: 15.5, weight: .medium))
                .kerning(-0.15)
            Text("\(totalMarketSkills) skills across \(marketplaces.count) marketplace\(marketplaces.count == 1 ? "" : "s")")
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

    // MARK: - Plugin marketplace section

    private var pluginMarketplaceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("claude plugin marketplace · \(totalMarketSkills) skills", icon: "powerplug")
            if marketplaceRows.isEmpty {
                Text("No marketplaces registered — add one with `claude plugin marketplace add` in a terminal.")
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
        .padding(.top, 20)
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
                _ = try? SkillOperations.cloneToPersonal(entry.skill, pluginId: entry.pluginId)
                installedFlash.insert(entry.skill.id)
                onInstalled()
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

    // MARK: - Community section

    private var communitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("community & git sources", icon: "point.3.connected.trianglepath.dotted")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Add from a repo")
                        .font(.system(size: 13, weight: .medium))
                    Text("Paste a GitHub or GitLab URL — clones it and finds every skill inside, even ones nested a few folders deep.")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
                Spacer()
                Button { showingAddFromRepo = true } label: {
                    Text("add from repo →")
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

    // MARK: - Data

    private var marketplaces: [Marketplace] { MarketplaceLoader.loadAll() }

    private var totalMarketSkills: Int { marketplaceRows.count }

    /// One row per (plugin, skill) — flattens store.pluginSkills, which
    /// already covers every registered plugin regardless of enabled state.
    private var marketplaceRows: [(pluginId: String, skill: ClaudeSkill)] {
        store.pluginSkills.keys.sorted().flatMap { pluginId in
            (store.pluginSkills[pluginId] ?? []).map { (pluginId, $0) }
        }
    }

}
