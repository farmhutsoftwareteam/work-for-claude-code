// Featured skill-pack catalog (#11) — the curated discovery layer shown at the
// top of the marketplace surface. A "pack" is a Claude Code plugin marketplace
// (`claude plugin marketplace add <repo>`) whose plugins are installed (install
// auto-enables at user scope). Atelier owns none of the payload: it drives the
// `claude plugin` CLI, so packs stay claude-updatable.
//
// IDENTITY IS THE REPO, NOT A NAME. A marketplace's declared `name` routinely
// differs from its repo (mattpocock/skills registers as marketplace "mattpocock"
// with a plugin "mattpocock-skills"). Guessing the name is exactly what silently
// broke "add pack" before — so every pack is keyed by `repo`, and the real
// marketplace name is resolved at runtime from `claude plugin marketplace list`.

import Foundation

struct SkillPack: Identifiable {
    enum Badge: String {
        case verified    // author-verified, license-checked (third-party)
        case official    // published by Anthropic
        case community   // community-maintained
    }

    /// Stable slug for UI state keys (phase/expanded/busy dictionaries).
    let id: String
    let title: String
    let publisher: String
    let badge: Badge
    let blurb: String
    /// License label, when known (redistribution/attribution clarity).
    let license: String?
    /// "owner/repo" — the pack's identity. We register + resolve the marketplace
    /// by THIS, never by a guessed name (see the file header).
    let repo: String
    /// Install only these plugins (by name) from the marketplace; nil = all of
    /// them. Used when a marketplace ships many independent plugins (e.g. the
    /// official one) and "the pack" is a cohesive subset.
    let pluginNames: [String]?
    /// Display-only teaser of headline commands. The authoritative installed
    /// set is resolved live from store.pluginSkills after the pack is added.
    let previewSkills: [PreviewSkill]
    /// Approximate skill count for the pre-install teaser (0 = resolve live).
    let skillCount: Int
    /// Part of the one-click "essentials" set.
    let essential: Bool

    struct PreviewSkill: Identifiable {
        let command: String   // "/code-review"
        let title: String
        var id: String { command }
    }

    /// Official Anthropic marketplaces auto-update by default; third-party ones
    /// do NOT — drives the honest per-pack update label.
    var autoUpdatesByDefault: Bool { badge == .official }
}

extension SkillPack {
    /// Verified-real featured packs. Names/plugins confirmed by actually
    /// registering + installing each in an isolated config sandbox:
    ///   mattpocock/skills → marketplace "mattpocock", plugin "mattpocock-skills"
    ///   anthropics/claude-plugins-official → built-in (pre-registered)
    ///   expo/skills → marketplace "expo-plugins"
    static let catalog: [SkillPack] = [
        SkillPack(
            id: "mattpocock",
            title: "Matt Pocock — Essentials",
            publisher: "mattpocock",
            badge: .verified,
            blurb: "Battle-tested engineering-workflow skills: diff review, spec-first planning, deep research, domain modeling, and bug diagnosis.",
            license: "MIT",
            repo: "mattpocock/skills",
            pluginNames: nil,   // the marketplace ships one plugin — the whole pack
            previewSkills: [
                .init(command: "/code-review", title: "Review the diff"),
                .init(command: "/to-tickets", title: "Break a goal into tickets"),
                .init(command: "/research", title: "Deep research"),
                .init(command: "/grill-me", title: "Stress-test a plan"),
                .init(command: "/domain-modeling", title: "Model the domain"),
                .init(command: "/diagnosing-bugs", title: "Diagnose a bug"),
            ],
            skillCount: 22,
            essential: true
        ),
        SkillPack(
            id: "anthropic",
            title: "Anthropic — Official",
            publisher: "anthropics",
            badge: .official,
            blurb: "Anthropic's own plugins — feature development and frontend design. Auto-updates by default.",
            license: nil,
            repo: "anthropics/claude-plugins-official",   // built-in: pre-registered on every install
            pluginNames: ["feature-dev", "frontend-design"],   // cohesive subset, NOT the whole official marketplace
            previewSkills: [],   // resolve live from the two named plugins
            skillCount: 0,
            essential: false
        ),
        SkillPack(
            id: "expo",
            title: "Expo",
            publisher: "expo",
            badge: .community,
            blurb: "Expo's app-design and deployment skills for React Native and EAS.",
            license: nil,
            repo: "expo/skills",
            pluginNames: nil,
            previewSkills: [],   // resolve live after add
            skillCount: 0,
            essential: false
        ),
    ]

    /// The one-click bundle — kept deliberately small; each still installs
    /// through the consented pack flow.
    static var essentials: [SkillPack] { catalog.filter(\.essential) }
}

/// Small typed error so the add-pack flow surfaces a real message (not a silent
/// no-op) when a pack can't be registered or exposes no installable plugins.
enum SkillPackError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}
