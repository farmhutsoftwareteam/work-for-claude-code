import SwiftUI
import AppKit

// MARK: - Per-project Integrations panel
//
// The "add Linear to golf-projects in two clicks" surface. Curated cards for
// the popular MCPs, one-toggle scope (Just me vs My team), one-tap install.
// After install, if a Claude session is currently running in this project,
// we surface an inline "Restart needed" banner with a one-click respawn —
// MCPs only load at session startup, so without this users hit the silent
// "I added it but nothing happened" trap.

struct ProjectIntegrationsPanel: View {
    let project: Project
    @Binding var isPresented: Bool

    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController

    @AppStorage("integrationsScopeIsTeam") private var scopeIsTeam: Bool = false
    @State private var installing: Set<String> = []
    @State private var lastInstalled: Integration?
    @State private var error: String?

    /// Names of MCPs already installed at any scope visible to this project.
    /// We dim the install button for those.
    private var installedNames: Set<String> {
        var names = Set<String>()
        names.formUnion(store.standaloneMCPs.map(\.name))
        if let projectMCPs = store.projectMCPs[project.cwd] {
            names.formUnion(projectMCPs.map(\.name))
        }
        return names
    }

    /// True if any live terminal tab is running in this project's cwd.
    private var hasLiveSession: Bool {
        terminals.isProjectLive(project.cwd)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            scopeSelector
            Divider()
            integrationsList

            if let last = lastInstalled, hasLiveSession {
                Divider()
                restartBanner(for: last)
            }
        }
        .frame(width: 520, height: 540)
        .alert(
            "Install failed",
            isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } }),
            actions: { Button("OK") { error = nil } },
            message: { Text(error ?? "") }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Integrations")
                    .font(.system(size: 17, weight: .semibold))
                Text(project.displayName)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .background(Color.primary.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
    }

    // MARK: - Scope selector

    private var scopeSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("INSTALL FOR")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(.tertiary)

            Picker("", selection: $scopeIsTeam) {
                Text("Just me").tag(false)
                Text("My team (commit to repo)").tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)

            Text(scopeIsTeam
                 ? "Writes to \(project.displayName)/.mcp.json — anyone who clones the repo gets this MCP."
                 : "Available only in \(project.displayName), only to you. Stored under your ~/.claude.json."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - Integrations list

    private var integrationsList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Integration.curated) { integration in
                    integrationCard(integration)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private func integrationCard(_ integration: Integration) -> some View {
        let isInstalled = installedNames.contains(integration.mcpName)
        let isInstalling = installing.contains(integration.id)

        return HStack(alignment: .center, spacing: 12) {
            // Icon orb in the integration's brand colour. Real brand SVG when
            // we have one (Simple Icons pack, MIT, template-rendered so the
            // mark inherits the white tint over the brand-coloured orb), or
            // fall back to an SF Symbol for entries without a brand (e.g.
            // Filesystem).
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(integration.color)
                    .frame(width: 42, height: 42)
                if let asset = integration.logoAsset {
                    Image(asset)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: integration.symbolFallback)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(integration.name)
                    .font(.system(size: 13, weight: .semibold))
                Text(integration.tagline)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if integration.requiresOAuth {
                    Text("OAuth in browser on first use")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 8)

            if isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if isInstalling {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button("Install") { install(integration) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .opacity(isInstalled ? 0.55 : 1)
    }

    // MARK: - Restart banner

    private func restartBanner(for integration: Integration) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Restart Claude in this project to load \(integration.name)")
                    .font(.system(size: 12, weight: .semibold))
                Text("Your session is still running with the old MCP set.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Restart") { restartLiveSessions() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
    }

    // MARK: - Actions

    private func install(_ integration: Integration) {
        installing.insert(integration.id)
        Task {
            do {
                // "Just me" → `.local(cwd:)` (per-project, private to user),
                // not `.user` (every project). This matches `claude mcp add`'s
                // default and what users actually want: install Linear in
                // *this* project, not in every project on the machine.
                let scope: MCPConfigWriter.Scope = scopeIsTeam
                    ? .project(cwd: project.cwd)
                    : .local(cwd: project.cwd)
                try MCPConfigWriter.save(integration.draft, scope: scope)
                await store.reloadMCPs()
                lastInstalled = integration

                // For HTTP OAuth integrations: spawn a fresh Claude session
                // in this project and auto-send /mcp. The user sees the
                // browser pop for OAuth without manually opening a terminal,
                // typing slash commands, or remembering syntax.
                if integration.requiresOAuth, !hasLiveSession {
                    autoStartOAuth(for: integration)
                }
            } catch {
                self.error = error.localizedDescription
            }
            installing.remove(integration.id)
        }
    }

    /// Spawn a new tab and pre-type `/mcp` once Claude is ready. Closes the
    /// integrations sheet so the user lands directly on the live session
    /// where the OAuth picker will appear.
    private func autoStartOAuth(for integration: Integration) {
        let title = "\(project.displayName) (\(integration.name) auth)"
        let tabId = terminals.openNew(projectCwd: project.cwd, title: title)
        isPresented = false  // hand off to the live terminal
        Task {
            // Wait for Claude to draw its prompt, then type the slash command
            // for them. Claude itself handles the OAuth dance from here.
            _ = await terminals.sendInputWhenReady("/mcp\r", to: tabId)
        }
    }

    /// Re-spawn every live session in this project. We use SIGTERM via the
    /// controller's close path, then `openResume` so the conversation
    /// continues with the fresh MCP config. If the integration that was
    /// just installed needs OAuth, also auto-send `/mcp` to the first
    /// respawned tab so the user lands straight in the auth flow.
    private func restartLiveSessions() {
        let liveTabs = terminals.tabs.filter {
            $0.projectCwd == project.cwd && $0.isLive
        }
        let needsOAuth = lastInstalled?.requiresOAuth ?? false
        var firstRespawnedTabId: UUID?

        for (idx, tab) in liveTabs.enumerated() {
            let sessionId = tab.sessionId
            let title = tab.title
            terminals.close(tab.id, force: true)
            // Slight delay to let the PTY actually terminate before respawning
            // on the same JSONL file (matches our handleOpenExternal pattern).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 800_000_000)
                let newId: UUID
                if let sid = sessionId {
                    newId = terminals.openResume(sessionId: sid, projectCwd: project.cwd, title: title)
                } else {
                    newId = terminals.openNew(projectCwd: project.cwd, title: title)
                }
                if idx == 0 { firstRespawnedTabId = newId }
                // Trigger OAuth on the first respawned tab only.
                if idx == 0, needsOAuth {
                    _ = await terminals.sendInputWhenReady("/mcp\r", to: newId)
                }
            }
        }
        _ = firstRespawnedTabId  // captured for symmetry
        lastInstalled = nil
        isPresented = false
    }
}

// MARK: - Curated catalogue

/// A hand-picked set of popular MCPs. The full registry is still browsable
/// via the Marketplace tab — this list is the "happy path" for the common
/// integrations users actually ask for. Each entry maps to a known-good
/// MCP server we can install with zero CLI fiddling.
struct Integration: Identifiable {
    let id: String
    let mcpName: String
    let name: String
    let tagline: String
    /// SF Symbol fallback when no brand SVG is available (e.g. Filesystem).
    let symbolFallback: String
    /// Asset name in `Assets.xcassets` (LogoLinear, LogoNotion …). nil → use SF Symbol.
    let logoAsset: String?
    let color: Color
    let requiresOAuth: Bool
    let draft: MCPDraft

    /// Brand colours sourced from each company's published brand kit /
    /// Simple Icons hex value. Logos themselves come from the bundled
    /// Assets.xcassets entries (LogoLinear, LogoNotion, …) — pulled from
    /// Simple Icons' MIT-licensed pack and rendered template-style so the
    /// orb's background colour shows through behind the white mark.
    static let curated: [Integration] = [
        Integration(
            id: "linear",
            mcpName: "linear-server",
            name: "Linear",
            tagline: "Find, create, and update issues, projects, and comments.",
            symbolFallback: "list.bullet.rectangle",
            logoAsset: "LogoLinear",
            color: Color(red: 0.37, green: 0.42, blue: 0.82),  // #5E6AD2
            requiresOAuth: true,
            draft: MCPDraft(
                name: "linear-server",
                transport: .http(url: "https://mcp.linear.app/mcp"),
                env: [:]
            )
        ),
        Integration(
            id: "notion",
            mcpName: "notion",
            name: "Notion",
            tagline: "Read pages, create blocks, search the workspace.",
            symbolFallback: "doc.text",
            logoAsset: "LogoNotion",
            color: Color(red: 0, green: 0, blue: 0),  // #000000
            requiresOAuth: true,
            draft: MCPDraft(
                name: "notion",
                transport: .http(url: "https://mcp.notion.com/mcp"),
                env: [:]
            )
        ),
        Integration(
            id: "sentry",
            mcpName: "sentry",
            name: "Sentry",
            tagline: "Inspect issues, releases, and performance data.",
            symbolFallback: "exclamationmark.triangle.fill",
            logoAsset: "LogoSentry",
            color: Color(red: 0.22, green: 0.16, blue: 0.36),  // #362D59
            requiresOAuth: true,
            draft: MCPDraft(
                name: "sentry",
                transport: .http(url: "https://mcp.sentry.dev/mcp"),
                env: [:]
            )
        ),
        Integration(
            id: "github",
            mcpName: "github",
            name: "GitHub",
            tagline: "Browse repos, search code, manage issues and PRs.",
            symbolFallback: "chevron.left.forwardslash.chevron.right",
            logoAsset: "LogoGithub",
            color: Color(red: 0.07, green: 0.09, blue: 0.13),  // #181717
            requiresOAuth: false,
            draft: MCPDraft(
                name: "github",
                transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-github@latest"]),
                env: ["GITHUB_PERSONAL_ACCESS_TOKEN": ""]
            )
        ),
        Integration(
            id: "supabase",
            mcpName: "supabase",
            name: "Supabase",
            tagline: "Query your database, manage rows, run migrations.",
            symbolFallback: "tablecells",
            logoAsset: "LogoSupabase",
            color: Color(red: 0.24, green: 0.73, blue: 0.49),  // #3FCF8E
            requiresOAuth: false,
            draft: MCPDraft(
                name: "supabase",
                transport: .stdio(command: "npx", args: ["-y", "@supabase/mcp-server-supabase@latest"]),
                env: ["SUPABASE_ACCESS_TOKEN": ""]
            )
        ),
        Integration(
            id: "stripe",
            mcpName: "stripe",
            name: "Stripe",
            tagline: "Search customers, charges, payouts, and balance data.",
            symbolFallback: "creditcard",
            logoAsset: "LogoStripe",
            color: Color(red: 0.39, green: 0.40, blue: 0.95),  // #635BFF
            requiresOAuth: false,
            draft: MCPDraft(
                name: "stripe",
                transport: .stdio(command: "npx", args: ["-y", "@stripe/mcp@latest", "--tools=all"]),
                env: ["STRIPE_API_KEY": ""]
            )
        ),
        Integration(
            id: "filesystem",
            mcpName: "filesystem",
            name: "Filesystem",
            tagline: "Let Claude read and write files outside this project.",
            symbolFallback: "folder.fill",
            logoAsset: nil,                                  // no brand for "filesystem"
            color: Color(red: 0.40, green: 0.55, blue: 0.85),
            requiresOAuth: false,
            draft: MCPDraft(
                name: "filesystem",
                transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem@latest"]),
                env: [:]
            )
        ),
        Integration(
            id: "puppeteer",
            mcpName: "puppeteer",
            name: "Puppeteer",
            tagline: "Drive a headless browser for scraping and screenshots.",
            symbolFallback: "globe",
            logoAsset: "LogoPuppeteer",
            color: Color(red: 0.25, green: 0.55, blue: 0.20),  // #40B5A4-ish
            requiresOAuth: false,
            draft: MCPDraft(
                name: "puppeteer",
                transport: .stdio(command: "npx", args: ["-y", "@modelcontextprotocol/server-puppeteer@latest"]),
                env: [:]
            )
        )
    ]
}
