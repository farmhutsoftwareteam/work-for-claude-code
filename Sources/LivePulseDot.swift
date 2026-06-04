import SwiftUI

/// A tiny solid colored dot inside a soft halo — "something is alive here".
/// No animation. Reads as "live" instantly without the noisy pulsating that
/// appears in lesser apps. Same name kept so callsites don't churn.
///
/// The halo is a fixed-opacity ring around the dot — it gives the indicator
/// presence without burning CPU on a perpetual `repeatForever` animation.
struct LivePulseDot: View {
    var size: CGFloat = 6
    var color: Color = .green

    var body: some View {
        ZStack {
            // Soft halo — sized 2× the dot, low opacity. Fixed, never animates.
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: size * 2.4, height: size * 2.4)
            // The dot itself — full colour, slight inner highlight for depth.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [color.opacity(0.95), color.opacity(0.75)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                )
        }
        // Bound the layout footprint to just the dot itself so the halo
        // doesn't push surrounding text around — the halo is decorative,
        // not part of the layout box.
        .frame(width: size, height: size)
    }
}
