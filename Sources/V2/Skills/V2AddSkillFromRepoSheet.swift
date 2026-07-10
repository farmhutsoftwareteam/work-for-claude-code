// Add-skill-from-repo sheet — the git-clone add-source flow, extracted from
// V2SkillsMarketplaceSheet so it's reachable directly from "+ new" (the
// original ask — "why can't I add a skill by pasting its gh repo?" — was a
// discoverability problem: this flow existed but was buried inside "browse
// marketplace". Same logic, both entry points (here and the marketplace's
// community section) route through this one sheet — no duplicated git-clone
// code to drift out of sync.

import SwiftUI
import Inject

struct V2AddSkillFromRepoSheet: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss

    var onInstalled: () -> Void

    @State private var gitURL = ""
    @State private var gitBusy = false
    @State private var gitError: String?
    @State private var gitCloneDir: URL?
    /// Every SKILL.md-bearing directory found in the clone. Real skill repos
    /// routinely bundle many skills (anthropics/skills has 17, none of them
    /// at the repo root or one level deep) — one candidate ⇒ auto-selected,
    /// several ⇒ shown as a picker so nothing gets chosen for the user.
    @State private var gitCandidates: [ClaudeSkill] = []
    @State private var gitSelected: ClaudeSkill?
    /// Live handle to the in-flight `git clone`, so dismissing the sheet
    /// mid-clone can actually terminate it (bug-hunt H7) instead of leaving
    /// it running with nothing left referencing it.
    @State private var activeGitProcess: Process?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                content
                    .padding(24)
            }
        }
        .frame(width: 620, height: 420)
        .background(v2.paper2)
        .onDisappear { cleanupGitPreview() }
        .enableInjection()
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Add skill from repo")
                .font(.system(size: 15.5, weight: .medium))
                .kerning(-0.15)
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

    private var content: some View {
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
                        Text("find skills")
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
            Text("Clones the repo and finds every skill in it — many repos bundle several — so you can review before installing. Atelier doesn't vet these; paste any public repo URL, or a link straight to one skill's folder.")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(v2.faint)
                .lineSpacing(3)

            if let gitError {
                Text(gitError)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(v2.del)
            }

            // Multiple skills found, none chosen yet — pick one.
            if gitSelected == nil, gitCandidates.count > 1 {
                VStack(alignment: .leading, spacing: 0) {
                    Text("\(gitCandidates.count) skills found in this repo — pick one")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                    ForEach(gitCandidates) { candidate in
                        Button { gitSelected = candidate } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                    Text(candidate.skillDescription)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundColor(v2.faint)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if candidate.id != gitCandidates.last?.id {
                            Rectangle().fill(v2.line).frame(height: 1)
                        }
                    }
                }
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }

            // Exactly one candidate (auto-selected) or a manual pick from the
            // list above — show the install confirmation.
            if let gitSelected {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(gitSelected.name)
                                .font(.system(size: 13, weight: .medium))
                            if gitCandidates.count > 1 {
                                Button("change") { self.gitSelected = nil }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(v2.mute)
                                    .underline()
                            }
                        }
                        Text(gitSelected.skillDescription)
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
    }

    // MARK: - Git add-source

    private func addFromGit() async {
        gitError = nil
        cleanupGitPreview()
        let raw = gitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }

        // Reject anything that isn't a plausible repo URL before it ever
        // reaches git — belt-and-suspenders alongside the "--" separator
        // below (bug-hunt H6): a bare "-"-prefixed value would otherwise be
        // parsable by git as a flag, e.g. "--upload-pack=/some/script".
        guard raw.hasPrefix("https://") || raw.hasPrefix("http://")
            || raw.hasPrefix("git@") || raw.hasPrefix("ssh://") else {
            gitError = "That doesn't look like a repo URL — expected it to start with https://, git@, or ssh://."
            return
        }

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

        if let failure = await runGitClone(cloneURL: cloneURL, branch: branch, cloneDir: cloneDir) {
            gitError = failure
            try? FileManager.default.removeItem(at: cloneDir)
            return
        }

        // Exact subpath first (the folder the pasted link actually pointed
        // at) — if it resolves, that's the one, no need to scan the rest of
        // the repo. Otherwise scan the WHOLE tree for every SKILL.md: real
        // skill repos routinely nest skills 1-2 levels under a container
        // folder. One match ⇒ use it directly; several ⇒ let the user pick,
        // never silently grab the first one found.
        var candidates: [URL] = []
        if let subpath, FileManager.default.fileExists(
            atPath: cloneDir.appendingPathComponent(subpath).appendingPathComponent("SKILL.md").path
        ) {
            candidates = [cloneDir.appendingPathComponent(subpath)]
        } else {
            candidates = Self.findAllSkillDirs(under: cloneDir)
        }

        let skills = candidates.compactMap { parseForPreview($0) }
        guard !skills.isEmpty else {
            gitError = "No SKILL.md found anywhere in this repo."
            try? FileManager.default.removeItem(at: cloneDir)
            return
        }
        gitCloneDir = cloneDir
        gitCandidates = skills
        gitSelected = skills.count == 1 ? skills[0] : nil
    }

    /// Splits a pasted GitHub/GitLab browser URL into a cloneable repo URL
    /// plus an optional branch and subpath, so a link straight to ONE skill
    /// inside a multi-skill repo (e.g. github.com/anthropics/skills/tree/
    /// main/skill-creator) clones the right branch and checks the right
    /// folder first — instead of cloning the whole repo and guessing. A
    /// plain repo URL (no /tree/ or /blob/) passes through unchanged.
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

    /// Bounded recursive scan for EVERY SKILL.md under `root` (not just root
    /// or one level deep). Stops descending once a directory is confirmed as
    /// a skill (its references/scripts/assets subfolders never get walked
    /// into looking for more). Depth-capped and skips the universally-safe
    /// non-skill directories (.git, node_modules, .github) — deliberately
    /// NOT filtering by name otherwise (a "docs" or "examples" folder could
    /// legitimately be someone's real skill name); the picker UI is what
    /// makes an unexpected match harmless.
    private static func findAllSkillDirs(under root: URL, maxDepth: Int = 4) -> [URL] {
        let fm = FileManager.default
        let skip: Set<String> = [".git", "node_modules", ".github"]
        var found: [URL] = []

        func walk(_ dir: URL, depth: Int) {
            if fm.fileExists(atPath: dir.appendingPathComponent("SKILL.md").path) {
                found.append(dir)
                return
            }
            guard depth < maxDepth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
            else { return }
            for entry in entries {
                let name = entry.lastPathComponent
                guard !name.hasPrefix("."), !skip.contains(name),
                      (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                else { continue }
                walk(entry, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return found
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
        guard let gitSelected else { return }
        // Was `try?` — a permission/name-collision/disk failure silently
        // proceeded to report success (cleared the form, called onInstalled,
        // dismissed) with nothing actually written (bug-hunt #12/M33).
        do {
            _ = try SkillOperations.cloneToPersonal(gitSelected)
        } catch {
            gitError = error.localizedDescription
            return
        }
        cleanupGitPreview()
        gitURL = ""
        onInstalled()
        dismiss()
    }

    private func cleanupGitPreview() {
        if let activeGitProcess, activeGitProcess.isRunning { activeGitProcess.terminate() }
        activeGitProcess = nil
        if let gitCloneDir { try? FileManager.default.removeItem(at: gitCloneDir) }
        gitCloneDir = nil
        gitCandidates = []
        gitSelected = nil
    }

    /// Runs `git clone` and suspends (no blocking wait — bug-hunt H7) until
    /// it exits or `timeout` elapses, whichever first; a hung/unreachable
    /// host gets terminated instead of orphaned. Returns an error message on
    /// failure, nil on success. `--` ends git's own flag parsing before the
    /// positional repo URL, closing the injection risk (bug-hunt H6)
    /// independent of the scheme check the caller already does.
    private func runGitClone(cloneURL: String, branch: String?, cloneDir: URL, timeout: TimeInterval = 30) async -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var args = ["clone", "--depth", "1"]
        if let branch { args += ["--branch", branch] }
        args += ["--", cloneURL, cloneDir.path]
        proc.arguments = args
        proc.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        proc.standardError = errPipe

        do {
            try proc.run()
        } catch {
            return "Couldn't run git: \(error.localizedDescription)"
        }
        activeGitProcess = proc

        let timedOut = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let resumeLock = NSLock()
            // The NSLock makes access to `resumed` genuinely safe across the
            // two closures below, but that's a runtime guarantee the Swift 6
            // strict-concurrency checker can't see syntactically — it flags
            // any `var` captured by two escaping closures regardless of
            // locking. `nonisolated(unsafe)` opts out of that check for this
            // one variable, which is correct here since we ARE the ones
            // providing the synchronization it can't verify.
            nonisolated(unsafe) var resumed = false
            proc.terminationHandler = { _ in
                resumeLock.lock(); defer { resumeLock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: false)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumeLock.lock(); defer { resumeLock.unlock() }
                guard !resumed else { return }
                resumed = true
                proc.terminate()
                cont.resume(returning: true)
            }
        }
        activeGitProcess = nil

        if timedOut {
            return "git clone timed out after \(Int(timeout))s — the host may be unreachable."
        }
        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return msg?.isEmpty == false ? msg : "git clone failed."
        }
        return nil
    }
}
