import Foundation

/// One file the agent edited/created this session — accumulated on StreamSession
/// (#41, the "what changed this session" rollup). Session-scoped: survives a
/// `--resume` restart in the same tab, resets on `/clear`. Distinct from the
/// project working-tree git status (V2ProjectChanges) — this is keyed to which
/// files the agent touched in THIS conversation, success only.
struct V2SessionChangeEntry: Identifiable, Equatable, Sendable {
    enum Op: String, Sendable {
        case create, edit, multiEdit, notebook

        /// Uppercase op tag for the V2Pill (agent vocabulary).
        var label: String {
            switch self {
            case .create:    return "CREATE"
            case .edit:      return "EDIT"
            case .multiEdit: return "MULTIEDIT"
            case .notebook:  return "NOTEBOOK"
            }
        }
    }

    /// Absolute, standardized path (the changeset key).
    let path: String
    /// The op on first touch (create wins over a later edit).
    let op: Op
    /// Total successful edits across the session (MultiEdit counts its nested edits).
    var edits: Int
    let firstTouchedAt: Date
    /// Written outside the session's project cwd (e.g. ~/.zshrc) — surfaced
    /// first, in clay, because out-of-tree writes are what review exists to catch.
    let outOfTree: Bool

    var id: String { path }

    /// Just the file name for a compact label.
    var fileName: String { (path as NSString).lastPathComponent }
}
