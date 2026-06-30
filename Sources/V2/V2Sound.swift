// Sound cues for the moments a tab needs your attention while you're elsewhere
// — the same two "loud" states the Tab-states design calls out: a turn finished
// while you were away (done), and a turn is blocked on your approval (needs you).
//
// Uses the built-in macOS system sounds (no notification permission, no
// entitlement — NSSound just plays audio, respecting the user's alert volume).
// Off-by-... no: default ON, toggled from the title bar. Only fires for a tab
// you're NOT currently looking at, so it never beeps at work you can already see.

import AppKit

enum V2Sound {
    enum Cue {
        case done       // a background turn finished
        case needsYou   // a background turn is blocked on approval

        /// A macOS system sound name (/System/Library/Sounds). `done` is a gentle
        /// chime; `needsYou` is more insistent since it's blocking you.
        var systemName: String {
            switch self {
            case .done:     return "Glass"
            case .needsYou: return "Funk"
            }
        }
    }

    private static let key = "v2.soundEnabled"

    /// Whether attention sounds play. Default ON. Persisted in UserDefaults so it
    /// survives launches; the title-bar speaker toggle writes here.
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func play(_ cue: Cue) {
        guard enabled else { return }
        NSSound(named: cue.systemName)?.play()
    }
}
