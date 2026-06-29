// The project-home "Changes" tab — real git. Left: staged/unstaged file list.
// Right: the selected file's diff, a stage/unstage action, and a commit bar.
// Design: the Changes view in "Atelier project home.dc.html".

import SwiftUI
import Inject

// MARK: - Model

@MainActor
final class V2GitModel: ObservableObject {
    @Published var status: GitStatus?
    @Published var isRepo = true
    @Published var loading = false
    @Published var selected: GitFile?
    @Published var diff: [DiffLine] = []
    @Published var commitMessage = ""
    @Published var committing = false
    @Published var drafting = false
    @Published var commitError: String?
    private(set) var cwd = ""

    func load(cwd: String) async {
        if cwd != self.cwd { self.cwd = cwd; selected = nil; diff = []; commitMessage = ""; commitError = nil }
        loading = true
        isRepo = await V2Git.isRepo(cwd: cwd)
        status = isRepo ? await V2Git.status(cwd: cwd) : nil
        loading = false
        let all = (status?.staged ?? []) + (status?.unstaged ?? [])
        if let sel = selected, let still = all.first(where: { $0.id == sel.id }) {
            await select(still)
        } else if let first = all.first {
            await select(first)
        } else {
            selected = nil; diff = []
        }
    }

    func select(_ file: GitFile) async {
        selected = file
        diff = await V2Git.diff(cwd: cwd, path: file.path, staged: file.staged, untracked: file.untracked)
    }

    func stage(_ file: GitFile) async { await V2Git.stage(cwd: cwd, path: file.path); await load(cwd: cwd) }
    func unstage(_ file: GitFile) async { await V2Git.unstage(cwd: cwd, path: file.path); await load(cwd: cwd) }

    func commit() async {
        guard let s = status, !s.staged.isEmpty,
              !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        committing = true; commitError = nil
        let r = await V2Git.commit(cwd: cwd, message: commitMessage)
        committing = false
        if r.ok { commitMessage = ""; await load(cwd: cwd) }
        else { commitError = r.output.isEmpty ? "commit failed" : String(r.output.prefix(160)) }
    }

    /// Draft the commit message with Claude from the staged diff.
    func draftMessage(claudeBinary: URL?) async {
        guard let bin = claudeBinary else { commitError = "claude binary not found"; return }
        guard !(status?.staged.isEmpty ?? true) else { commitError = "stage changes first"; return }
        let staged = await V2Git.run(["diff", "--cached"], cwd: cwd).out
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !staged.isEmpty else { commitError = "nothing staged to summarise"; return }
        drafting = true; commitError = nil
        let msg = await V2Git.generateCommitMessage(claudeBinary: bin, diff: staged)
        drafting = false
        if let msg, !msg.isEmpty { commitMessage = msg }
        else { commitError = "couldn’t draft a message — try again" }
    }
}

// MARK: - View

struct V2ProjectChanges: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    @ObservedObject var git: V2GitModel

    var body: some View {
        Group {
            if !git.isRepo {
                centered("Not a git repository.", sub: "This project folder isn’t under version control.")
            } else if (git.status?.changeCount ?? 0) == 0 {
                centered("Working tree clean", sub: git.loading ? "Reading git status…" : "Nothing to commit.")
            } else {
                HStack(spacing: 0) {
                    fileList.frame(width: 300)
                        .overlay(alignment: .trailing) { Rectangle().fill(v2.line).frame(width: 1) }
                    diffPane
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .enableInjection()
    }

    private func centered(_ title: String, sub: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(v2.mute)
            Text(sub).font(.system(size: 12, design: .monospaced)).foregroundColor(v2.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: File list

    private var fileList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let s = git.status {
                    if !s.staged.isEmpty {
                        sectionHeader("staged · \(s.staged.count)", topBorder: false)
                        ForEach(s.staged) { fileRow($0) }
                    }
                    if !s.unstaged.isEmpty {
                        sectionHeader("unstaged · \(s.unstaged.count)", topBorder: !s.staged.isEmpty)
                        ForEach(s.unstaged) { fileRow($0) }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ text: String, topBorder: Bool) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, design: .monospaced)).kerning(1.1)
            .foregroundColor(v2.faint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18).padding(.top, topBorder ? 14 : 11).padding(.bottom, 7)
            .overlay(alignment: .top) { if topBorder { Rectangle().fill(v2.line).frame(height: 1) } }
    }

    private func fileRow(_ file: GitFile) -> some View {
        let on = git.selected?.id == file.id
        return Button { Task { await git.select(file) } } label: {
            HStack(spacing: 10) {
                Text(statusLetter(file))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(statusColor(file))
                    .frame(width: 14, alignment: .leading)
                Text(file.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if file.added > 0 {
                    Text("+\(file.added)").font(.system(size: 10, design: .monospaced)).foregroundColor(v2.add)
                }
                if file.deleted > 0 {
                    Text("−\(file.deleted)").font(.system(size: 10, design: .monospaced)).foregroundColor(v2.del)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(on ? v2.card : Color.clear)
            .overlay(alignment: .leading) { if on { Rectangle().fill(v2.ink).frame(width: 3) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func statusLetter(_ f: GitFile) -> String { f.untracked ? "?" : f.status }
    private func statusColor(_ f: GitFile) -> Color {
        switch f.status {
        case "D": return v2.del
        case "?": return v2.mute
        default:  return v2.add
        }
    }

    // MARK: Diff pane

    private var diffPane: some View {
        VStack(spacing: 0) {
            if let file = git.selected {
                diffHeader(file)
                diffBody
            } else {
                Color.clear
            }
            commitBar
        }
        .frame(maxWidth: .infinity)
    }

    private func diffHeader(_ file: GitFile) -> some View {
        HStack(spacing: 12) {
            Text(file.path)
                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundColor(v2.ink).lineLimit(1).truncationMode(.middle)
            if file.added > 0 { Text("+\(file.added)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.add) }
            if file.deleted > 0 { Text("−\(file.deleted)").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.del) }
            Spacer(minLength: 8)
            Button { Task { file.staged ? await git.unstage(file) : await git.stage(file) } } label: {
                Text(file.staged ? "Unstage" : "Stage file")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.ink)
                    .padding(.horizontal, 11).padding(.vertical, 5)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var diffBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(git.diff) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(color(for: line.kind))
                        .lineLimit(1).truncationMode(.tail)
                        .padding(.horizontal, 20).padding(.vertical, 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(bg(for: line.kind))
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func color(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return v2.add
        case .del: return v2.del
        case .hunk: return v2.mute
        case .context: return v2.faint
        }
    }
    private func bg(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return v2.addBg
        case .del: return v2.delBg
        case .hunk: return v2.paper3
        case .context: return .clear
        }
    }

    // MARK: Commit bar

    private var commitBar: some View {
        let stagedCount = git.status?.staged.count ?? 0
        let canCommit = stagedCount > 0 && !git.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !git.committing
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                TextField("Commit message…", text: $git.commitMessage)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.ink)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(v2.card)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                    .onSubmit { Task { await git.commit() } }
                Button { Task { await git.commit() } } label: {
                    Text(git.committing ? "Committing…" : "Commit \(stagedCount) staged")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(canCommit ? v2.paper : v2.faint)
                        .padding(.horizontal, 18).padding(.vertical, 9)
                        .background(canCommit ? v2.ink : v2.card)
                        .overlay(Rectangle().stroke(canCommit ? Color.clear : v2.line2, lineWidth: 1))
                }
                .buttonStyle(.plain).disabled(!canCommit)
            }
            HStack(spacing: 16) {
                if let err = git.commitError {
                    Text(err).font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.del)
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("git commit -m").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
                }
                Button { Task { await git.draftMessage(claudeBinary: appState.claudeBinary) } } label: {
                    Text(git.drafting ? "drafting…" : "ask Claude to write message")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .underline()
                }
                .buttonStyle(.plain)
                .disabled(git.drafting || (git.status?.staged.isEmpty ?? true))
                Spacer(minLength: 8)
                if let s = git.status {
                    Text(aheadLabel(s)).font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(v2.paper2)
        .overlay(alignment: .top) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func aheadLabel(_ s: GitStatus) -> String {
        guard let up = s.upstream else { return "no upstream" }
        if s.ahead == 0 && s.behind == 0 { return "in sync with \(up)" }
        var bits: [String] = []
        if s.ahead > 0 { bits.append("\(s.ahead) ahead") }
        if s.behind > 0 { bits.append("\(s.behind) behind") }
        return bits.joined(separator: " · ") + " of \(up)"
    }
}
