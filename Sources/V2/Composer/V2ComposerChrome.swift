import SwiftUI

/// Provider-neutral composer chrome. Claude and Codex supply their own
/// transport/state behavior, while the visual shell stays identical.
struct V2ComposerChrome<Content: View, Helper: View>: View {
    @Environment(\.v2) private var v2

    let attachments: [V2Attachment]
    let onRemoveAttachment: (V2Attachment) -> Void
    private let content: Content
    private let helper: Helper

    init(
        attachments: [V2Attachment],
        onRemoveAttachment: @escaping (V2Attachment) -> Void,
        @ViewBuilder content: () -> Content,
        @ViewBuilder helper: () -> Helper
    ) {
        self.attachments = attachments
        self.onRemoveAttachment = onRemoveAttachment
        self.content = content()
        self.helper = helper()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { item in
                            V2ComposerAttachmentChip(item: item) {
                                onRemoveAttachment(item)
                            }
                        }
                    }
                }
            }
            content
            helper
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(v2.line).frame(height: 1)
        }
    }
}

struct V2ComposerBoxChrome<Content: View>: View {
    @Environment(\.v2) private var v2
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(v2.card)
            .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

struct V2ComposerAttachmentChip: View {
    @Environment(\.v2) private var v2
    let item: V2Attachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let thumb = item.thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 24, height: 24)
                    .clipped()
            } else {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundColor(v2.mute)
                    .frame(width: 24, height: 24)
                    .background(v2.paper3)
            }
            Text(item.displayName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(v2.mute)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 4)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(v2.paper2)
        .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
    }
}

struct V2ComposerAttachButton: View {
    @Environment(\.v2) private var v2
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "paperclip")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(v2.mute)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Attach an image or file (or drag one in / paste with ⌘V)")
        .disabled(!enabled)
    }
}

struct V2ComposerTurnButton: View {
    @Environment(\.v2) private var v2
    let isWorking: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    var body: some View {
        if isWorking {
            Button(action: onStop) {
                HStack(spacing: 7) {
                    Rectangle().fill(v2.ink).frame(width: 8, height: 8)
                    Text("Stop")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(v2.ink)
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(v2.paper2)
                .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
        } else {
            Button(action: onSend) {
                Text("⏎ send")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(canSend ? v2.ink : v2.faint)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(v2.paper2)
                    .overlay(Rectangle().stroke(v2.line2, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
    }
}

struct V2ComposerContextMeter: View {
    @Environment(\.v2) private var v2
    let model: String
    let used: Int
    let window: Int?
    let isTight: Bool
    var helpText: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if !isTight, !model.isEmpty {
                Text(model)
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 90, alignment: .leading)
            }
            if used == 0 {
                Text("context idle").foregroundColor(v2.faint).lineLimit(1)
            } else if let window, window > 0 {
                let fraction = min(1, Double(used) / Double(window))
                let high = fraction >= 0.85
                let percentage = Int((fraction * 100).rounded())
                ZStack(alignment: .leading) {
                    Rectangle().fill(v2.line2).frame(width: 46, height: 4)
                    Rectangle().fill(high ? v2.del : v2.ink)
                        .frame(width: 46 * max(0, fraction), height: 4)
                }
                Text(isTight
                     ? "\(percentage)%"
                     : "\(percentage)% · \(V2Format.count(used))/\(V2Format.count(window))")
                    .foregroundColor(high ? v2.del : v2.faint)
                    .lineLimit(1)
            } else {
                Text(isTight ? V2Format.count(used) : "\(V2Format.count(used)) in context")
                    .foregroundColor(v2.faint)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .help(helpText ?? "Current model and context usage")
    }
}

enum V2ComposerMetrics {
    /// Computed only when the draft changes; callers cache the result so a
    /// streaming transcript never rescans the full draft per token.
    static func height(for draft: String) -> CGFloat {
        let lineHeight: CGFloat = 19
        let topBottomPadding: CGFloat = 8
        let newlines = draft.filter { $0 == "\n" }.count
        let wrapped = max(0, (draft.count / 80) - newlines)
        let lines = max(1, min(8, 1 + newlines + wrapped))
        return CGFloat(lines) * lineHeight + topBottomPadding
    }
}
