// Tracks images / files attached to the composer for the next user turn.
// Pasted bytes get written to ~/Library/Application Support/Atelier/
// attachments/paste-<uuid>.<ext> so claude can @-reference them. Picked
// files are referenced in place — we don't copy them.
//
// On send, V2LiveComposer asks the store for the @-reference prefix that
// should land at the top of the user turn (claude reads the @path via its
// Read tool — no protocol change, no base64 over stdin).

import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

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
    nonisolated private static let scratchDir: URL = {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.munyamakosa.work")
            .appendingPathComponent("attachments")
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport
    }()

    /// Persisted-image and thumbnail decode/encode are capped to this on
    /// their longest side (ImageIO downsizes, never upscales). A raw
    /// screenshot/RAW paste otherwise burns CPU proportional to native
    /// resolution for a chip that renders at ~64pt (M18).
    nonisolated private static let maxPersistedDimension: CGFloat = 4096

    // MARK: - Add

    func addFile(_ url: URL) {
        guard !items.contains(where: { $0.url == url }) else { return }
        // Thumbnail decode is unbounded by source file size (a dropped
        // multi-MB TIFF/HEIC decodes synchronously otherwise) — run it off
        // @MainActor and publish only the finished attachment (M18).
        //
        // A plain `Task {}` here (not `.detached`) inherits this method's
        // @MainActor isolation, so the code either side of the inner
        // `Task.detached` stays on MainActor with no captured `self` ever
        // crossing the actor boundary — `Task.detached([weak self])` +
        // `MainActor.run { guard let self }` is the pattern Swift 6 strict
        // concurrency flags as "sending self risks causing data races"
        // (self, an @MainActor class, gets handed into a @Sendable closure).
        // The detached hop below only ever touches static/nonisolated work.
        Task {
            let thumb = await Task.detached(priority: .userInitiated) {
                Self.makeThumbnail(for: url)
            }.value
            guard !items.contains(where: { $0.url == url }) else { return }
            items.append(V2Attachment(
                url: url,
                displayName: url.lastPathComponent,
                isOwned: false,
                thumbnail: thumb
            ))
        }
    }

    func addFiles(_ urls: [URL]) {
        urls.forEach(addFile)
    }

    func addImage(_ image: NSImage) {
        // TIFF→PNG encode + thumbnail decode are synchronous, CPU-bound work
        // — doing them on @MainActor visibly stalls the composer for a
        // high-res screenshot/RAW paste (M18). `tiffRepresentation` has to
        // be read on the main thread (NSImage isn't safely Sendable), but
        // everything after that is plain Data/ImageIO work — see the note
        // on addFile(_:) above for why this hops via a nested Task.detached
        // over static functions instead of capturing `[weak self]` directly.
        guard let tiff = image.tiffRepresentation else { return }
        Task {
            let result: (url: URL, thumb: NSImage?)? = await Task.detached(priority: .userInitiated) {
                guard let url = Self.persistImage(tiffData: tiff) else { return nil }
                return (url, Self.makeThumbnail(for: url))
            }.value
            guard let result else { return }
            items.append(V2Attachment(
                url: result.url,
                displayName: result.url.lastPathComponent,
                isOwned: true,
                thumbnail: result.thumb
            ))
        }
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

    /// Encodes + writes pasted image bytes. Called from a detached Task (see
    /// `addImage`) so it must not touch NSImage/AppKit — ImageIO's
    /// CGImageSource/CGImageDestination are the documented thread-safe way
    /// to decode/downsize/encode off the main actor (M18).
    nonisolated private static func persistImage(tiffData: Data) -> URL? {
        guard let source = CGImageSourceCreateWithData(tiffData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPersistedDimension,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // UUID, not a second-resolution timestamp + this store's own
        // `items.count` — two DIFFERENT tabs pasting within the same
        // wall-clock second used to collide because every V2AttachmentStore
        // counts from 0 independently while all tabs share this one static
        // scratch dir (M15).
        let name = "paste-\(UUID().uuidString).png"
        let url = scratchDir.appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return url
    }

    /// ImageIO thumbnail instead of `NSImage(contentsOf:)` + `lockFocus`
    /// drawing — avoids decoding the full-resolution source just to render a
    /// 64pt chip, and (unlike NSImage) is safe to call off @MainActor (M18).
    nonisolated private static func makeThumbnail(for url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 128, // @2x for a 64pt chip
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
