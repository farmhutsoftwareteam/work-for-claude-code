// Picker sheet for "Connect & choose project…" — the sign-in-then-pick flow
// Supabase's own docs make possible: list_projects only works on the
// UNSCOPED connection (a project_ref in the URL deliberately disables
// account-level tools). Shown after sign-in succeeds; picking a project
// closes this and hands the caller a ready-to-save draft (scoped URL +
// read-only choice) — the caller opens the normal MCPEditor with it, same
// review-before-save step every other install path already goes through.

import SwiftUI

struct V2SupabaseProjectPicker: View {
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    let claudeBinary: URL
    let onPick: (SupabaseProject, _ readOnly: Bool) -> Void

    private enum LoadState {
        case loading
        case loaded([SupabaseProject])
        case failed(String)
    }
    @State private var state: LoadState = .loading
    @State private var readOnly = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(v2.line).frame(height: 1)
            content
        }
        .frame(width: 420, height: 460)
        .background(v2.paper)
        .task { await load() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Choose a Supabase project")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(v2.ink)
                Text("Signed in — pick which project this connects to.")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(v2.faint)
            }
            Spacer()
            V2ChipButton(label: "cancel") { dismiss() }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: 11) {
                V2PulseDot(size: 9, color: v2.ink)
                Text("Listing your Supabase projects…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(v2.mute)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 11) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20))
                    .foregroundColor(v2.del)
                Text(message)
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.mute)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                V2ChipButton(label: "try again") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded(let projects):
            if projects.isEmpty {
                Text("No Supabase projects found on this account.")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(v2.faint)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(projects) { project in
                                Button {
                                    onPick(project, readOnly)
                                    dismiss()
                                } label: {
                                    row(project)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Rectangle().fill(v2.line).frame(height: 1)
                    Toggle("Read-only (recommended)", isOn: $readOnly)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.mute)
                        .padding(14)
                }
            }
        }
    }

    private func row(_ project: SupabaseProject) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(v2.ink)
                if let org = project.organizationName {
                    Text(org)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(v2.faint)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(v2.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(v2.card)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(v2.line).frame(height: 1) }
    }

    private func load() async {
        state = .loading
        do {
            let projects = try await SupabaseProjectDiscovery.listProjects(claudeBinary: claudeBinary)
            state = .loaded(projects)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
