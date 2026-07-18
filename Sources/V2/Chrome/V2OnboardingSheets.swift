// Real onboarding for the two states that previously dead-ended in plain,
// unclickable red text: a missing CLI binary, and (Claude only — Codex
// already had this) never having signed in. User report, 2026-07-18: not
// every user arrives with either provider installed or authenticated, and
// there was no path forward from that besides reading a sentence and
// leaving the app.
//
// Deliberately NOT auto-executing the install script: piping a downloaded
// curl to bash unattended from inside the app is a real trust decision,
// not a UI one. The user copies the command and runs it themselves, in
// their own terminal, having seen exactly what it is.

import SwiftUI

private struct V2SheetChrome<Content: View>: View {
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    let provider: V2AgentProvider
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                V2ProviderMark(provider: provider, size: 18)
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(v2.ink)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundColor(v2.faint)
            }
            content()
        }
        .padding(22)
        .frame(width: 440)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

/// Shown when a provider's CLI binary isn't found on PATH at all — was
/// previously just "`codex` not found on PATH — install Codex CLI" with no
/// way to act on it.
struct V2ProviderInstallSheet: View {
    @Environment(\.v2) private var v2
    @EnvironmentObject private var appState: V2AppState
    let provider: V2AgentProvider
    @State private var copied = false
    @State private var rechecking = false

    private var installCommand: String {
        switch provider {
        case .claude: return "curl -fsSL https://claude.ai/install.sh | bash"
        case .codex: return "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
        }
    }
    private var docsURL: URL {
        switch provider {
        case .claude: return URL(string: "https://code.claude.com/docs/en/setup")!
        case .codex: return URL(string: "https://developers.openai.com/codex/cli")!
        }
    }
    private var isNowInstalled: Bool {
        provider == .claude ? appState.claudeBinary != nil : appState.codexBinary != nil
    }

    var body: some View {
        V2SheetChrome(provider: provider, title: "\(provider.displayName) isn't installed") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Atelier wraps the real \(provider.displayName) command-line tool — it needs to be installed once, outside the app. Run this in Terminal:")
                    .font(.system(size: 12))
                    .foregroundColor(v2.mute)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Text(installCommand)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.ink)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button {
                        V2Clipboard.copy(installCommand)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    } label: {
                        Text(copied ? "copied" : "copy")
                            .font(.system(size: 10.5, design: .monospaced))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(v2.ink)
                }
                .padding(10)
                .background(v2.card)
                .overlay(Rectangle().stroke(v2.line, lineWidth: 1))

                Link(destination: docsURL) {
                    Text("Full install guide →")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(v2.mute)
                }

                HStack {
                    Spacer()
                    Button {
                        rechecking = true
                        Task {
                            await appState.resolveBinary()
                            rechecking = false
                        }
                    } label: {
                        Text(rechecking ? "checking…" : (isNowInstalled ? "✓ found — you're set" : "I've installed it — check again"))
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(v2.paper)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(v2.ink)
                    }
                    .buttonStyle(.plain)
                    .disabled(rechecking)
                }
            }
        }
    }
}

/// Claude's real "Sign in" flow — see ClaudeAuthManager for the underlying
/// mechanism. Mirrors Codex's existing loginView so both providers feel
/// like the same kind of app, adapted for Claude's paste-a-code shape
/// instead of Codex's pure browser round trip.
struct V2ClaudeSignInSheet: View {
    @Environment(\.v2) private var v2
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: V2AppState
    // V2AppState is per-window (no singleton) — the caller passes its own
    // appState.claudeAuth in explicitly so @ObservedObject observes the
    // real, live instance rather than a throwaway fallback.
    @ObservedObject var auth: ClaudeAuthManager
    @State private var code = ""

    var body: some View {
        V2SheetChrome(provider: .claude, title: "Sign in to Claude") {
            VStack(alignment: .leading, spacing: 14) {
                switch auth.loginState {
                case .idle:
                    Text("Opens claude.ai in your browser. Claude stores and refreshes your credentials — Atelier never sees your password.")
                        .font(.system(size: 12))
                        .foregroundColor(v2.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    startButton("Sign in with Claude")

                case .waitingForURL:
                    statusLine("Starting sign-in…", spinning: true)

                case .awaitingCode(let url):
                    Text("Complete sign-in at the page that just opened, then paste the code it gives you.")
                        .font(.system(size: 12))
                        .foregroundColor(v2.mute)
                        .fixedSize(horizontal: false, vertical: true)
                    Link(destination: url) {
                        Text("Reopen sign-in page →")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(v2.mute)
                    }
                    HStack(spacing: 8) {
                        TextField("paste code here", text: $code)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(8)
                            .background(v2.card)
                            .overlay(Rectangle().stroke(v2.line, lineWidth: 1))
                            .onSubmit(submit)
                        Button("continue") { submit() }
                            .buttonStyle(.plain)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(v2.paper)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(code.isEmpty ? v2.line2 : v2.ink)
                            .disabled(code.isEmpty)
                    }

                case .submitting:
                    statusLine("Confirming…", spinning: true)

                case .failed(let message):
                    Text(message)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundColor(v2.del)
                        .fixedSize(horizontal: false, vertical: true)
                    startButton("Try again")
                }
            }
        }
        .onChange(of: auth.status) { _, newStatus in
            if case .loggedIn = newStatus { dismiss() }
        }
    }

    private func startButton(_ label: String) -> some View {
        Button {
            guard let binary = appState.claudeBinary else { return }
            auth.beginLogin(binary: binary)
        } label: {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(v2.paper)
                .padding(.horizontal, 16).padding(.vertical, 9)
                .background(v2.ink)
        }
        .buttonStyle(.plain)
    }

    private func statusLine(_ text: String, spinning: Bool) -> some View {
        HStack(spacing: 9) {
            if spinning { ProgressView().controlSize(.small) }
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundColor(v2.mute)
        }
    }

    private func submit() {
        guard !code.isEmpty else { return }
        auth.submitCode(code)
        code = ""
    }
}
