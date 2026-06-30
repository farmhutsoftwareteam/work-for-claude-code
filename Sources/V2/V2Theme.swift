// Atelier v2 color tokens. Single source of truth for every v2 view.
//
// Light + dark palettes captured verbatim from design/chat-states.dc.html.
// When the design changes, edit here once, not in individual views.

import SwiftUI

struct V2Palette {
    let ink: Color
    let paper: Color
    let paper2: Color
    let paper3: Color
    let card: Color
    let desk: Color
    let line: Color
    let line2: Color
    let mute: Color
    let faint: Color
    let add: Color
    let addBg: Color
    let del: Color
    let delBg: Color
    /// "Token" chip — file paths, refs, shas, inline code. The agent-vocabulary
    /// primitive (design: Agent vocabulary.dc.html).
    let tok: Color
    let tokInk: Color
}

enum V2Theme {
    static let light = V2Palette(
        ink:    Color(red: 0x1b/255.0, green: 0x1c/255.0, blue: 0x1e/255.0),
        paper:  Color(red: 0xe9/255.0, green: 0xea/255.0, blue: 0xe8/255.0),
        paper2: Color(red: 0xf3/255.0, green: 0xf4/255.0, blue: 0xf2/255.0),
        paper3: Color(red: 0xdc/255.0, green: 0xde/255.0, blue: 0xdb/255.0),
        card:   Color(red: 0xfb/255.0, green: 0xfb/255.0, blue: 0xfa/255.0),
        desk:   Color(red: 0xcf/255.0, green: 0xd0/255.0, blue: 0xce/255.0),
        line:   Color.black.opacity(0.16),
        line2:  Color.black.opacity(0.30),
        mute:   Color.black.opacity(0.54),
        faint:  Color.black.opacity(0.38),
        add:    Color(red: 0x3f/255.0, green: 0x6f/255.0, blue: 0x57/255.0),
        addBg:  Color(red: 0x3f/255.0, green: 0x6f/255.0, blue: 0x57/255.0).opacity(0.10),
        del:    Color(red: 0x9c/255.0, green: 0x52/255.0, blue: 0x49/255.0),
        delBg:  Color(red: 0x9c/255.0, green: 0x52/255.0, blue: 0x49/255.0).opacity(0.10),
        tok:    Color(red: 0xdd/255.0, green: 0xe0/255.0, blue: 0xdb/255.0),
        tokInk: Color(red: 0x2c/255.0, green: 0x2e/255.0, blue: 0x2b/255.0)
    )

    static let dark = V2Palette(
        ink:    Color(red: 0xe7/255.0, green: 0xe8/255.0, blue: 0xe5/255.0),
        paper:  Color(red: 0x1c/255.0, green: 0x1d/255.0, blue: 0x1f/255.0),
        paper2: Color(red: 0x24/255.0, green: 0x25/255.0, blue: 0x28/255.0),
        paper3: Color(red: 0x16/255.0, green: 0x17/255.0, blue: 0x19/255.0),
        card:   Color(red: 0x2a/255.0, green: 0x2b/255.0, blue: 0x2e/255.0),
        desk:   Color(red: 0x0e/255.0, green: 0x0f/255.0, blue: 0x10/255.0),
        line:   Color.white.opacity(0.14),
        line2:  Color.white.opacity(0.26),
        mute:   Color.white.opacity(0.56),
        faint:  Color.white.opacity(0.40),
        add:    Color(red: 0x7f/255.0, green: 0xb8/255.0, blue: 0x9a/255.0),
        addBg:  Color(red: 0x7f/255.0, green: 0xb8/255.0, blue: 0x9a/255.0).opacity(0.13),
        del:    Color(red: 0xd3/255.0, green: 0x91/255.0, blue: 0x89/255.0),
        delBg:  Color(red: 0xd3/255.0, green: 0x91/255.0, blue: 0x89/255.0).opacity(0.13),
        tok:    Color(red: 0x33/255.0, green: 0x35/255.0, blue: 0x2f/255.0),
        tokInk: Color(red: 0xcd/255.0, green: 0xd0/255.0, blue: 0xc8/255.0)
    )
}

private struct V2PaletteKey: EnvironmentKey {
    static let defaultValue: V2Palette = V2Theme.light
}

extension EnvironmentValues {
    var v2: V2Palette {
        get { self[V2PaletteKey.self] }
        set { self[V2PaletteKey.self] = newValue }
    }
}

// MARK: - Theme choice (persisted)

/// User's theme preference. Persisted via @AppStorage under "v2.theme".
/// `.system` follows macOS effective appearance via the active window.
enum V2ThemeChoice: String, CaseIterable, Identifiable {
    case light
    case dark
    case system

    var id: String { rawValue }

    var label: String { rawValue }

    /// Resolve to a concrete palette given the system's current colorScheme
    /// (passed in by the root view via the environment).
    func palette(systemColorScheme: ColorScheme) -> V2Palette {
        switch self {
        case .light:  return V2Theme.light
        case .dark:   return V2Theme.dark
        case .system: return systemColorScheme == .dark ? V2Theme.dark : V2Theme.light
        }
    }

    /// What to pass to .preferredColorScheme. Nil for .system so SwiftUI
    /// reads the OS appearance and lets controls render natively.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .light:  return .light
        case .dark:   return .dark
        case .system: return nil
        }
    }

    /// Icon shown in the title-bar toggle.
    var icon: String {
        switch self {
        case .light:  return "sun.max"
        case .dark:   return "moon"
        case .system: return "circle.lefthalf.filled"
        }
    }

    /// Next choice in the cycle when the title-bar button is clicked.
    var next: V2ThemeChoice {
        switch self {
        case .light:  return .dark
        case .dark:   return .system
        case .system: return .light
        }
    }
}
