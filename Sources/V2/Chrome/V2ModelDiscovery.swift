// Builds the model picker's catalog by scanning what's actually in the user's
// ~/.claude/projects/**/*.jsonl history. No hardcoded version list — the
// picker shows exactly what claude has accepted on this machine, sorted by
// how often the user has reached for each one.
//
// Tags + descriptions are inferred from the model family name (opus / sonnet
// / haiku / fable) rather than baked into a catalog, so a new family appears
// in the picker the first time a session uses it.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "models")

struct V2DiscoveredModel: Identifiable, Equatable, Hashable {
    let id: String        // the literal model string claude reports (e.g. "claude-opus-4-7")
    let displayName: String
    let tag: String       // "most capable" / "balanced" / "fast" / "experimental" / ""
    let description: String
    let usageCount: Int   // how often it appeared in history; drives sort order
    /// The full, concrete model id (e.g. "claude-opus-4-8") used ONLY for
    /// family/generation classification. Distinct from `id` because `id` is
    /// what gets passed to `setModel()`/`--model`, and for the LIVE catalog
    /// that's a bare alias ("sonnet", "opus[1m]") — a version number can't be
    /// parsed out of it. Defaults to `id` for every source where `id` already
    /// IS the full resolved id (history-scan, the active-session synthetic
    /// row) — only the live-catalog construction site needs to pass this
    /// explicitly.
    let resolvedId: String

    init(id: String, displayName: String, tag: String, description: String, usageCount: Int, resolvedId: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.tag = tag
        self.description = description
        self.usageCount = usageCount
        self.resolvedId = resolvedId ?? id
    }

    var family: String { Self.familyKey(resolvedId) }

    static func familyKey(_ id: String) -> String {
        let lower = id.lowercased()
        if lower.contains("opus")   { return "opus" }
        if lower.contains("sonnet") { return "sonnet" }
        if lower.contains("haiku")  { return "haiku" }
        if lower.contains("fable")  { return "fable" }
        return "other"
    }

    static func tag(for id: String) -> String {
        switch familyKey(id) {
        case "opus":   return "most capable"
        case "sonnet": return "balanced"
        case "haiku":  return "fast"
        case "fable":  return "experimental"
        default:       return ""
        }
    }

    static func description(for id: String) -> String {
        switch familyKey(id) {
        case "opus":   return "Best for complex, multi-step tasks"
        case "sonnet": return "Speed + quality for everyday work"
        case "haiku":  return "Lightweight checks & quick edits"
        case "fable":  return "Experimental — newest capability tier"
        default:       return "Custom model"
        }
    }

    /// Single source of truth for the fable-usage callout — every surface
    /// that shows or lets you pick a model routes through this rather than
    /// re-deriving the family check, so the wording can't drift between the
    /// picker and the header badge. User-reported (2026-07-21), not from a
    /// published Anthropic multiplier — there is no public API for this
    /// (see AnthropicPricing.swift's header comment on the same limit) — so
    /// this deliberately says "tends to use more" rather than a specific
    /// number that can't be verified or that Anthropic could change without
    /// telling us.
    static let usageWarning = "uses more of your plan's usage limit"

    var usesMoreUsage: Bool { family == "fable" }

    // MARK: - Generation grouping
    //
    // Families don't all advance version numbers together — e.g. Sonnet and
    // Fable reached "5" while Opus's newest release is still "4.8" (asked
    // about directly, 2026-08-08: "why can't I see opus 5" — there isn't
    // one; 4.8 IS the latest Opus). A flat list can't show that, so instead
    // of hand-maintaining a "which ids are newest" table that goes stale
    // every release, we derive generation from the id's own version number
    // and rank models RELATIVE to the newest one this machine's claude CLI
    // actually reports — self-updating, and it never needs another code
    // change when a new model ships.

    /// The leading version number after `claude-<family>-`, e.g.
    /// "claude-opus-4-8" → 4, "claude-sonnet-5" → 5,
    /// "claude-haiku-4-5-20251001" → 4. nil for bare aliases ("sonnet") or
    /// any id shape this doesn't recognize — callers treat nil as "don't
    /// bury it," never as legacy.
    static func majorVersion(_ id: String) -> Int? {
        let parts = stripCacheTag(id).split(separator: "-")
        guard parts.count > 2 else { return nil }
        // Guard against the older `claude-<major>-<minor>-<family>-<date>`
        // id shape (e.g. "claude-3-5-sonnet-20241022", plausible in an old
        // session's history) — there parts[1] is a version digit, not a
        // family name, and parts[2] would be misread as major="5" instead
        // of correctly falling back to nil for an unrecognized shape. Real
        // family names are never pure digits.
        guard Int(parts[1]) == nil else { return nil }
        return Int(parts[2])
    }

    /// "LATEST" / "PREVIOUS" / "LEGACY" relative to `maxMajor` — the highest
    /// version number found in the SAME list being displayed, not a global
    /// constant. An id with no parseable version (custom/unrecognized shape)
    /// is never classified as legacy — it's shown alongside LATEST instead,
    /// since we'd rather over-surface an unknown model than hide one.
    static func generationLabel(for id: String, maxMajor: Int) -> V2ModelGeneration {
        guard let major = majorVersion(id), major < maxMajor else { return .latest }
        if major == maxMajor - 1 { return .previous }
        return .legacy
    }

    /// The one ordering every model list routes through — newest generation
    /// first, then the existing family rank, then usage — so the picker's
    /// live-catalog path and its history-scan fallback can never disagree
    /// about what counts as "latest."
    static func sortedByGeneration(_ models: [V2DiscoveredModel]) -> [V2DiscoveredModel] {
        let familyRank = ["opus": 0, "sonnet": 1, "haiku": 2, "fable": 3, "other": 4]
        return models.sorted { a, b in
            let ma = majorVersion(a.resolvedId) ?? Int.max
            let mb = majorVersion(b.resolvedId) ?? Int.max
            if ma != mb { return ma > mb }
            let ra = familyRank[a.family] ?? 99
            let rb = familyRank[b.family] ?? 99
            if ra != rb { return ra < rb }
            return a.usageCount > b.usageCount
        }
    }
}

/// A closed, compile-time-checked set of generation buckets — matching the
/// closed-set-as-enum convention this file already uses for other fixed
/// vocabularies (see V2PermissionMode elsewhere in the app), rather than
/// comparing raw "LATEST"/"PREVIOUS"/"LEGACY" strings a typo could desync.
enum V2ModelGeneration: String {
    case latest = "LATEST"
    case previous = "PREVIOUS"
    case legacy = "LEGACY"
}

/// Strips a runtime cache-tier suffix claude appends, e.g.
/// "claude-opus-4-8[1m]" → "claude-opus-4-8". Shared by majorVersion and
/// scan()'s folding loop below — the same idiom hand-rolled in one place
/// only, not two.
private func stripCacheTag(_ id: String) -> String {
    String(id.split(separator: "[").first ?? Substring(id))
}

enum V2ModelDiscovery {

    /// Scan every .jsonl under ~/.claude/projects/ and collect distinct
    /// `message.model` strings with their occurrence count. Designed to run
    /// off the main thread — call from a Task.detached. Typical sweep over
    /// the user's full history finishes in a few hundred ms.
    static func scan() -> [V2DiscoveredModel] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("projects")

        var counts: [String: Int] = [:]
        let fm = FileManager.default
        guard let projects = try? fm.contentsOfDirectory(atPath: projectsDir.path) else {
            log.notice("No projects directory available for model discovery")
            return []
        }

        // Match the literal `"model":"<value>"` substring — we don't need
        // full JSON decoding because this field's shape is identical across
        // every claude version that's written .jsonl. Cheap regex.
        let pattern = #""model":"([^"]+)""#
        let rx = try? NSRegularExpression(pattern: pattern, options: [])

        for project in projects {
            let dir = projectsDir.appendingPathComponent(project)
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for f in files where f.hasSuffix(".jsonl") {
                let url = dir.appendingPathComponent(f)
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                count(raw, into: &counts, regex: rx)
            }
        }

        // Filter junk: claude writes "<synthetic>" for some internal events
        // and bare aliases like "sonnet" for older formats. The picker passes
        // these to --model so we only want strings claude will accept as ids.
        let cleaned = counts.filter { id, _ in
            !id.isEmpty
                && !id.hasPrefix("<")
                && id.contains("-")  // explicit version → keep; bare alias → drop
        }

        // Strip cache-tier suffixes claude adds at runtime (e.g.
        // "claude-opus-4-8[1m]") so the picker shows the bare id. Sum counts
        // across the variants.
        var folded: [String: Int] = [:]
        for (id, n) in cleaned {
            folded[stripCacheTag(id), default: 0] += n
        }

        let models = folded.map { id, n in
            V2DiscoveredModel(
                id: id,
                displayName: id,
                tag: V2DiscoveredModel.tag(for: id),
                description: V2DiscoveredModel.description(for: id),
                usageCount: n
            )
        }

        let sorted = V2DiscoveredModel.sortedByGeneration(models)

        log.info("discovered \(sorted.count, privacy: .public) models from session history")
        return sorted
    }

    private static func count(_ raw: String, into counts: inout [String: Int], regex: NSRegularExpression?) {
        guard let regex else { return }
        let range = NSRange(raw.startIndex..., in: raw)
        regex.enumerateMatches(in: raw, options: [], range: range) { match, _, _ in
            guard let match, match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: raw) else { return }
            let id = String(raw[r])
            counts[id, default: 0] += 1
        }
    }
}
