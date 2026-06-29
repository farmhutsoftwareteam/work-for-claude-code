// Brand glyphs for MCP servers. Resolves a server (by name, and optionally its
// URL host) to a bundled monochrome Simple-Icons template SVG in
// Assets.xcassets, tinted to match the panel's state. Unknown services fall
// back to a letter monogram so every row still reads as a distinct, intentional
// mark rather than an anonymous square.
//
// Logos are the MIT-licensed Simple Icons set — same source as the v1
// integrations panel's LogoLinear / LogoSupabase / … assets, which this extends.

import SwiftUI

struct V2ServiceLogo: View {
    let name: String
    var host: String? = nil
    var size: CGFloat = 16
    var tint: Color

    var body: some View {
        if let asset = Self.asset(forName: name, host: host) {
            Image(asset)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundColor(tint)
        } else {
            // Monogram fallback — first letter of the service in a bordered
            // square. Distinct per service, works for anything (custom servers,
            // local stdio tools) with zero assets.
            Text(Self.monogram(name))
                .font(.system(size: size * 0.6, weight: .semibold, design: .monospaced))
                .foregroundColor(tint)
                .frame(width: size, height: size)
                .overlay(Rectangle().stroke(tint.opacity(0.45), lineWidth: 1))
        }
    }

    // MARK: - Resolution

    /// Substring keyword (matched against the name + URL host) → asset name.
    /// Ordered so more specific multi-word keys win before generic ones.
    static func asset(forName name: String, host: String? = nil) -> String? {
        let hay = (name + " " + (host ?? "")).lowercased()
        for (key, asset) in table where hay.contains(key) { return asset }
        return nil
    }

    private static let table: [(String, String)] = [
        // Specific / multi-word first.
        ("google calendar", "LogoGoogleCalendar"),
        ("googlecalendar",  "LogoGoogleCalendar"),
        ("calendar.google", "LogoGoogleCalendar"),
        ("google drive",    "LogoGoogleDrive"),
        ("googledrive",     "LogoGoogleDrive"),
        ("drive.google",    "LogoGoogleDrive"),
        ("gmail",           "LogoGmail"),
        ("mail.google",     "LogoGmail"),
        // Single-keyword brands.
        ("linear",    "LogoLinear"),
        ("vercel",    "LogoVercel"),
        ("supabase",  "LogoSupabase"),
        ("notion",    "LogoNotion"),
        ("sentry",    "LogoSentry"),
        ("github",    "LogoGithub"),
        ("stripe",    "LogoStripe"),
        ("puppeteer", "LogoPuppeteer"),
        ("expo",      "LogoExpo"),
        ("ableton",   "LogoAbleton"),
        ("slack",     "LogoSlack"),
        ("anthropic", "LogoClaude"),
        ("claude",    "LogoClaude"),
    ]

    static func monogram(_ name: String) -> String {
        for ch in name where ch.isLetter || ch.isNumber {
            return String(ch).uppercased()
        }
        return "•"
    }

    /// URL host for http/sse transports (nil for stdio/sdk), used to recognise
    /// a service when its server name is generic (e.g. "mcp" pointing at
    /// vercel.com).
    static func host(of transport: MCPServer.Transport) -> String? {
        switch transport {
        case .http(let url), .sse(let url): return URL(string: url)?.host
        default: return nil
        }
    }
}
