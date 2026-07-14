import SwiftUI

// MARK: - MCP Marketplace browser sheet

struct MCPMarketplaceView: View {
    let onInstall: (MCPDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [RegistryMCP] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var expanded: Set<String> = []
    @State private var searchTask: Task<Void, Never>?
    /// The identifier just tapped — flips its row to "installing…" so the
    /// click reads as acknowledged through the two back-to-back sheet
    /// transitions (this sheet dismissing, then the editor sheet presenting
    /// from the parent's onDismiss) before the editor actually appears. Only
    /// ever set on the guaranteed-success path (right before `dismiss()`),
    /// so it can never get stuck — a `makeDraft` failure leaves the row as a
    /// tappable "install" and surfaces `installError` instead.
    @State private var installingIdentifier: String?
    @State private var installError: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("MCP Marketplace")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Browse the official Model Context Protocol registry")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                V2ChipButton(label: "close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            Divider()

            // Search bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                TextField("Search MCPs (try 'supabase', 'github', 'database')…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if isLoading {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(Color.primary.opacity(0.04))
            .onChange(of: query) { _, _ in
                scheduleSearch()
            }
            .onAppear {
                if results.isEmpty { Task { await fetch(query: "") } }
            }

            Divider()

            // Body
            Group {
                if let err = errorMessage {
                    errorState(err)
                } else if results.isEmpty && !isLoading {
                    emptyState
                } else {
                    resultsList
                }
            }
        }
        .frame(width: 680, height: 560)
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
        .alert("Couldn't install", isPresented: Binding(
            get: { installError != nil },
            set: { if !$0 { installError = nil } }
        )) {
            Button("OK") { installError = nil }
        } message: {
            Text(installError ?? "")
        }
    }

    // MARK: - Results

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(results) { mcp in
                    mcpCard(mcp)
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func mcpCard(_ mcp: RegistryMCP) -> some View {
        let isExpanded = expanded.contains(mcp.id)

        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(mcp.displayName)
                            .font(.system(size: 14, weight: .semibold))
                        Text("v\(mcp.version)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    Text(mcp.name)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(mcp.description)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        if isExpanded { expanded.remove(mcp.id) }
                        else { expanded.insert(mcp.id) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(14)

            if isExpanded {
                Divider().opacity(0.5)
                installOptions(for: mcp)
                    .padding(14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func installOptions(for mcp: RegistryMCP) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Installable packages (index-based id to avoid duplicate-identifier ForEach crashes)
            let pkgs = mcp.packages.filter { ["npm", "pypi"].contains($0.registryType) }
            ForEach(Array(pkgs.enumerated()), id: \.offset) { _, pkg in
                installRow(
                    label: pkg.registryType.uppercased(),
                    labelColor: .orange,
                    identifier: pkg.identifier,
                    envRequirements: pkg.environmentVariables.map { ($0.name, $0.isRequired) },
                    isInstalling: installingIdentifier == pkg.identifier
                ) {
                    if let draft = MCPRegistry.makeDraft(from: mcp, package: pkg) {
                        installingIdentifier = pkg.identifier
                        onInstall(draft)
                        dismiss()
                    } else {
                        installError = "Couldn't install \"\(pkg.identifier)\" — the registry entry looks malformed."
                    }
                }
            }

            // Remote endpoints (index-based id for same reason)
            let rems = mcp.remotes.filter { ["streamable-http", "sse", "http"].contains($0.type) }
            ForEach(Array(rems.enumerated()), id: \.offset) { _, rem in
                installRow(
                    label: rem.type == "sse" ? "SSE" : "HTTP",
                    labelColor: rem.type == "sse" ? .cyan : .blue,
                    identifier: rem.url,
                    envRequirements: rem.headers.map { ($0.name, $0.isRequired) },
                    isInstalling: installingIdentifier == rem.url
                ) {
                    if let draft = MCPRegistry.makeDraft(from: mcp, remote: rem) {
                        installingIdentifier = rem.url
                        onInstall(draft)
                        dismiss()
                    } else {
                        installError = "Couldn't install \"\(rem.url)\" — the registry entry looks malformed."
                    }
                }
            }

            // Repo link — only render for http(s) URLs to prevent javascript:/file:// exploits
            if let repo = mcp.repositoryURL,
               let url = URL(string: repo),
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 10))
                    Link("View source", destination: url)
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
            }
        }
    }

    private func installRow(
        label: String,
        labelColor: Color,
        identifier: String,
        envRequirements: [(String, Bool)],
        isInstalling: Bool = false,
        onInstall: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(labelColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(labelColor.opacity(0.12), in: Capsule())

            VStack(alignment: .leading, spacing: 2) {
                Text(identifier)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !envRequirements.isEmpty {
                    let required = envRequirements.filter { $0.1 }.map { $0.0 }
                    let optional = envRequirements.filter { !$0.1 }.map { $0.0 }
                    if !required.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                            Text("Requires: \(required.joined(separator: ", "))")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.orange)
                    }
                    if !optional.isEmpty {
                        Text("Optional: \(optional.joined(separator: ", "))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            if isInstalling {
                Text("installing…")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
            } else {
                V2ChipButton(label: "install", prominent: true, action: onInstall)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Empty and error states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No results")
                .font(.system(size: 13, weight: .semibold))
            Text("Try a different search term.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("Couldn't load marketplace")
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            V2ChipButton(label: "try again") {
                Task { await fetch(query: query) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }

    // MARK: - Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let currentQuery = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms debounce
            guard !Task.isCancelled else { return }
            await fetch(query: currentQuery)
        }
    }

    private func fetch(query: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let mcps = try await MCPRegistry.search(query: query.isEmpty ? nil : query)
            // Discard stale response if the user has typed something new or cancelled
            guard !Task.isCancelled, query == self.query else { return }
            results = mcps
        } catch is CancellationError {
            // Ignore — a newer search is in progress
            return
        } catch {
            // Ignore stale error too
            guard !Task.isCancelled, query == self.query else { return }
            errorMessage = error.localizedDescription
            results = []
        }
        if !Task.isCancelled, query == self.query {
            isLoading = false
        }
    }
}
