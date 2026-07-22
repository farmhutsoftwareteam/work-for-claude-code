import SwiftUI
import AppKit
import MarkdownUI

// MARK: - Plugins list

struct PluginsListView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            ForEach(store.plugins) { plugin in
                DisclosureGroup {
                    pluginDetail(plugin)
                } label: {
                    pluginRow(plugin)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Plugins")
    }

    private func pluginRow(_ plugin: ClaudePlugin) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(plugin.isEnabled ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 8, height: 8)
            Text(plugin.name)
                .font(.body.weight(.medium))
            Spacer()
            Text(plugin.marketplace.replacingOccurrences(of: "claude-plugins-", with: ""))
                .font(.caption)
                .foregroundStyle(.tertiary)
            Toggle("", isOn: Binding(
                get: { plugin.isEnabled },
                set: { newValue in togglePlugin(plugin, enabled: newValue) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .opacity(plugin.isEnabled ? 1.0 : 0.6)
    }

    private func togglePlugin(_ plugin: ClaudePlugin, enabled: Bool) {
        do {
            try SkillOperations.setPluginEnabled(enabled, pluginId: plugin.id)
            Task { await store.loadExtensions() }
        } catch {
            // Silent — user can retry; no good place for a sheet in the list row
            Diagnostics.record(
                severity: .warning, subsystem: .storage, operation: .preferences, outcome: .failed,
                code: "plugin-toggle-failed"
            )
        }
    }

    @ViewBuilder
    private func pluginDetail(_ plugin: ClaudePlugin) -> some View {
        let skills = store.pluginSkills[plugin.id] ?? []
        let mcps = store.pluginMCPs[plugin.id] ?? []

        if !skills.isEmpty {
            ForEach(skills) { skill in
                HStack(spacing: 6) {
                    Image(systemName: "sparkle")
                        .foregroundStyle(.purple)
                        .frame(width: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(skill.name)
                            .font(.callout.weight(.medium))
                        if !skill.skillDescription.isEmpty {
                            Text(skill.skillDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer()
                    skillBadges(skill)
                }
                .padding(.vertical, 2)
            }
        }

        if !mcps.isEmpty {
            ForEach(mcps) { mcp in
                HStack(spacing: 6) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.blue)
                        .frame(width: 14)
                    Text(mcp.name)
                        .font(.callout)
                    Spacer()
                    Text(mcp.transportLabel)
                        .font(.system(.caption2, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
        }

        if skills.isEmpty && mcps.isEmpty {
            Text("No bundled skills or MCPs found")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func skillBadges(_ skill: ClaudeSkill) -> some View {
        HStack(spacing: 3) {
            if skill.hasReferences { badge("refs", .blue) }
            if skill.hasScripts { badge("scripts", .orange) }
            if skill.hasAssets { badge("assets", .purple) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Skills list

enum SkillScopeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case personal = "Personal"
    case project = "Project"
    case plugin = "Plugin"
    var id: String { rawValue }
}

struct SkillsListView: View {
    @EnvironmentObject var store: Store
    @State private var search = ""
    @State private var scope: SkillScopeFilter = .all
    @State private var showingCreator = false

    /// Every skill visible to the user, with scope info preserved.
    private var allSkills: [ClaudeSkill] {
        var all: [ClaudeSkill] = store.standaloneSkills
        all.append(contentsOf: store.pluginSkills.values.flatMap { $0 })
        all.append(contentsOf: store.projectSkills.values.flatMap { $0 })
        return all
    }

    /// Map from skill-name → list of scopes where it appears (for conflict detection).
    private var nameIndex: [String: [ClaudeSkill]] {
        Dictionary(grouping: allSkills, by: \.name)
    }

    private var filtered: [ClaudeSkill] {
        var pool = allSkills
        switch scope {
        case .all:      break
        case .personal: pool = pool.filter { if case .standalone = $0.source { return true } else { return false } }
        case .project:  pool = pool.filter { if case .project = $0.source { return true } else { return false } }
        case .plugin:   pool = pool.filter { if case .plugin = $0.source { return true } else { return false } }
        }
        if !search.isEmpty {
            pool = pool.filter {
                $0.name.localizedCaseInsensitiveContains(search) ||
                $0.skillDescription.localizedCaseInsensitiveContains(search) ||
                ($0.whenToUse ?? "").localizedCaseInsensitiveContains(search)
            }
        }
        return pool.sorted { ($0.name, $0.source.precedence) < ($1.name, $1.source.precedence) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Scope picker bar
            HStack {
                Picker("", selection: $scope) {
                    ForEach(SkillScopeFilter.allCases) { s in
                        Text(scopeLabel(s)).tag(s)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()

                Spacer()

                Text("\(filtered.count) skill\(filtered.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            List {
                ForEach(filtered) { skill in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            // Precedence hint when a name collision exists
                            if let conflicts = conflicts(for: skill), conflicts.count > 1 {
                                precedenceBanner(for: skill, all: conflicts)
                            }
                            skillDetail(skill)
                        }
                    } label: {
                        skillRow(skill)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .searchable(text: $search, prompt: "Filter skills")
        .navigationTitle("Skills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingCreator = true
                } label: {
                    Label("New Skill", systemImage: "plus")
                }
                .help("Create a new skill in ~/.claude/skills/")
            }
        }
        .sheet(isPresented: $showingCreator) {
            SkillCreatorSheet(isPresented: $showingCreator)
                .environmentObject(store)
        }
    }

    private func scopeLabel(_ s: SkillScopeFilter) -> String {
        switch s {
        case .all:      return "All (\(allSkills.count))"
        case .personal: return "Personal (\(store.standaloneSkills.count))"
        case .project:  return "Project (\(store.projectSkills.values.reduce(0) { $0 + $1.count }))"
        case .plugin:   return "Plugin (\(store.pluginSkills.values.reduce(0) { $0 + $1.count }))"
        }
    }

    private func conflicts(for skill: ClaudeSkill) -> [ClaudeSkill]? {
        nameIndex[skill.name]?.filter { $0.id != skill.id }
    }

    /// Inline banner shown when a skill name appears at multiple scopes.
    @ViewBuilder
    private func precedenceBanner(for skill: ClaudeSkill, all: [ClaudeSkill]) -> some View {
        let sorted = all.sorted { $0.source.precedence > $1.source.precedence }
        let winner = sorted.first
        let isWinner = winner?.id == skill.id

        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isWinner ? "crown.fill" : "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(isWinner ? .yellow : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(isWinner ? "ACTIVE" : "SHADOWED")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(isWinner ? .green : .orange)
                Text(isWinner
                    ? "This version wins. Claude invokes \(skill.source.sourceLabel) when you run /\(skill.name)."
                    : "A higher-precedence copy exists at \(winner?.source.sourceLabel ?? "?"). Claude uses that one instead."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (isWinner ? Color.green.opacity(0.06) : Color.orange.opacity(0.08)),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    private func skillRow(_ skill: ClaudeSkill) -> some View {
        HStack(spacing: 8) {
            Image(systemName: scopeIcon(for: skill.source))
                .foregroundStyle(scopeIconColor(for: skill.source))
                .frame(width: 16)
            Text(skill.name)
                .font(.body.weight(.medium))

            // Tiny scope tag
            Text(scopeTag(for: skill.source))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(scopeIconColor(for: skill.source))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(scopeIconColor(for: skill.source).opacity(0.12), in: Capsule())

            // Collision indicator
            if let matches = nameIndex[skill.name], matches.count > 1 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help("This name exists at \(matches.count) scopes")
            }

            Spacer()

            HStack(spacing: 3) {
                if skill.hasReferences {
                    Image(systemName: "doc.text").font(.caption2).foregroundStyle(.blue)
                }
                if skill.hasScripts {
                    Image(systemName: "terminal").font(.caption2).foregroundStyle(.orange)
                }
                if skill.hasAssets {
                    Image(systemName: "photo").font(.caption2).foregroundStyle(.purple)
                }
                if skill.packaging == .zipArchive {
                    Image(systemName: "archivebox").font(.caption2).foregroundStyle(.indigo)
                }
            }
        }
    }

    private func scopeIcon(for source: ClaudeSkill.Source) -> String {
        switch source {
        case .enterprise:   return "building.columns"
        case .standalone:   return "sparkle"
        case .project:      return "folder.badge.gearshape"
        case .plugin:       return "puzzlepiece.extension"
        }
    }

    private func scopeIconColor(for source: ClaudeSkill.Source) -> Color {
        switch source {
        case .enterprise:   return .red
        case .standalone:   return .purple
        case .project:      return .green
        case .plugin:       return .indigo
        }
    }

    private func scopeTag(for source: ClaudeSkill.Source) -> String {
        switch source {
        case .enterprise:   return "ENT"
        case .standalone:   return "USER"
        case .project:      return "PROJ"
        case .plugin:       return "PLUG"
        }
    }

    private func skillDetail(_ skill: ClaudeSkill) -> some View {
        SkillDetailView(skill: skill)
    }
}

// MARK: - Skill detail view

/// Expanded detail for one skill. Loads SKILL.md body lazily, renders as Markdown,
/// lists every file in `references/` and `scripts/` with click-to-open.
struct SkillDetailView: View {
    let skill: ClaudeSkill
    @EnvironmentObject var store: Store

    @State private var bodyMarkdown: String = ""
    @State private var referenceFiles: [SkillFile] = []
    @State private var scriptFiles: [SkillFile] = []
    @State private var showBody = false
    @State private var operationError: String?
    @State private var confirmDelete = false
    @State private var isMutating = false

    struct SkillFile: Identifiable, Hashable {
        let id: String
        let url: URL
        let name: String
        let sizeBytes: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Description
            if !skill.skillDescription.isEmpty {
                Text(skill.skillDescription)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Metadata chips
            FlowRow(spacing: 8) {
                metaChip(skill.source.sourceLabel, icon: "folder", color: sourceColor(for: skill.source))

                if let version = skill.version {
                    metaChip("v\(version)", icon: "tag", color: .gray)
                }
                if let author = skill.author {
                    metaChip(author, icon: "person", color: .gray)
                }
                if let model = skill.model {
                    metaChip(model, icon: "cpu", color: .blue)
                }
                if let effort = skill.effort {
                    metaChip("effort: \(effort)", icon: "bolt", color: .orange)
                }
                if skill.disableModelInvocation {
                    metaChip("auto-invoke off", icon: "hand.raised", color: .red)
                }
                if !skill.userInvocable {
                    metaChip("slash-hidden", icon: "slash.circle", color: .red)
                }
                if skill.packaging == .zipArchive {
                    metaChip(".skill archive", icon: "archivebox", color: .indigo)
                }
            }

            // when_to_use — displayed prominently if present
            if let when = skill.whenToUse, !when.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.blue.opacity(0.7))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("WHEN TO USE")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(0.8)
                            .foregroundStyle(.tertiary)
                        Text(when)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            }

            // argument-hint, paths, allowed-tools — less prominent
            if !skill.allowedTools.isEmpty {
                kvRow("Allowed tools", skill.allowedTools.joined(separator: ", "))
            }
            if !skill.paths.isEmpty {
                kvRow("Auto-activates on", skill.paths.joined(separator: ", "))
            }
            if let hint = skill.argumentHint, !hint.isEmpty {
                kvRow("Argument hint", hint)
            }

            // Actions row
            FlowRow(spacing: 6) {
                Button {
                    showBody.toggle()
                } label: {
                    Label(showBody ? "Hide SKILL.md" : "View SKILL.md", systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([skill.path])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if skill.packaging == .directory {
                    Button {
                        let skillMd = skill.path.appendingPathComponent("SKILL.md")
                        NSWorkspace.shared.open(skillMd)
                    } label: {
                        Label("Open in editor", systemImage: "pencil")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                // Invocation toggles — only for editable directory skills
                if skill.packaging == .directory {
                    Toggle(isOn: Binding(
                        get: { !skill.disableModelInvocation },
                        set: { newValue in toggleAutoInvoke(enabled: newValue) }
                    )) {
                        Text("Auto-invoke")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isMutating)

                    Toggle(isOn: Binding(
                        get: { skill.userInvocable },
                        set: { newValue in toggleUserInvocable(invocable: newValue) }
                    )) {
                        Text("Slash command")
                            .font(.caption)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(isMutating)
                }

                // Clone — only for plugin-scoped skills (makes a personal override)
                if case .plugin = skill.source {
                    Button {
                        cloneToPersonal()
                    } label: {
                        Label("Clone to Personal", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isMutating)
                }

                // Delete — only for user-owned personal/project skills
                if case .standalone = skill.source {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isMutating)
                }
            }

            // Rendered Markdown body (toggled)
            if showBody && !bodyMarkdown.isEmpty {
                ScrollView {
                    Markdown(bodyMarkdown)
                        .markdownTheme(.docC)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 400)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color.secondary.opacity(0.1), lineWidth: 0.5)
                )
            }

            // References list
            if !referenceFiles.isEmpty {
                fileSection(title: "REFERENCES", icon: "doc.text.below.ecg", files: referenceFiles, color: .blue)
            }

            // Scripts list
            if !scriptFiles.isEmpty {
                fileSection(title: "SCRIPTS", icon: "terminal", files: scriptFiles, color: .orange)
            }

            // License note
            if let license = skill.license {
                Text(license)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 6)
        .task(id: skill.id) {
            await loadDetail()
        }
        .alert("Delete \(skill.name)?",
               isPresented: $confirmDelete,
               actions: {
                   Button("Move to Trash", role: .destructive) { deleteSkill() }
                   Button("Cancel", role: .cancel) { }
               },
               message: {
                   Text("The skill folder moves to the Trash. You can restore it from there. This doesn't affect any plugin version with the same name.")
               })
        .alert("Couldn't complete operation",
               isPresented: Binding(get: { operationError != nil }, set: { if !$0 { operationError = nil } }),
               actions: { Button("OK") { operationError = nil } },
               message: { Text(operationError ?? "") })
    }

    // MARK: - Operations

    // All four helpers hop to a detached task for the actual file I/O so a
    // slow disk op (unzip, trash, cross-volume copy) doesn't freeze the main
    // thread + spinner. Result is published back on the main actor.

    private func toggleAutoInvoke(enabled: Bool) {
        isMutating = true
        let captured = skill
        Task {
            let result: Result<Void, any Swift.Error> = await Task.detached {
                do {
                    try SkillOperations.setDisableModelInvocation(!enabled, for: captured)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                if case .failure(let error) = result {
                    operationError = error.localizedDescription
                }
                isMutating = false
            }
            await store.loadExtensions()
        }
    }

    private func toggleUserInvocable(invocable: Bool) {
        isMutating = true
        let captured = skill
        Task {
            let result: Result<Void, any Swift.Error> = await Task.detached {
                do {
                    try SkillOperations.setUserInvocable(invocable, for: captured)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                if case .failure(let error) = result {
                    operationError = error.localizedDescription
                }
                isMutating = false
            }
            await store.loadExtensions()
        }
    }

    private func cloneToPersonal() {
        isMutating = true
        let captured = skill
        Task {
            let result: Result<URL, any Swift.Error> = await Task.detached {
                do {
                    let url = try SkillOperations.cloneToPersonal(captured)
                    return .success(url)
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                switch result {
                case .success(let url):
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .failure(let error):
                    operationError = error.localizedDescription
                }
                isMutating = false
            }
            await store.loadExtensions()
        }
    }

    private func deleteSkill() {
        isMutating = true
        let captured = skill
        Task {
            let result: Result<Void, any Swift.Error> = await Task.detached {
                do {
                    _ = try SkillOperations.deleteSkill(captured)
                    return .success(())
                } catch {
                    return .failure(error)
                }
            }.value
            await MainActor.run {
                if case .failure(let error) = result {
                    operationError = error.localizedDescription
                }
                isMutating = false
            }
            await store.loadExtensions()
        }
    }

    private func loadDetail() async {
        let path = skill.path
        let packaging = skill.packaging
        let (newBody, refs, scripts) = await Task.detached(priority: .userInitiated) {
            () -> (String, [SkillFile], [SkillFile]) in
            return Self.readDetail(path: path, packaging: packaging)
        }.value
        bodyMarkdown = newBody
        referenceFiles = refs
        scriptFiles = scripts
    }

    nonisolated private static func readDetail(path: URL, packaging: ClaudeSkill.Packaging) -> (String, [SkillFile], [SkillFile]) {
        let fm = FileManager.default
        let skillMdURL: URL
        let baseDir: URL

        if packaging == .zipArchive {
            // Lazily extract to a tmp dir to read body + list references/scripts
            let tmp = fm.temporaryDirectory.appendingPathComponent("work-skill-detail-\(UUID().uuidString)")
            try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            proc.arguments = ["-q", "-o", path.path, "-d", tmp.path]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do { try proc.run(); proc.waitUntilExit() } catch { return ("", [], []) }
            let contents = (try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil)) ?? []
            guard let inner = contents.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else {
                return ("", [], [])
            }
            baseDir = inner
            skillMdURL = inner.appendingPathComponent("SKILL.md")
        } else {
            baseDir = path
            skillMdURL = path.appendingPathComponent("SKILL.md")
        }

        let rawContent = (try? String(contentsOf: skillMdURL, encoding: .utf8)) ?? ""
        let body = SkillFrontmatter.extractBody(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = listFiles(in: baseDir.appendingPathComponent("references"))
        let scripts = listFiles(in: baseDir.appendingPathComponent("scripts"))
        return (body, refs, scripts)
    }

    nonisolated private static func listFiles(in dir: URL) -> [SkillFile] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path),
              let urls = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
        else { return [] }
        return urls.compactMap { url -> SkillFile? in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return SkillFile(id: url.path, url: url, name: url.lastPathComponent, sizeBytes: size)
        }
        .sorted { $0.name < $1.name }
    }

    // MARK: - UI helpers

    private func metaChip(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }

    private func kvRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func sourceColor(for source: ClaudeSkill.Source) -> Color {
        switch source {
        case .enterprise:   return .red
        case .standalone:   return .purple
        case .project:      return .green
        case .plugin:       return .indigo
        }
    }

    private func fileSection(title: String, icon: String, files: [SkillFile], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Text("· \(files.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            VStack(spacing: 2) {
                ForEach(files) { file in
                    Button {
                        NSWorkspace.shared.open(file.url)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "doc")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text(file.name)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Spacer()
                            Text(formatBytes(file.sizeBytes))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func formatBytes(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Skill creator sheet

struct SkillCreatorSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var store: Store

    @State private var name: String = ""
    @State private var description: String = ""
    @State private var whenToUse: String = ""
    @State private var model: String = ""
    @State private var includeReferences = false
    @State private var includeScripts = false
    @State private var includeAssets = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var isValid: Bool {
        SkillOperations.isValidName(name) && !description.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Skill")
                .font(.system(size: 17, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text("NAME")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                TextField("e.g. pr-review", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .onAppear { nameFocused = true }
                Text("Lowercase letters, digits, hyphens. 2–64 chars.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("DESCRIPTION")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $description)
                    .frame(height: 56)
                    .border(Color.secondary.opacity(0.2))
                Text("Shown to Claude — it uses this to decide when to auto-invoke.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WHEN TO USE (optional)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                TextEditor(text: $whenToUse)
                    .frame(height: 44)
                    .border(Color.secondary.opacity(0.2))
            }

            HStack(spacing: 8) {
                Toggle("references/", isOn: $includeReferences)
                Toggle("scripts/", isOn: $includeScripts)
                Toggle("assets/", isOn: $includeAssets)
            }
            .toggleStyle(.checkbox)
            .font(.caption)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func create() {
        do {
            let newURL = try SkillOperations.createSkill(
                name: name,
                description: description,
                whenToUse: whenToUse.isEmpty ? nil : whenToUse,
                model: model.isEmpty ? nil : model,
                includeReferences: includeReferences,
                includeScripts: includeScripts,
                includeAssets: includeAssets
            )
            Task { await store.loadExtensions() }
            NSWorkspace.shared.open(newURL.appendingPathComponent("SKILL.md"))
            isPresented = false
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Simple wrap-any-children flow layout for metadata chips.
private struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 6, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        // SwiftUI doesn't have a native flow layout pre-26.1, so use a Layout.
        FlowLayout(spacing: spacing) { content() }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x)
        }
        return CGSize(width: totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - MCPs list

struct MCPsListView: View {
    @EnvironmentObject var store: Store

    @State private var editorMode: MCPEditor.Mode?
    @State private var pendingDelete: (name: String, scope: MCPConfigWriter.Scope)?
    @State private var isRefreshing = false
    @State private var showAppliedHint = false
    @State private var hintTask: Task<Void, Never>?
    @State private var expandedRows: Set<String> = []
    @State private var showMarketplace = false
    @State private var pendingMarketplaceDraft: MCPDraft?
    @State private var operationError: String?

    private func isExpanded(_ mcp: MCPServer) -> Bool {
        expandedRows.contains(mcp.statusKey)
    }

    private func toggleExpanded(_ mcp: MCPServer) {
        if expandedRows.contains(mcp.statusKey) {
            expandedRows.remove(mcp.statusKey)
        } else {
            expandedRows.insert(mcp.statusKey)
        }
    }

    /// Projects that have at least one MCP configured, sorted by name
    private var projectsWithMCPs: [(cwd: String, name: String, mcps: [MCPServer])] {
        store.projectMCPs
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { entry in
                let name = (entry.key as NSString).lastPathComponent
                return (cwd: entry.key, name: name, mcps: entry.value)
            }
    }

    /// Projects that have at least one `.local` MCP — same shape as
    /// `projectsWithMCPs` but pulling from `store.localUserMCPs`.
    private var projectsWithLocalMCPs: [(cwd: String, name: String, mcps: [MCPServer])] {
        store.localUserMCPs
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { entry in
                let name = (entry.key as NSString).lastPathComponent
                return (cwd: entry.key, name: name, mcps: entry.value)
            }
    }

    /// Priority order: needsAuth > configured > running. Alphabetical within group.
    private func sortMCPs(_ mcps: [MCPServer]) -> [MCPServer] {
        func priority(_ mcp: MCPServer) -> Int {
            switch store.mcpStatuses[mcp.statusKey] {
            case .needsAuth: return 0   // show first
            case .configured: return 1
            case .running: return 2     // working fine, least urgent
            case nil: return 3
            }
        }
        return mcps.sorted { (a, b) in
            let pa = priority(a), pb = priority(b)
            if pa != pb { return pa < pb }
            return a.name < b.name
        }
    }

    private var hasAnyMCPs: Bool {
        !store.standaloneMCPs.isEmpty
            || !projectsWithMCPs.isEmpty
            || !projectsWithLocalMCPs.isEmpty
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if showAppliedHint {
                    appliedHintBanner
                }

                if !hasAnyMCPs {
                    emptyState
                } else {
                    // User-scope (all sessions) — top-level mcpServers in
                    // ~/.claude.json. Renamed from "Global" to match Claude
                    // Code's own terminology.
                    sectionHeader("User (all your projects)", count: store.standaloneMCPs.count)
                    if store.standaloneMCPs.isEmpty {
                        Text("No user MCPs yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 4)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(sortMCPs(store.standaloneMCPs)) { mcp in
                                mcpCard(mcp, scope: .user)
                            }
                        }
                    }

                    // Local scope — per-project, private to you, stored under
                    // ~/.claude.json → projects.<cwd>.mcpServers. This is
                    // Claude Code's DEFAULT scope (claude mcp add with no
                    // --scope lands here).
                    ForEach(projectsWithLocalMCPs, id: \.cwd) { entry in
                        sectionHeader("Local: \(entry.name) (private to you)", count: entry.mcps.count)
                            .padding(.top, 16)
                        VStack(spacing: 8) {
                            ForEach(sortMCPs(entry.mcps)) { mcp in
                                mcpCard(mcp, scope: .local(cwd: entry.cwd))
                            }
                        }
                    }

                    // Project scope — shared with the team via .mcp.json
                    ForEach(projectsWithMCPs, id: \.cwd) { entry in
                        sectionHeader("Project: \(entry.name) (shared via .mcp.json)", count: entry.mcps.count)
                            .padding(.top, 16)
                        VStack(spacing: 8) {
                            ForEach(sortMCPs(entry.mcps)) { mcp in
                                mcpCard(mcp, scope: .project(cwd: entry.cwd))
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle("MCP Servers")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task {
                        isRefreshing = true
                        await store.reloadMCPs()
                        isRefreshing = false
                    }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Reload configs and recheck running status")
                .disabled(isRefreshing)
            }

            ToolbarItem(placement: .automatic) {
                Button {
                    showMarketplace = true
                } label: {
                    Label("Marketplace", systemImage: "bag")
                }
                .help("Browse the official MCP marketplace")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    editorMode = .add(defaultScope: .global)
                } label: {
                    Label("Add MCP", systemImage: "plus")
                }
                .help("Add a new MCP server manually")
            }
        }
        .task { await store.refreshMCPStatuses() }
        .sheet(item: Binding(
            get: { editorMode },
            set: { editorMode = $0 }
        )) { mode in
            MCPEditor(mode: mode) {
                triggerAppliedHint()
            }
            .environmentObject(store)
        }
        .sheet(
            isPresented: $showMarketplace,
            onDismiss: {
                // Present the editor sheet only after the marketplace sheet has fully
                // dismissed — SwiftUI refuses to present two sheets simultaneously.
                if let draft = pendingMarketplaceDraft {
                    pendingMarketplaceDraft = nil
                    editorMode = .addFromMarketplace(draft: draft, defaultScope: .global)
                }
            }
        ) {
            MCPMarketplaceView { draft in
                pendingMarketplaceDraft = draft
            }
        }
        .alert(
            "Delete MCP?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { pending in
            Button("Delete", role: .destructive) {
                let name = pending.name
                let scope = pending.scope
                pendingDelete = nil
                Task {
                    do {
                        try await Task.detached(priority: .userInitiated) {
                            try MCPConfigWriter.delete(name: name, scope: scope)
                        }.value
                        await store.reloadMCPs()
                        triggerAppliedHint()
                    } catch {
                        operationError = "Failed to delete '\(name)': \(error.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { pending in
            Text("'\(pending.name)' will be removed from your config. This can't be undone from the app.")
        }
        .alert(
            "Operation failed",
            isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            ),
            presenting: operationError
        ) { _ in
            Button("OK") { operationError = nil }
        } message: { err in
            Text(err)
        }
    }

    private func triggerAppliedHint() {
        hintTask?.cancel()
        showAppliedHint = true
        hintTask = Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                showAppliedHint = false
            }
        }
    }

    // MARK: - Section header

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(.tertiary)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.06), in: Capsule())
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Applied hint banner

    private var appliedHintBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Saved. Start a new Claude session to apply changes.")
                .font(.system(size: 12))
            Spacer()
        }
        .padding(10)
        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.green.opacity(0.2), lineWidth: 0.5)
        )
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "server.rack")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            VStack(spacing: 6) {
                Text("No MCP servers yet")
                    .font(.system(size: 15, weight: .semibold))
                Text("Extend Claude Code with new capabilities — databases, APIs, tools.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                editorMode = .add(defaultScope: .global)
            } label: {
                Label("Add your first MCP", systemImage: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(40)
    }

    // MARK: - MCP card

    @ViewBuilder
    private func mcpCard(_ mcp: MCPServer, scope: MCPConfigWriter.Scope) -> some View {
        let status = store.mcpStatuses[mcp.statusKey]
        let needsAttention = status == .needsAuth

        VStack(alignment: .leading, spacing: 0) {
            // Top row: name + transport chip + actions
            HStack(spacing: 8) {
                // Clickable expand area (name + chip)
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        toggleExpanded(mcp)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(isExpanded(mcp) ? 90 : 0))
                            .foregroundStyle(.tertiary)
                            .frame(width: 10)

                        Text(mcp.name)
                            .font(.system(size: 14, weight: .semibold))

                        transportChip(mcp)
                        authChip(mcp)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Status (always visible)
                if let status {
                    statusPill(status)
                }

                // Actions
                if case .plugin = mcp.source {
                    EmptyView()
                } else {
                    rowActions(mcp, scope: scope, needsAttention: needsAttention)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            // Expanded detail
            if isExpanded(mcp) {
                Divider().opacity(0.5)
                mcpDetail(mcp)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .transition(.opacity)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(needsAttention
                    ? Color.orange.opacity(0.06)
                    : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    needsAttention
                        ? Color.orange.opacity(0.3)
                        : Color.primary.opacity(0.08),
                    lineWidth: 0.5
                )
        )
    }

    // MARK: - Transport chip (clear text label, not cryptic icon)

    private func transportChip(_ mcp: MCPServer) -> some View {
        let label: String
        let color: Color
        switch mcp.transport {
        case .stdio:    label = "LOCAL";  color = .orange
        case .http:     label = "HTTP";   color = .blue
        case .sse:      label = "SSE";    color = .cyan
        case .sdk:      label = "SDK";    color = .secondary
        case .unknown:  label = "?";       color = .yellow
        }
        return Text(label)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .help(transportHelp(mcp))
    }

    // MARK: - Auth method inference

    private enum AuthMethod {
        case apiKey       // stdio with secret env vars
        case oauth        // http/sse — Claude Code handles OAuth
        case none         // no auth needed

        var label: String {
            switch self {
            case .apiKey: return "API Key"
            case .oauth:  return "OAuth"
            case .none:   return "No Auth"
            }
        }

        var color: Color {
            switch self {
            case .apiKey: return .purple
            case .oauth:  return .blue
            case .none:   return .secondary
            }
        }

        var help: String {
            switch self {
            case .apiKey: return "Authed via API key in the env vars. Edit to rotate."
            case .oauth:  return "Authed via OAuth. Claude Code manages the token in your keychain."
            case .none:   return "No authentication required."
            }
        }
    }

    private func authMethod(for mcp: MCPServer) -> AuthMethod {
        switch mcp.transport {
        case .http, .sse:
            return .oauth
        case .stdio(_, let args):
            // Check env vars for secret-looking keys
            let envHasSecret = (mcp.env ?? [:]).keys.contains(where: SecretDetection.isSecretKey)
            if envHasSecret { return .apiKey }

            // Check args for auth-like flags (--token, --access-token, --api-key, etc.)
            // or any arg starting with common token prefixes (sbp_, sk_, ghp_, etc.)
            let argsHaveSecret = args.contains { arg in
                let lower = arg.lowercased()
                if lower.hasPrefix("--") {
                    return lower.contains("token") || lower.contains("key")
                        || lower.contains("secret") || lower.contains("auth")
                        || lower.contains("password")
                }
                // Token value heuristics
                return arg.hasPrefix("sbp_") || arg.hasPrefix("sk_") || arg.hasPrefix("sk-")
                    || arg.hasPrefix("ghp_") || arg.hasPrefix("gho_") || arg.hasPrefix("github_pat_")
                    || arg.hasPrefix("Bearer ")
            }
            return argsHaveSecret ? .apiKey : .none
        case .sdk, .unknown:
            return .none
        }
    }

    private func authChip(_ mcp: MCPServer) -> some View {
        let method = authMethod(for: mcp)
        return HStack(spacing: 3) {
            Image(systemName: method == .oauth ? "link" : (method == .apiKey ? "key.fill" : "lock.open"))
                .font(.system(size: 8))
            Text(method.label)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(method.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(method.color.opacity(0.1), in: Capsule())
        .help(method.help)
    }

    // MARK: - Status pill (clearer than badge)

    private func statusPill(_ status: MCPStatus) -> some View {
        let color: Color
        switch status {
        case .running:    color = .green
        case .needsAuth:  color = .orange
        case .configured: color = .secondary
        }
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(status.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .help(statusHelp(status))
    }

    private func statusHelp(_ status: MCPStatus) -> String {
        switch status {
        case .running:    "Running — a matching process was found on your Mac"
        case .needsAuth:  "Needs sign-in before it can be used"
        case .configured: "Configured — will run when a Claude session starts"
        }
    }

    // MARK: - Row actions

    @ViewBuilder
    private func rowActions(_ mcp: MCPServer, scope: MCPConfigWriter.Scope, needsAttention: Bool) -> some View {
        Button {
            editorMode = .edit(mcp, scope: scope)
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Edit")

        Menu {
            if needsAttention {
                Button("Reset auth state") { resetAuth(for: mcp) }
                Divider()
            }
            Button("Copy config (without secrets)") { copyConfig(mcp, includeSecrets: false) }
            if (mcp.env ?? [:]).keys.contains(where: SecretDetection.isSecretKey) {
                Button("Copy config WITH secrets") { copyConfig(mcp, includeSecrets: true) }
            }
            Divider()
            Button("Delete…", role: .destructive) {
                pendingDelete = (name: mcp.name, scope: scope)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Remove the MCP from ~/.claude/mcp-needs-auth-cache.json so the next Claude session
    /// re-triggers the OAuth flow. For stdio/API-key MCPs this does nothing meaningful —
    /// the user should use Edit to rotate the token.
    private func resetAuth(for mcp: MCPServer) {
        let cacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/mcp-needs-auth-cache.json")
        let mcpName = mcp.name

        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    // If file doesn't exist there's nothing to reset — that's fine
                    guard FileManager.default.fileExists(atPath: cacheURL.path) else { return }

                    let coordinator = NSFileCoordinator()
                    var coordError: NSError?
                    var thrownError: Error?
                    coordinator.coordinate(writingItemAt: cacheURL, options: [], error: &coordError) { url in
                        do {
                            let data = try Data(contentsOf: url)
                            guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                                throw NSError(
                                    domain: "ResetAuth", code: 1,
                                    userInfo: [NSLocalizedDescriptionKey: "Auth cache is not a JSON object"]
                                )
                            }
                            dict.removeValue(forKey: mcpName)
                            let newData = try JSONSerialization.data(
                                withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]
                            )
                            try newData.write(to: url, options: .atomic)
                        } catch {
                            thrownError = error
                        }
                    }
                    if let e = coordError { throw e }
                    if let e = thrownError { throw e }
                }.value
                await store.reloadMCPs()
                triggerAppliedHint()
            } catch {
                operationError = "Couldn't reset auth for '\(mcpName)': \(error.localizedDescription)"
            }
        }
    }

    /// Shell-quote an argument for display only, so args with spaces/quotes render unambiguously.
    private static func shellQuote(_ arg: String) -> String {
        // Simple display rule: if arg is "safe" (alphanumerics and `/_-.:@=+,%` only), no quotes.
        // Otherwise wrap in single quotes and escape any embedded single quotes.
        let safe = arg.unicodeScalars.allSatisfy { scalar in
            let c = Character(scalar)
            return c.isLetter || c.isNumber || "/_-.:@=+,%".contains(c)
        }
        if safe && !arg.isEmpty { return arg }
        let escaped = arg.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func copyConfig(_ mcp: MCPServer, includeSecrets: Bool) {
        var dict: [String: Any] = [:]
        switch mcp.transport {
        case .stdio(let cmd, let args):
            dict["type"] = "stdio"
            dict["command"] = cmd
            dict["args"] = args
        case .http(let url):
            dict["type"] = "http"
            dict["url"] = url
        case .sse(let url):
            dict["type"] = "sse"
            dict["url"] = url
        default:
            break
        }
        if let env = mcp.env, !env.isEmpty {
            if includeSecrets {
                dict["env"] = env
            } else {
                // Redact secret values — keep keys so user sees what's needed
                var redacted: [String: String] = [:]
                for (k, v) in env {
                    redacted[k] = SecretDetection.isSecretKey(k) ? "REDACTED" : v
                }
                dict["env"] = redacted
            }
        }
        let wrapper = [mcp.name: dict]
        if let data = try? JSONSerialization.data(withJSONObject: wrapper, options: [.prettyPrinted, .sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            NSPasteboard.general.clearContents()
            // Mark as concealed so clipboard managers can treat it as sensitive
            if includeSecrets {
                NSPasteboard.general.setString(str, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            }
            NSPasteboard.general.setString(str, forType: .string)
        }
    }

    private func mcpDetail(_ mcp: MCPServer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mcp.transport {
            case .stdio(let command, let args):
                detailRow("Command", value: command)
                if !args.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Arguments")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                        Text(args.map(Self.shellQuote).joined(separator: " "))
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.textBackgroundColor).opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            case .http(let url), .sse(let url):
                detailRow("URL", value: url)
            case .sdk:
                detailRow("Type", value: "Built-in SDK integration")
            case .unknown(let type):
                detailRow("Type", value: "Unknown (\(type))")
            }

            // Environment variables with secret masking
            if let env = mcp.env, !env.isEmpty {
                EnvVarsList(env: env)
            }
        }
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func capBox(_ label: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 72, height: 36)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func transportIcon(_ mcp: MCPServer) -> String {
        switch mcp.transport {
        case .stdio:    "terminal"
        case .http:     "network"
        case .sse:      "antenna.radiowaves.left.and.right"
        case .sdk:      "shippingbox"
        case .unknown:  "questionmark.circle"
        }
    }

    private func transportColor(_ mcp: MCPServer) -> Color {
        switch mcp.transport {
        case .stdio:    .orange
        case .http:     .blue
        case .sse:      .cyan
        case .sdk:      .secondary
        case .unknown:  .yellow
        }
    }

    private func transportHelp(_ mcp: MCPServer) -> String {
        switch mcp.transport {
        case .stdio:    "stdio — runs a local command on your Mac"
        case .http:     "HTTP — connects to a remote server over HTTP"
        case .sse:      "SSE — subscribes to a remote server via Server-Sent Events"
        case .sdk:      "SDK — built into Claude Code"
        case .unknown(let t): "Unknown transport type: \(t)"
        }
    }

    private func sourceLabel(_ source: MCPServer.Source) -> some View {
        Group {
            switch source {
            case .global:
                Text("global")
            case .localUser:
                Text("local")
            case .project:
                Text("project")
            case .plugin(let name):
                Text(name)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

// MARK: - Env vars display (with secret masking)

private struct EnvVarsList: View {
    let env: [String: String]
    @State private var revealed: Set<String> = []

    private var keys: [String] { env.keys.sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "key.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Environment")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .tracking(0.5)
            }

            VStack(spacing: 4) {
                ForEach(keys, id: \.self) { key in
                    envRow(key: key, value: env[key] ?? "")
                }
            }
        }
    }

    @ViewBuilder
    private func envRow(key: String, value: String) -> some View {
        let isSecret = SecretDetection.isSecretKey(key)
        let isRevealed = revealed.contains(key)
        let displayValue = (isSecret && !isRevealed) ? Self.mask(value) : value

        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(minWidth: 120, alignment: .leading)

            Group {
                if isRevealed || !isSecret {
                    Text(displayValue)
                        .textSelection(.enabled)
                } else {
                    Text(displayValue)
                }
            }
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .lineLimit(1)
            .truncationMode(.middle)

            if isSecret {
                Button {
                    if isRevealed { revealed.remove(key) } else { revealed.insert(key) }
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isRevealed ? "Hide value" : "Reveal value")
            }

            Button {
                NSPasteboard.general.clearContents()
                if isSecret {
                    // Mark as concealed so clipboard managers can treat it as sensitive
                    NSPasteboard.general.setString(value, forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
                }
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .help(isSecret ? "Copy (marked as concealed)" : "Copy value")
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Copy value")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 5))
    }

    private static func mask(_ value: String) -> String {
        // Show first 3 chars + dots
        guard value.count > 4 else { return String(repeating: "•", count: 8) }
        let prefix = String(value.prefix(4))
        return prefix + String(repeating: "•", count: 12)
    }
}

// MARK: - MCP status badge (shared)

struct MCPStatusBadge: View {
    let status: MCPStatus?

    var body: some View {
        if let status {
            HStack(spacing: 3) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(status.rawValue)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(statusColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(statusColor.opacity(0.12), in: Capsule())
            .help(statusHelp)
        }
    }

    private var statusColor: Color {
        switch status {
        case .running:    .green
        case .needsAuth:  .orange
        case .configured: .secondary
        case nil:         .secondary
        }
    }

    private var statusHelp: String {
        switch status {
        case .running:    "Running — a matching process was found on your Mac"
        case .needsAuth:  "Needs auth — sign in to this MCP in Claude Code"
        case .configured: "Configured — ready to run when Claude Code starts a session"
        case nil:         ""
        }
    }
}

// MARK: - Hooks list

struct HooksListView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        List {
            ForEach(store.hooks) { hook in
                DisclosureGroup {
                    hookDetail(hook)
                } label: {
                    hookRow(hook)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle("Hooks")
    }

    private func hookRow(_ hook: ClaudeHook) -> some View {
        HStack(spacing: 8) {
            Image(systemName: hook.eventIcon)
                .foregroundStyle(.orange)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(hook.event)
                    .font(.body.weight(.medium))
                Text(eventDescription(hook.event))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(hook.commands.count) cmd\(hook.commands.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
    }

    private func hookDetail(_ hook: ClaudeHook) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(hook.commands) { cmd in
                VStack(alignment: .leading, spacing: 4) {
                    if let matcher = cmd.matcher {
                        HStack(spacing: 4) {
                            Text("when:")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Text(matcher)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(cmd.command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.textBackgroundColor).opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func eventDescription(_ event: String) -> String {
        switch event {
        case "SessionStart":        "When a new Claude session begins"
        case "SessionEnd":          "When a session ends"
        case "UserPromptSubmit":    "Before each user message is sent"
        case "PreToolUse":          "Before a tool executes"
        case "PostToolUse":         "After a tool succeeds"
        case "PostToolUseFailure":  "When a tool fails"
        case "Stop":                "When Claude finishes responding"
        default:                    ""
        }
    }
}
