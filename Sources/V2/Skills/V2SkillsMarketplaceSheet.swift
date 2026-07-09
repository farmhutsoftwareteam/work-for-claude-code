// Skill marketplace browsing (#64) — implements the marketplace overlay
// from "Skills management.dc.html". Two real sources, no fabricated catalog
// data:
//   1. Registered Claude plugin marketplaces (MarketplaceLoader scans
//      ~/.claude/plugins/marketplaces/*/.claude-plugin/marketplace.json —
//      already real) crossed with store.pluginSkills (already parses every
//      registered plugin's skills, install state or not) for skill-level
//      "install just this one" via SkillOperations.cloneToPersonal.
//   2. A real git-clone add-source flow for community skill repos — the
//      wider open-source skill ecosystem is a different distribution
//      channel entirely (no Claude Code marketplace registration), so this
//      clones to a temp dir, verifies a SKILL.md exists, and only then
//      offers to install it.

import SwiftUI
import Inject

struct V2SkillsMarketplaceSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: Store

    var onInstalled: () -> Void

    @State private var installedFlash: Set<String> = []
    @State private var gitURL = ""
    @State private var gitBusy = false
    @State private var gitError: String?
    @State private var gitPreview: (skill: ClaudeSkill, cloneDir: URL)?

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
        .onDisappear { cleanupGitPreview() }
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
                _ = try? SkillOperations.cloneToPersonal(entry.skill)
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    TextField("https://github.com/user/some-skill-repo", text: $gitURL)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(9)
                        .background(v2.card)
                        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    Button {
                        Task { await addFromGit() }
                    } label: {
                        if gitBusy {
                            ProgressView().controlSize(.small)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                        } else {
                            Text("add source")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(v2.ink)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .background(v2.paper2)
                                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(gitBusy || gitURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Text("Clones the repo, looks for a SKILL.md at its root or one level deep, and lets you review before installing. This is a different channel from the plugin marketplace above — Atelier doesn't vet these.")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .lineSpacing(3)

                if let gitError {
                    Text(gitError)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.del)
                }

                if let gitPreview {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(gitPreview.skill.name)
                                .font(.system(size: 13, weight: .medium))
                            Text(gitPreview.skill.skillDescription)
                                .font(.system(size: 10.5, design: .monospaced))
                                .foregroundColor(v2.faint)
                                .lineLimit(2)
                        }
                        Spacer()
                        Button("install") { installGitPreview() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.paper)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(v2.ink)
                    }
                    .padding(12)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundColor(v2.line2))
                }
            }
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

    // MARK: - Git add-source

    private func addFromGit() async {
        gitError = nil
        cleanupGitPreview()
        let raw = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        gitBusy = true
        defer { gitBusy = false }

        // People share skills as a link straight to the skill's folder inside
        // a bigger repo (anthropics/skills bundles many this way) — a browser
        // "tree"/"blob" URL, not a bare clone URL. Parse the repo/branch/
        // subpath out so we clone the right branch and look in the right
        // place first, instead of guessing across the whole repo.
        let (cloneURL, branch, subpath) = Self.parseRepoURL(raw)

        let cloneDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-skill-source-\(UUID().uuidString.prefix(8))")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var args = ["clone", "--depth", "1"]
        if let branch { args += ["--branch", branch] }
        args += [cloneURL, cloneDir.path]
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            gitError = "Couldn't run git: \(error.localizedDescription)"
            return
        }
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            gitError = msg?.isEmpty == false ? msg : "git clone failed."
            try? FileManager.default.removeItem(at: cloneDir)
            return
        }

        // Exact subpath first (the folder the pasted link actually pointed
        // at) — only fall back to the shallow root/one-level scan if that
        // specific spot doesn't pan out, e.g. the link was slightly off.
        let exact = subpath.map { cloneDir.appendingPathComponent($0) }
        let skillDir = exact.flatMap { dir -> URL? in
            FileManager.default.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) ? dir : nil
        } ?? findSkillDir(under: cloneDir)

        guard let skillDir, let skill = parseForPreview(skillDir) else {
            let hint = subpath.map { " (looked in \($0)/, then the repo root and one level deep)" } ?? ""
            gitError = "No SKILL.md found at the repo root or one level deep\(hint)."
            try? FileManager.default.removeItem(at: cloneDir)
            return
        }
        gitPreview = (skill, cloneDir)
    }

    /// Splits a pasted GitHub/GitLab browser URL into a cloneable repo URL
    /// plus an optional branch and subpath, so a link straight to ONE skill
    /// inside a multi-skill repo (e.g. github.com/anthropics/skills/tree/
    /// main/skill-creator) clones the right branch and checks the right
    /// folder first — instead of cloning the whole repo and guessing. A
    /// plain repo URL (no /tree/ or /blob/) passes through unchanged, same
    /// as before this fix.
    static func parseRepoURL(_ raw: String) -> (cloneURL: String, branch: String?, subpath: String?) {
        var s = raw
        while s.hasSuffix("/") { s.removeLast() }

        // github.com/<owner>/<repo>/(tree|blob)/<branch>/<path...>
        // gitlab.com/<owner>/<repo>/-/(tree|blob)/<branch>/<path...>
        let patterns = [
            #"^(https://github\.com/[^/]+/[^/]+)/(tree|blob)/([^/]+)/(.+)$"#,
            #"^(https://gitlab\.com/[^/]+/[^/]+)/-/(tree|blob)/([^/]+)/(.+)$"#,
        ]
        for pattern in patterns {
            guard let re = try? NSRegularExpression(pattern: pattern),
                  let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
                  m.numberOfRanges == 5
            else { continue }
            func group(_ i: Int) -> String {
                guard let r = Range(m.range(at: i), in: s) else { return "" }
                return String(s[r])
            }
            let repoURL = group(1)
            let kind = group(2)
            let branch = group(3)
            var path = group(4)
            // A "blob" link points at a FILE (…/tree/main/skill-x/SKILL.md);
            // drop the filename to get the containing folder. "tree" links
            // already point at a folder.
            if kind == "blob", let lastSlash = path.lastIndex(of: "/") {
                path = String(path[path.startIndex..<lastSlash])
            } else if kind == "blob" {
                path = ""   // blob URL with no subdirectory — file sits at repo root
            }
            return (repoURL, branch, path.isEmpty ? nil : path)
        }
        return (s, nil, nil)
    }

    /// Root, or exactly one level deep (covers "repo IS the skill" and
    /// "repo contains several skill folders, look for the first one").
    private func findSkillDir(under root: URL) -> URL? {
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appendingPathComponent("SKILL.md").path) { return root }
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            if fm.fileExists(atPath: entry.appendingPathComponent("SKILL.md").path) { return entry }
        }
        return nil
    }

    private func parseForPreview(_ dir: URL) -> ClaudeSkill? {
        guard let content = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else {
            return nil
        }
        let normalized = content.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
              let second = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:]
        for line in lines[(first + 1)..<second] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            fields[key] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        guard let name = fields["name"] else { return nil }
        return ClaudeSkill(
            id: dir.path, name: name, skillDescription: fields["description"] ?? "",
            author: nil, version: nil, source: .standalone, path: dir,
            hasReferences: false, hasScripts: false, hasAssets: false,
            whenToUse: fields["when_to_use"], allowedTools: [], model: fields["model"],
            effort: nil, license: nil, argumentHint: nil, disableModelInvocation: false,
            userInvocable: true, paths: [], packaging: .directory, rawFrontmatter: fields
        )
    }

    private func installGitPreview() {
        guard let gitPreview else { return }
        _ = try? SkillOperations.cloneToPersonal(gitPreview.skill)
        cleanupGitPreview()
        gitURL = ""
        onInstalled()
    }

    private func cleanupGitPreview() {
        if let gitPreview { try? FileManager.default.removeItem(at: gitPreview.cloneDir) }
        gitPreview = nil
    }
}
