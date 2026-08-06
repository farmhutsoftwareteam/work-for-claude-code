import SwiftUI
import AppKit

// MARK: - Marketplace models

struct MarketplacePlugin: Identifiable, Hashable {
    let id: String             // "<marketplace>/<name>"
    let marketplace: String
    let name: String
    let description: String
    let category: String?
    let author: String?
    let homepage: URL?

    var isInstalled: Bool = false
}

struct Marketplace: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
    let owner: String?
    var plugins: [MarketplacePlugin]
}

// MARK: - Loader

enum MarketplaceLoader {
    /// Parse every `.claude-plugin/marketplace.json` under ~/.claude/plugins/marketplaces/.
    static func loadAll() -> [Marketplace] {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
            .appendingPathComponent("plugins")
            .appendingPathComponent("marketplaces")
        guard let dirs = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return []
        }

        var result: [Marketplace] = []
        for dir in dirs {
            let manifest = dir.appendingPathComponent(".claude-plugin/marketplace.json")
            guard let data = try? Data(contentsOf: manifest),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let mpName = (obj["name"] as? String) ?? dir.lastPathComponent
            let desc = (obj["description"] as? String)
                ?? (obj["metadata"] as? [String: Any])?["description"] as? String
            let ownerName = (obj["owner"] as? [String: Any])?["name"] as? String
            let rawPlugins = obj["plugins"] as? [[String: Any]] ?? []

            let plugins = rawPlugins.compactMap { raw -> MarketplacePlugin? in
                guard let name = raw["name"] as? String else { return nil }
                let category = raw["category"] as? String
                let authorName = (raw["author"] as? [String: Any])?["name"] as? String
                    ?? (raw["author"] as? String)
                let homepage = (raw["homepage"] as? String).flatMap { URL(string: $0) }
                return MarketplacePlugin(
                    id: "\(mpName)/\(name)",
                    marketplace: mpName,
                    name: name,
                    description: (raw["description"] as? String) ?? "",
                    category: category,
                    author: authorName,
                    homepage: homepage
                )
            }

            result.append(Marketplace(
                id: mpName,
                name: mpName,
                description: desc,
                owner: ownerName,
                plugins: plugins.sorted { $0.name < $1.name }
            ))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Match installed plugins back against the marketplace listings so the UI
    /// can show the right install/uninstall state.
    static func annotateInstalled(_ markets: [Marketplace], installed: [ClaudePlugin]) -> [Marketplace] {
        let installedIds = Set(installed.map(\.id))  // "name@marketplace"
        return markets.map { m in
            var copy = m
            copy.plugins = m.plugins.map { p in
                var q = p
                q.isInstalled = installedIds.contains("\(p.name)@\(m.name)")
                return q
            }
            return copy
        }
    }
}

// MARK: - Install runner

/// One entry from `claude plugin marketplace list --json`. Carries `repo`,
/// which is how a featured pack resolves its real marketplace `name` (the two
/// differ: mattpocock/skills → name "mattpocock").
struct RegisteredMarketplace: Decodable, Hashable {
    let name: String
    let repo: String?
    let installLocation: String?
}

enum MarketplaceInstaller {
    enum Action: String {
        case install, uninstall, update
    }

    /// Shell out to `claude plugin <action> <plugin>@<marketplace>`.
    /// We don't block the UI on this; stdout/stderr stream back to the caller.
    static func run(_ action: Action, plugin: MarketplacePlugin) async throws -> String {
        try await runClaude(["plugin", action.rawValue, "\(plugin.name)@\(plugin.marketplace)"])
    }

    /// `claude plugin marketplace add <source>` — register a whole pack
    /// (marketplace) so its plugins become installable. `source` is an
    /// owner/repo shorthand, a git URL, or a local path. Idempotent enough for
    /// our use: re-adding a registered marketplace is tolerated by the caller.
    static func addMarketplace(_ source: String) async throws -> String {
        try await runClaude(["plugin", "marketplace", "add", source])
    }

    /// `claude plugin marketplace update [name]` — re-pull a registered
    /// marketplace from its source (no name = all). This is how a pack picks up
    /// newly published skills; a per-plugin `.update` then applies them.
    static func updateMarketplace(_ name: String?) async throws -> String {
        try await runClaude(["plugin", "marketplace", "update"] + (name.map { [$0] } ?? []))
    }

    /// `claude plugin marketplace list --json` decoded — the source of truth for
    /// mapping a pack's `repo` to its actually-registered marketplace `name`.
    /// Returns [] on any failure (caller treats "not registered" the same way).
    static func listMarketplaces() async -> [RegisteredMarketplace] {
        guard let out = try? await runClaude(["plugin", "marketplace", "list", "--json"]),
              let data = out.data(using: .utf8),
              let list = try? JSONDecoder().decode([RegisteredMarketplace].self, from: data)
        else { return [] }
        return list
    }

    /// Shared runner: resolve the `claude` binary, run it with the enriched
    /// dev-tool PATH, capture stdout/stderr, throw a readable error on nonzero
    /// exit. GUI apps inherit launchd's stripped PATH, and `claude plugin …`
    /// routinely shells out to node/npx/git — hence enrichedEnvironment().
    private static func runClaude(_ args: [String]) async throws -> String {
        let claude = resolveClaudeBinary()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claude)
        process.arguments = args
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        process.environment = Self.enrichedEnvironment()

        try process.run()
        process.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let msg = [stderr, stdout].filter { !$0.isEmpty }.joined(separator: "\n")
            throw NSError(
                domain: "MarketplaceInstaller",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: msg.isEmpty ? "Exited with status \(process.terminationStatus)" : msg]
            )
        }
        return stdout
    }

    private static func resolveClaudeBinary() -> String {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for p in candidates where FileManager.default.isExecutableFile(atPath: p) { return p }
        return "claude"  // Fallback — will fail with a clear error from Process
    }

    /// Same recipe as `TerminalsController.enrichedEnvironment`, in dict form
    /// suitable for `Process.environment`. Prepends common dev-tool bin dirs
    /// to PATH so subprocesses can find node/npx/git/uv.
    static func enrichedEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin",
            "\(home)/.claude/local",
            "\(home)/.cargo/bin",
            "\(home)/.volta/bin",
            "\(home)/.nvm/versions/node/current/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin"
        ]
        let fm = FileManager.default
        let existingPath = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingSet = Set(existingPath.split(separator: ":").map(String.init))
        let additions = candidates.filter { fm.fileExists(atPath: $0) && !existingSet.contains($0) }
        if !additions.isEmpty {
            env["PATH"] = additions.joined(separator: ":") + ":" + existingPath
        }
        return env
    }
}

// MARK: - Marketplace view

struct MarketplaceView: View {
    @EnvironmentObject var store: Store
    @State private var markets: [Marketplace] = []
    @State private var search = ""
    @State private var selectedMarketplace: String = "all"
    @State private var busy: Set<String> = []   // plugin ids currently installing/uninstalling
    @State private var runError: String?

    private var filteredPlugins: [MarketplacePlugin] {
        let pool = markets
            .filter { selectedMarketplace == "all" || $0.id == selectedMarketplace }
            .flatMap(\.plugins)
        if search.isEmpty { return pool.sorted { $0.name < $1.name } }
        return pool.filter {
            $0.name.localizedCaseInsensitiveContains(search) ||
            $0.description.localizedCaseInsensitiveContains(search) ||
            ($0.category ?? "").localizedCaseInsensitiveContains(search)
        }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $selectedMarketplace) {
                    Text("All marketplaces").tag("all")
                    ForEach(markets) { m in
                        Text(m.name).tag(m.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 220)

                Spacer()
                Text("\(filteredPlugins.count) plugin\(filteredPlugins.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            List {
                ForEach(filteredPlugins) { plugin in
                    DisclosureGroup {
                        pluginDetail(plugin)
                    } label: {
                        pluginRow(plugin)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
        .searchable(text: $search, prompt: "Search plugins")
        .navigationTitle("Marketplace")
        .task { await reload() }
        .alert("Couldn't complete",
               isPresented: Binding(get: { runError != nil }, set: { if !$0 { runError = nil } }),
               actions: { Button("OK") { runError = nil } },
               message: { Text(runError ?? "") })
    }

    private func reload() async {
        let raw = await Task.detached { MarketplaceLoader.loadAll() }.value
        let annotated = MarketplaceLoader.annotateInstalled(raw, installed: store.plugins)
        markets = annotated
    }

    // MARK: - Row + detail

    private func pluginRow(_ plugin: MarketplacePlugin) -> some View {
        HStack(spacing: 8) {
            Image(systemName: plugin.isInstalled ? "checkmark.circle.fill" : "puzzlepiece.extension")
                .foregroundStyle(plugin.isInstalled ? .green : .indigo)
                .frame(width: 16)
            Text(plugin.name)
                .font(.body.weight(.medium))
                .lineLimit(1)
            if let cat = plugin.category {
                Text(cat.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
            }
            Spacer()
            Text(plugin.marketplace)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func pluginDetail(_ plugin: MarketplacePlugin) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if !plugin.description.isEmpty {
                Text(plugin.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            HStack(spacing: 14) {
                if let author = plugin.author {
                    Label(author, systemImage: "person").font(.caption).foregroundStyle(.tertiary)
                }
                Label(plugin.marketplace, systemImage: "building.columns").font(.caption).foregroundStyle(.tertiary)
                if let homepage = plugin.homepage {
                    Link(destination: homepage) {
                        Label("Homepage", systemImage: "link").font(.caption)
                    }
                }
            }

            HStack(spacing: 6) {
                let busyThis = busy.contains(plugin.id)
                if plugin.isInstalled {
                    Button {
                        run(.uninstall, on: plugin)
                    } label: {
                        Label(busyThis ? "Uninstalling…" : "Uninstall", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyThis)

                    Button {
                        run(.update, on: plugin)
                    } label: {
                        Label(busyThis ? "Updating…" : "Update", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(busyThis)
                } else {
                    Button {
                        run(.install, on: plugin)
                    } label: {
                        Label(busyThis ? "Installing…" : "Install", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(busyThis)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func run(_ action: MarketplaceInstaller.Action, on plugin: MarketplacePlugin) {
        busy.insert(plugin.id)
        Task {
            do {
                _ = try await MarketplaceInstaller.run(action, plugin: plugin)
                await store.loadExtensions()
                await reload()
            } catch {
                runError = error.localizedDescription
            }
            busy.remove(plugin.id)
        }
    }
}
