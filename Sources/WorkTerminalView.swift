import Foundation
import SwiftTerm

/// Thin subclass of `LocalProcessTerminalView` that emits a zero-cost
/// "data arrived" ping on every PTY read. Used to drive the tab chip's
/// busy/ready color without parsing terminal output.
///
/// The callback does not inspect bytes — it just fires. The controller
/// debounces into a busy/idle flag, so this adds one closure call per
/// PTY read above stock SwiftTerm.
final class WorkTerminalView: LocalProcessTerminalView {
    var onData: (() -> Void)?

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        // SwiftTerm invokes dataReceived from the LocalProcess read queue (a
        // background dispatch queue). The `onData` closure is almost always
        // going to touch @MainActor state, so hop explicitly here rather than
        // relying on every caller to remember. Cheap: empty-closure call,
        // plus one dispatch per PTY read burst.
        guard let onData else { return }
        if Thread.isMainThread {
            onData()
        } else {
            DispatchQueue.main.async { onData() }
        }
    }
}
