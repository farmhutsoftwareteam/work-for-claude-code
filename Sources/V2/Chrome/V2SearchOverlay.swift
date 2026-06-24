// ⌘K search overlay. Modal layered over the v2 root, dims the chrome behind
// it, and searches across every session in every project. Picking a result
// opens a tab via V2AppState.openHistorySession — same path the history rail
// uses.

import SwiftUI
import Inject

struct V2SearchOverlay: View {
    @ObserveInjection private var inject
    @Environment(\.v2) private var v2
    @EnvironmentObject private var store: Store
    @EnvironmentObject private var appState: V2AppState
    @FocusState private var queryFocused: Bool
    @State private var highlighted: Int = 0

    var body: some View {
        ZStack {
            // Subtle vibrancy backdrop — the .ultraThinMaterial lets the
            // chrome behind read through while pushing it visually back. A
            // thin ink wash on top keeps the modal legible in light mode
            // without going full opaque.
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()
                .overlay(Color.black.opacity(0.06).ignoresSafeArea())
                .contentShape(Rectangle())
                .onTapGesture { close() }

            VStack(spacing: 0) {
                input
                Divider().background(v2.line)
                results
                Divider().background(v2.line)
                footer
            }
            .frame(width: 560)
            .frame(maxHeight: 480)
            .background(.regularMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(v2.line2, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.32), radius: 36, x: 0, y: 18)
            .shadow(color: .black.opacity(0.10), radius: 2, x: 0, y: 1)
            .padding(.top, 110)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear {
            queryFocused = true
            highlighted = 0
        }
        .background(
            // Esc to close — captured by the overlay itself.
            Button("Close") { close() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
        )
        .enableInjection()
    }

    private var input: some View {
        HStack(spacing: 11) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundColor(v2.mute)
            TextField("Search sessions across all projects…", text: $appState.searchQuery)
                .textFieldStyle(.plain)
                .focused($queryFocused)
                .font(.system(size: 13.5, design: .monospaced))
                .foregroundColor(v2.ink)
                .onSubmit(openHighlighted)
                .onChange(of: appState.searchQuery) { _, _ in highlighted = 0 }
            Text("esc")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    @ViewBuilder
    private var results: some View {
        let matches = filteredResults
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionLabel
                    if matches.isEmpty {
                        Text("No matches.")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(v2.faint)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 24)
                    } else {
                        ForEach(Array(matches.enumerated()), id: \.element.id) { idx, entry in
                            V2SearchRow(entry: entry, highlighted: idx == highlighted) {
                                pick(entry)
                            }
                            .id(entry.id)
                        }
                    }
                }
            }
            .onChange(of: highlighted) { _, newValue in
                guard newValue < matches.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(matches[newValue].id, anchor: .center)
                }
            }
        }
        .background(
            // Arrow-key navigation. Buttons are invisible but live in the
            // responder chain because the input has focus inside the overlay.
            ZStack {
                Button("Up") {
                    let n = filteredResults.count
                    if n > 0 { highlighted = (highlighted - 1 + n) % n }
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                Button("Down") {
                    let n = filteredResults.count
                    if n > 0 { highlighted = (highlighted + 1) % n }
                }
                .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0).frame(width: 0, height: 0)
        )
    }

    private var sectionLabel: some View {
        Text(appState.searchQuery.isEmpty ? "RECENT SESSIONS" : "RESULTS")
            .font(.system(size: 9.5, weight: .regular, design: .monospaced))
            .kerning(1.2)
            .foregroundColor(v2.faint)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private var footer: some View {
        HStack(spacing: 18) {
            hint("↑↓", "navigate")
            hint("↵", "open")
            hint("esc", "close")
            Spacer()
            Text(footerSummary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).foregroundColor(v2.mute)
            Text(label).foregroundColor(v2.faint)
        }
        .font(.system(size: 10.5, design: .monospaced))
    }

    private var footerSummary: String {
        let total = allEntries.count
        let shown = filteredResults.count
        if appState.searchQuery.isEmpty {
            return "\(total) session\(total == 1 ? "" : "s") across \(store.projects.count) projects"
        }
        return "\(shown) of \(total) match"
    }

    private var allEntries: [V2HistoryEntry] {
        V2HistoryEntry.collect(from: store.projects)
    }

    private var filteredResults: [V2HistoryEntry] {
        let q = appState.searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let all = allEntries
        guard !q.isEmpty else { return Array(all.prefix(20)) }
        return all.filter {
            $0.title.lowercased().contains(q)
                || $0.projectName.lowercased().contains(q)
                || $0.sessionId.lowercased().contains(q)
        }
        .prefix(50)
        .map { $0 }
    }

    private func openHighlighted() {
        let m = filteredResults
        guard highlighted < m.count else { return }
        pick(m[highlighted])
    }

    private func pick(_ entry: V2HistoryEntry) {
        appState.openHistorySession(
            sessionId: entry.sessionId,
            projectCwd: entry.projectCwd,
            projectName: entry.projectName,
            title: entry.title
        )
        close()
    }

    private func close() {
        appState.searchOpen = false
        appState.searchQuery = ""
    }
}

private struct V2SearchRow: View {
    @Environment(\.v2) private var v2
    let entry: V2HistoryEntry
    let highlighted: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 13) {
                V2DovetailMark(size: 14)
                    .foregroundColor(v2.faint)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .kerning(-0.13)
                        .foregroundColor(v2.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 7) {
                        Text(entry.projectName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(v2.ink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(entry.relativeTime)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(v2.faint)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? v2.card : Color.clear)
        }
        .buttonStyle(.plain)
    }
}
