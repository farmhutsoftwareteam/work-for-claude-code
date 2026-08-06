import SwiftUI
import Inject

/// "Changes this session" (#41) — every file the active Claude session's agent
/// edited/created, rolled into one reviewable list with per-file diffs. Reads
/// StreamSession.sessionChangeset (accumulated on tool completion) via a SCOPED
/// publisher, so it never re-renders per streamed token (PERFORMANCE.md §2).
/// Distinct from the project-home git Changes tab (working-tree scoped): this
/// is keyed to what the agent touched in THIS conversation.
struct V2ChangesPanel: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    let session: StreamSession

    @State private var entries: [V2SessionChangeEntry] = []
    @State private var expanded: String?
    @State private var diffLines: [DiffLine] = []
    @State private var diffLoading = false

    /// Out-of-tree writes first (that's what review exists to catch), then by
    /// first-touch order.
    private var sorted: [V2SessionChangeEntry] {
        entries.sorted {
            if $0.outOfTree != $1.outOfTree { return $0.outOfTree }
            return $0.firstTouchedAt < $1.firstTouchedAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if sorted.isEmpty {
                emptyState
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sorted) { entry in
                            fileRow(entry)
                            if expanded == entry.path { diffView }
                        }
                    }
                }
            }
        }
        .background(v2.paper2)
        // Scoped subscription — the changeset publisher only, never the
        // session's blanket objectWillChange (no per-token re-render).
        .task(id: session.instanceId) {
            entries = session.sessionChangeset
            for await c in session.sessionChangesetPublisher.values { entries = c }
        }
        .enableInjection()
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Changes")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.15)
            if !entries.isEmpty {
                Text("\(entries.count) file\(entries.count == 1 ? "" : "s")")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No files changed this session.")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.mute)
            Text("Edits, writes, and notebook changes the agent makes appear here, each with its diff. Out-of-project writes are flagged.")
                .font(.system(size: 10.5, design: .monospaced))
                .lineSpacing(10.5 * 0.5)
                .foregroundColor(v2.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
    }

    private func fileRow(_ entry: V2SessionChangeEntry) -> some View {
        let isOpen = expanded == entry.path
        return HStack(spacing: 10) {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(v2.mute)
                .rotationEffect(.degrees(isOpen ? 0 : -90))
            V2Pill(text: entry.op.label)
            V2Token(displayPath(entry))
            Spacer(minLength: 6)
            if entry.outOfTree {
                Text("outside project")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(v2.del)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(Rectangle().stroke(v2.del.opacity(0.6), lineWidth: 1))
            }
            Text("\(entry.edits)×")
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundColor(v2.mute)
        }
        .padding(.horizontal, 18).padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { toggle(entry) }
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    @ViewBuilder
    private var diffView: some View {
        if diffLoading {
            attentionRow { HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("loading diff…").font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
            } }
        } else if diffLines.isEmpty {
            attentionRow {
                Text("No textual diff (unchanged on disk, or binary).")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundColor(v2.faint)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(diffLines.prefix(600))) { line in
                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(color(for: line.kind))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 18).padding(.vertical, 0.5)
                        .background(bg(for: line.kind))
                }
                if diffLines.count > 600 {
                    Text("… \(diffLines.count - 600) more lines")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundColor(v2.faint)
                        .padding(.horizontal, 18).padding(.vertical, 6)
                }
            }
            .padding(.vertical, 6)
            .background(v2.paper3.opacity(0.4))
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
        }
    }

    private func attentionRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(v2.paper3.opacity(0.4))
            .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func color(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add:     return v2.add
        case .del:     return v2.del
        case .hunk:    return v2.mute
        case .context: return v2.faint
        }
    }
    private func bg(for kind: DiffLineKind) -> Color {
        switch kind {
        case .add: return v2.addBg
        case .del: return v2.delBg
        default:   return .clear
        }
    }

    private func displayPath(_ entry: V2SessionChangeEntry) -> String {
        if let base = session.cwd, entry.path.hasPrefix(base + "/") {
            return String(entry.path.dropFirst(base.count + 1))
        }
        return (entry.path as NSString).abbreviatingWithTildeInPath
    }

    private func toggle(_ entry: V2SessionChangeEntry) {
        if expanded == entry.path { expanded = nil; return }
        expanded = entry.path
        loadDiff(entry)
    }

    private func loadDiff(_ entry: V2SessionChangeEntry) {
        diffLines = []
        diffLoading = true
        let cwd = session.cwd ?? (entry.path as NSString).deletingLastPathComponent
        let path = entry.path
        // New files + out-of-tree writes aren't in the working-tree index — the
        // --no-index path of V2Git.diff renders their full content as additions.
        let untracked = entry.op == .create || entry.outOfTree
        Task {
            let lines = await V2Git.diff(cwd: cwd, path: path, staged: false, untracked: untracked)
            guard expanded == path else { return }   // selection changed while loading
            diffLines = lines
            diffLoading = false
        }
    }
}
