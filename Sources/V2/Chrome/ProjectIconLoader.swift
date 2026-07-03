// Project favicons for tabs + rail — the Chrome insight applied to projects.
// A logo is discovered ONLY at canonical locations (public/favicon.*, Next's
// app/favicon.ico, Expo's assets/icon.png, …) — never a fuzzy "*logo*" hunt,
// which is how you end up rendering a 4000px marketing banner. Every hit must
// pass hard quality gates before a pixel shows: decodes, roughly square
// (aspect ≤ 1.35 — kills wordmark banners), 16..1024px, file ≤ 1MB. Then it's
// downscaled once to a crisp 32px thumbnail and cached (negative results too).
// Fail any gate → show nothing new; the dot/monogram baseline stays.
//
// Perf: discovery (stat calls) runs off-main; the one-time 32px decode happens
// on main only after a path passed the cheap checks. One publish per icon
// ever — nothing per-render.

import AppKit
import SwiftUI

@MainActor
final class ProjectIconLoader: ObservableObject {
    static let shared = ProjectIconLoader()

    /// cwd → downscaled 32px icon. Misses are in `attempted` (negative cache).
    @Published private(set) var icons: [String: NSImage] = [:]
    private var attempted: Set<String> = []

    /// Canonical, conventional locations only — grow the list, never the fuzziness.
    nonisolated private static let candidates: [String] = [
        "public/favicon.svg", "public/favicon.png", "public/favicon.ico",
        "app/favicon.ico", "src/app/favicon.ico",          // next.js app router
        "favicon.ico", "favicon.png",
        "public/apple-touch-icon.png", "apple-touch-icon.png",
        "assets/icon.png", "assets/images/icon.png",       // expo / rn
        "public/logo.svg", "public/logo.png", "public/icon.png",
        "src/assets/logo.svg", "src/assets/logo.png", "assets/logo.png",
        "static/favicon.png", "static/favicon.ico",
        "public/images/logo.png",
        "docs/favicon-32.png",
    ]

    /// Cached lookup; on first miss schedules discovery. Safe to call from
    /// `body` — it's a dictionary read plus (once per project) a task spawn.
    func icon(for cwd: String) -> NSImage? {
        if let hit = icons[cwd] { return hit }
        guard !attempted.contains(cwd) else { return nil }
        attempted.insert(cwd)
        Task.detached(priority: .utility) {
            // Off-main: cheap stat pass over the allowlist.
            let path = Self.discover(cwd: cwd)
            await MainActor.run {
                guard let path, let img = Self.validatedThumbnail(at: path) else { return }
                self.icons[cwd] = img
            }
        }
        return nil
    }

    /// First allowlisted file that exists with a sane byte size.
    nonisolated private static func discover(cwd: String) -> String? {
        let fm = FileManager.default
        for c in candidates {
            let p = cwd + "/" + c
            guard let attrs = try? fm.attributesOfItem(atPath: p),
                  let size = attrs[.size] as? Int,
                  (100...1_000_000).contains(size)
            else { continue }
            return p
        }
        return nil
    }

    /// Decode + quality gates + one-time downscale to 32px. Main-actor because
    /// NSImage isn't Sendable; this runs once per project ever.
    private static func validatedThumbnail(at path: String) -> NSImage? {
        guard let img = NSImage(contentsOfFile: path) else { return nil }

        // Pixel dimensions when raster; point size for vectors (SVG reps
        // report 0 pixels). Both must be square-ish and within bounds.
        let rep = img.representations.first
        let w = CGFloat((rep?.pixelsWide ?? 0) > 0 ? CGFloat(rep!.pixelsWide) : img.size.width)
        let h = CGFloat((rep?.pixelsHigh ?? 0) > 0 ? CGFloat(rep!.pixelsHigh) : img.size.height)
        guard w > 0, h > 0 else { return nil }
        guard min(w, h) >= 16, max(w, h) <= 1024 else { return nil }
        guard max(w, h) / min(w, h) <= 1.35 else { return nil }   // no banners

        // Downscale once, aspect-fit into 32×32.
        let target: CGFloat = 32
        let scale = min(target / w, target / h)
        let drawSize = NSSize(width: w * scale, height: h * scale)
        let thumb = NSImage(size: NSSize(width: target, height: target))
        thumb.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let origin = NSPoint(x: (target - drawSize.width) / 2, y: (target - drawSize.height) / 2)
        img.draw(in: NSRect(origin: origin, size: drawSize),
                 from: .zero, operation: .sourceOver, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }
}
