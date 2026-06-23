import SwiftUI
import AppKit

// MARK: - Unified session detail
//
// Renders whichever face of the session is relevant right now:
//   • If a live TerminalTab exists for this session → live embedded terminal
//   • Otherwise → ConversationView (historical messages)
//
// The key design goal: clicking a session never dumps the user into a
// separate nav destination. The detail pane simply *becomes* the session,
// whether that means a humming terminal or a scrollable log. We cross-fade
// between the two states so the transition feels like one object breathing,
// not two different screens.

struct SessionDetailView: View {
    let session: Session
    @EnvironmentObject var store: Store
    @EnvironmentObject var terminals: TerminalsController

    @State private var confirmCloseLive = false

    /// The live tab currently running this session, if any.
    private var liveTab: TerminalTab? {
        terminals.tabs.first { $0.sessionId == session.id && $0.isLive }
    }

    private var project: Project? {
        store.projects.first { $0.cwd == session.projectCwd }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            // No transition animation — the previous 280ms cross-fade made
            // every tab click feel laggy because SwiftUI had to wait for the
            // animation to finish before the next content was interactive.
            // The terminal switching instantly is preferable to the fade.
            content
        }
        .alert("End this session?",
               isPresented: $confirmCloseLive,
               actions: {
                   Button("End session", role: .destructive) {
                       if let id = liveTab?.id { terminals.close(id) }
                   }
                   Button("Keep running", role: .cancel) { }
               },
               message: {
                   Text("The Claude process will receive SIGTERM and the PTY will close. Scrollback goes away too.")
               })
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            // Status dot with soft pulse when live
            StatusDot(isLive: liveTab != nil)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(store.displayName(for: session))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if store.hasAlias(session) {
                        Image(systemName: "pencil.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor.opacity(0.6))
                            .help("Renamed in Atelier")
                    }
                }
                HStack(spacing: 8) {
                    if let project {
                        Label(project.displayName, systemImage: "folder")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text("·").foregroundStyle(.tertiary)
                    Text(stateLabel)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .tracking(0.5)
                        .foregroundStyle(stateColor)
                }
            }

            Spacer(minLength: 12)

            // Primary action
            if liveTab == nil {
                Button(action: resume) {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Menu {
                    Button("Restart session") {
                        if let id = liveTab?.id { terminals.restart(tabId: id) }
                    }
                    .help("Kill and respawn this session so it picks up newly-added MCPs, hooks, or skills")
                    Divider()
                    Button("End session", role: .destructive) {
                        confirmCloseLive = true
                    }
                    Divider()
                    Button("Open in Terminal.app") {
                        openExternal()
                    }
                } label: {
                    Label("Running", systemImage: "waveform")
                        .foregroundStyle(.green)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .frame(width: 110)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var stateLabel: String {
        liveTab != nil ? "LIVE" : "DORMANT"
    }

    private var stateColor: Color {
        liveTab != nil ? .green : .secondary
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let live = liveTab {
            // Identity is *just* the tab id — re-attaching the embedded view
            // is handled by the wrapper itself, no need to bump on every spawn.
            EmbeddedTerminalView(tabId: live.id)
                .id("live-\(live.id)")
        } else {
            ConversationView(session: session)
                .id("conversation-\(session.id)")
        }
    }

    // MARK: - Actions

    private func resume() {
        guard let project else { return }
        terminals.requestOpenResume(
            sessionId: session.id,
            projectCwd: project.cwd,
            title: store.displayName(for: session)
        )
    }

    private func openExternal() {
        guard let live = liveTab, let project,
              let session = project.sessions.first(where: { $0.id == live.sessionId ?? "" })
        else { return }
        terminals.close(live.id, force: true)
        Launcher.resume(session, in: project)
    }
}

// MARK: - Tiny UI helpers

/// Soft-pulsing green dot when live, flat gray when dormant.
/// Defers to the shared `LivePulseDot` so animation lifecycle (start on
/// appear, stop on disappear) is handled in one place. Toggling `isLive`
/// swaps the entire view via SwiftUI's `if`, which gives us a clean
/// teardown of any prior animation.
private struct StatusDot: View {
    let isLive: Bool

    var body: some View {
        if isLive {
            LivePulseDot(size: 10)
        } else {
            Circle()
                .fill(Color.secondary.opacity(0.35))
        }
    }
}

