// Tracks images / files attached to the composer for the next user turn.
// Pasted bytes get written to ~/Library/Application Support/Atelier/
// attachments/<timestamp>-<n>.<ext> so claude can @-reference them. Picked
// files are referenced in place — we don't copy them.
//
// On send, V2LiveComposer asks the store for the @-reference prefix that
// should land at the top of the user turn (claude reads the @path via its
// Read tool — no protocol change, no base64 over stdin).

import Foundation
import AppKit

struct V2Attachment: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let displayName: String
    let isOwned: Bool      // true → we wrote it, safe to delete after send
    let thumbnail: NSImage?
}

@MainActor
final class V2AttachmentStore: ObservableObject {
    @Published private(set) var items: [V2Attachment] = []

    /// Where pasted-image bytes get written. Once-per-app static directory
    /// under Application Support so the path survives across launches if
    /// claude hasn't read the file yet.
    private static let scratchDir: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.munyamakosa.work")
            .appendingPathComponent("attachments")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }()

    // MARK: - Add

    func addFile(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        let thumb = Self.makeThumbnail(for: url)
        items.append(V2Attachment(
            url: url,
            displayName: url.lastPathComponent,
            isOwned: false,
            thumbnail: thumb
        ))
    }

    func addFiles(_ urls: [URL]) {
        urls.forEach(addFile)
    }

    func addImage(_ image: NSImage) {
        guard let url = persistImage(image) else { return }
        let thumb = Self.makeThumbnail(for: url)
        items.append(V2Attachment(
            url: url,
            displayName: url.lastPathComponent,
            isOwned: true,
            thumbnail: thumb
        ))
    }

    // MARK: - Remove

    func remove(_ attachment: V2Attachment) {
        items.removeAll { $0.id == attachment.id }
        if attachment.isOwned {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }

    func clear() {
        // We DO NOT delete owned files here. Composer calls clear()
        // immediately after session.send() returns, but claude hasn't
        // necessarily issued its Read tool call yet — deleting the PNG out
        // from under an in-flight Read makes the attachment vanish before
        // it can be seen. Old attachments age out via purgeOldAttachments()
        // on next launch instead.
        items.removeAll()
    }

    /// Sweep ~/Library/Application Support/com.munyamakosa.work/attachments
    /// at app launch, removing owned pastes older than the cutoff. Anything
    /// fresher than that is still potentially mid-Read by an active claude
    /// session and must not be touched.
    static func purgeOldAttachments(olderThan cutoff: TimeInterval = 24 * 60 * 60) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: scratchDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let now = Date()
        for url in entries {
            let attrs = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let mtime = attrs?.contentModificationDate else { continue }
            if now.timeIntervalSince(mtime) > cutoff {
                try? fm.removeItem(at: url)
            }
        }
    }

    // MARK: - Outbound

    /// Build the @-reference prefix for the user turn. claude reads each
    /// path via its Read tool, so prepending these makes the screenshots /
    /// docs first-class context in the next reply.
    func outboundPrefix() -> String {
        guard !items.isEmpty else { return "" }
        let refs = items.map { "@\(absolutePath($0.url))" }.joined(separator: " ")
        return refs + "\n\n"
    }

    private func absolutePath(_ url: URL) -> String {
        // claude's @-references resolve relative to the cwd. Absolute paths
        // always work; relative would require knowing the active project.
        url.path
    }

    // MARK: - Persistence

    private func persistImage(_ image: NSImage) -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "paste-\(stamp)-\(items.count + 1).png"
        let url = Self.scratchDir.appendingPathComponent(name)
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        do {
            try png.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func makeThumbnail(for url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let target = NSSize(width: 64, height: 64)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        defer { thumb.unlockFocus() }
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(in: NSRect(origin: .zero, size: target),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .copy, fraction: 1.0)
        return thumb
    }
}
