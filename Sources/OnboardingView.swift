import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Onboarding — dark, warm, single screen

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var appeared = false
    @State private var launchAtLogin = true

    // Stagger indices for entrance animation
    private func delay(_ index: Int) -> Animation {
        .spring(response: 0.55, dampingFraction: 0.82).delay(Double(index) * 0.09)
    }

    var body: some View {
        ZStack {
            // Layer 1: Animated mesh background
            backgroundLayer

            // Layer 2: Content
            VStack(spacing: 0) {
                Spacer()
                    .frame(minHeight: 24)

                // App identity
                VStack(spacing: 20) {
                    // App icon from bundle resources
                    Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 88, height: 88)
                        .shadow(color: .black.opacity(0.4), radius: 20, y: 8)
                        .stagger(0, appeared: appeared)

                    VStack(spacing: 8) {
                        Text("Work")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91)) // warm ivory
                            .stagger(1, appeared: appeared)

                        Text("Every Claude Code session. Always ready.")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.5))
                            .stagger(2, appeared: appeared)
                    }
                }

                Spacer().frame(height: 44)

                // Feature cards
                HStack(spacing: 16) {
                    FeatureCard(
                        icon: "folder.fill",
                        title: "Browse",
                        detail: "Your projects appear as you work. Zero setup."
                    )
                    .stagger(3, appeared: appeared)

                    FeatureCard(
                        icon: "text.bubble.fill",
                        title: "Read",
                        detail: "Revisit any conversation in full, right from your Mac."
                    )
                    .stagger(4, appeared: appeared)

                    FeatureCard(
                        icon: "play.fill",
                        title: "Resume",
                        detail: "Pick up right where you left off in Terminal."
                    )
                    .stagger(5, appeared: appeared)
                }
                .padding(.horizontal, 48)

                Spacer().frame(height: 36)

                // Options row
                VStack(spacing: 12) {
                    Toggle(isOn: $launchAtLogin) {
                        Text("Start Work when I log in")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.5))
                    }
                    .toggleStyle(.checkbox)
                    .colorScheme(.dark)

                    HStack(spacing: 5) {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 9))
                        Text("macOS will ask to allow Terminal access")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91).opacity(0.25))
                }
                .stagger(6, appeared: appeared)

                Spacer().frame(height: 28)

                // CTA
                Button(action: completeOnboarding) {
                    Text("Open Work")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color(red: 0.96, green: 0.94, blue: 0.91)) // warm ivory
                        .padding(.horizontal, 40)
                        .padding(.vertical, 12)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 0.27, green: 0.42, blue: 0.78),
                                                 Color(red: 0.20, green: 0.33, blue: 0.65)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .shadow(color: Color(red: 0.25, green: 0.38, blue: 0.72).opacity(0.35),
                                        radius: 12, y: 4)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [])
                .stagger(7, appeared: appeared)

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 480)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation { appeared = true }
        }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5],
                    [Float(0.5 + 0.08 * cos(t * 0.3)),
                     Float(0.5 + 0.08 * sin(t * 0.25))],
                    [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Color(red: 0.06, green: 0.06, blue: 0.07),
                    Color(red: 0.07, green: 0.07, blue: 0.08),
                    Color(red: 0.06, green: 0.06, blue: 0.07),

                    Color(red: 0.07, green: 0.07, blue: 0.08),
                    Color(red: 0.09, green: 0.10, blue: 0.16), // subtle blue-graphite glow
                    Color(red: 0.07, green: 0.07, blue: 0.08),

                    Color(red: 0.05, green: 0.05, blue: 0.06),
                    Color(red: 0.06, green: 0.06, blue: 0.07),
                    Color(red: 0.05, green: 0.05, blue: 0.06),
                ]
            )
            .ignoresSafeArea()
        }
    }

    // MARK: - Actions

    private func completeOnboarding() {
        if launchAtLogin {
            try? SMAppService.mainApp.register()
        }

        // Trigger Terminal permission prompt off the main thread
        DispatchQueue.global(qos: .userInitiated).async {
            let script = """
            tell application "Terminal"
                return name
            end tell
            """
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
            }
        }
        onComplete()
    }
}

// MARK: - Feature card

private struct FeatureCard: View {
    let icon: String
    let title: String
    let detail: String

    @State private var hovering = false

    private let ivory = Color(red: 0.96, green: 0.94, blue: 0.91)
    private let accent = Color(red: 0.27, green: 0.42, blue: 0.78)

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22))
                .foregroundStyle(ivory.opacity(hovering ? 0.9 : 0.7))
                .frame(width: 44, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ivory.opacity(hovering ? 0.08 : 0.04))
                )

            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ivory.opacity(0.85))

                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(ivory.opacity(0.35))
                    .multilineTextAlignment(.center)
                    .lineSpacing(1.5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(ivory.opacity(hovering ? 0.05 : 0.025))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(
                            hovering ? accent.opacity(0.25) : ivory.opacity(0.06),
                            lineWidth: 0.5
                        )
                )
        )
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
    }
}

// MARK: - Staggered entrance modifier

private struct StaggerModifier: ViewModifier {
    let index: Int
    let appeared: Bool

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 16)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.82)
                    .delay(Double(index) * 0.08),
                value: appeared
            )
    }
}

private extension View {
    func stagger(_ index: Int, appeared: Bool) -> some View {
        modifier(StaggerModifier(index: index, appeared: appeared))
    }
}

// MARK: - Permission check utility

enum PermissionCheck {
    static var hasTerminalPermission: Bool {
        let script = """
        tell application "Terminal"
            return name
        end tell
        """
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else { return false }
        appleScript.executeAndReturnError(&error)
        return error == nil
    }
}
