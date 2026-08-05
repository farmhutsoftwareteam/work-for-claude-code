// Featured skill-pack catalog (#11) — the curated discovery layer shown at the
// top of the marketplace surface. A "pack" is a Claude Code plugin marketplace
// (`claude plugin marketplace add <repo>`) whose plugins are installed + enabled.
// Atelier owns none of the payload: it drives the `claude plugin` CLI, so packs
// stay claude-updatable (unlike a per-skill clone, which is a static copy that
// never refreshes).
//
// Curation discipline: every entry here is a REAL, verified marketplace — no
// fabricated catalog data. `previewSkills` are shown only where the real
// /commands were verified; otherwise the card resolves its skill list live from
// store.pluginSkills once the pack is added.

import Foundation

struct SkillPack: Identifiable {
    enum Badge: String {
        case verified    // author-verified, license-checked (third-party)
        case official    // published by Anthropic
        case community   // community-maintained
    }

    /// Marketplace name (ClaudePlugin.marketplace / marketplace.json `name`).
    let id: String
    let title: String
    let publisher: String
    let badge: Badge
    let blurb: String
    /// SPDX-ish license label, when known (redistribution/attribution clarity).
    let license: String?
    /// "owner/repo" for `claude plugin marketplace add`. nil when the
    /// marketplace ships built-in (already registered — skip the add step).
    let repo: String?
    /// The registered marketplace name to install plugins from.
    let marketplace: String
    /// When set, only these plugins (by name) are installed/enabled and counted
    /// for this pack — used when a marketplace ships many independent plugins
    /// (e.g. claude-plugins-official) and "the pack" is a cohesive subset, not
    /// the whole thing. nil = the marketplace's plugins ARE the pack (small,
    /// cohesive marketplaces like mattpocock-skills / expo).
    let pluginNames: [String]?
    /// Display-only teaser of headline skills (real /commands). The authoritative
    /// installed set comes from store.pluginSkills after the pack is added.
    let previewSkills: [PreviewSkill]
    /// Approximate skill count for the pre-install teaser (0 = resolve live).
    let skillCount: Int
    /// Part of the one-click "essentials" set.
    let essential: Bool

    struct PreviewSkill: Identifiable {
        let command: String   // "/tdd"
        let title: String
        var id: String { command }
    }

    /// Official Anthropic marketplaces auto-update by default; third-party ones
    /// do NOT — "always latest" for those means an explicit update (the pack
    /// card's "check for updates"). This drives the honest status label.
    var autoUpdatesByDefault: Bool { badge == .official }
}

extension SkillPack {
    /// Verified-real featured packs. mattpocock/skills confirmed MIT with the
    /// listed /commands; claude-plugins-official is Anthropic's built-in
    /// marketplace (already registered on every install); expo/skills is Expo's
    /// public marketplace.
    static let catalog: [SkillPack] = [
        SkillPack(
            id: "mattpocock-skills",
            title: "Matt Pocock — Essentials",
            publisher: "mattpocock",
            badge: .verified,
            blurb: "Battle-tested engineering-workflow skills: test-driven dev, diff review, spec-first planning, HTML prototyping, and deep research.",
            license: "MIT",
            repo: "mattpocock/skills",
            marketplace: "mattpocock-skills",
            pluginNames: nil,   // small cohesive marketplace — the whole pack
            previewSkills: [
                .init(command: "/tdd", title: "Test-driven development"),
                .init(command: "/code-review", title: "Review the diff"),
                .init(command: "/prototype", title: "Prototype in HTML"),
                .init(command: "/to-tickets", title: "Break a goal into tickets"),
                .init(command: "/research", title: "Deep research"),
                .init(command: "/grill-me", title: "Stress-test a plan"),
                .init(command: "/handoff", title: "Write a session handoff"),
            ],
            skillCount: 22,
            essential: true
        ),
        SkillPack(
            id: "claude-plugins-official",
            title: "Anthropic — Official",
            publisher: "anthropics",
            badge: .official,
            blurb: "Anthropic's own plugin marketplace — feature development, frontend design, and document skills. Auto-updates by default.",
            license: nil,
            repo: nil,   // built-in: registered on every Claude Code install
            marketplace: "claude-plugins-official",
            pluginNames: ["feature-dev", "frontend-design"],   // cohesive subset, NOT the whole official marketplace
            previewSkills: [],   // resolve live from the two named plugins
            skillCount: 0,
            essential: false
        ),
        SkillPack(
            id: "expo-plugins",
            title: "Expo",
            publisher: "expo",
            badge: .community,
            blurb: "Expo's app-design and deployment skills for React Native and EAS.",
            license: nil,
            repo: "expo/skills",
            marketplace: "expo-plugins",
            pluginNames: nil,   // small cohesive marketplace — the whole pack
            previewSkills: [],   // resolve live after add
            skillCount: 0,
            essential: false
        ),
    ]

    /// The one-click bundle. Kept deliberately small — a curated starting point,
    /// not everything. Each still installs through the consented pack flow.
    static var essentials: [SkillPack] { catalog.filter(\.essential) }
}
