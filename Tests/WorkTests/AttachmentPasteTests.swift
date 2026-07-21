import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Work

/// Attaching an image was hanging the app. Root cause, found by measuring
/// real execution rather than reasoning about it (2026-07-21): pasting ran
/// `NSPasteboard.readObjects(forClasses: [NSImage.self])` (decodes the full
/// image) then `NSImage.tiffRepresentation` (re-encodes it, UNCOMPRESSED,
/// synchronously) — both on the main thread, both unbounded. Measured on a
/// realistic 48MP photo paste: 1.3s in tiffRepresentation alone, allocating
/// a 1.5GB intermediate buffer.
///
/// The fix reads raw pasteboard bytes instead (`pb.data(forType:)` — a
/// memory copy, not a decode) and moves every decode/downsample step into
/// V2AttachmentStore's existing off-actor Task. That surfaced a SECOND,
/// easy-to-miss trap, also found by executing it rather than assuming:
/// `NSPasteboard.types` (the aggregate accessor) advertises types AppKit
/// can SYNTHESIZE on demand, not just what's actually there — write only
/// PNG and `pb.types` still lists `.tiff`. Asking for that synthesized
/// type is itself a full decode + uncompressed re-encode (measured 215ms
/// for a 4MB source), silently reintroducing the exact bug this fix
/// removes. `NSPasteboardItem.types` (the per-item accessor) reflects only
/// what was actually written, verified in both directions — that's what
/// `rawImageData` keys off, not a fixed try-order.
@MainActor
final class AttachmentPasteTests: XCTestCase {

    // MARK: - Helpers

    /// Builds PNG bytes at an EXACT pixel size via CGBitmapContext — no
    /// NSImage/lockFocus involved, which on a Retina host draws at the
    /// screen's backing scale and silently doubles the pixel count,
    /// making a dimension assertion ambiguous.
    private func makePNG(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!
        let dest = NSMutableData()
        let d = CGImageDestinationCreateWithData(dest as CFMutableData, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cgImage, nil)
        CGImageDestinationFinalize(d)
        return dest as Data
    }

    private func makeTIFF(width: Int, height: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!
        let dest = NSMutableData()
        let d = CGImageDestinationCreateWithData(dest as CFMutableData, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cgImage, nil)
        CGImageDestinationFinalize(d)
        return dest as Data
    }

    /// Writes via NSPasteboardItem (not `declareTypes`+`setData`), which is
    /// what makes the type NATIVE per-item rather than only pasteboard-wide
    /// — matching how real apps (screenshot tool, Preview, browsers) put
    /// image data on the clipboard.
    private func pasteboard(nativeType: NSPasteboard.PasteboardType, data: Data) -> NSPasteboard {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(data, forType: nativeType)
        pb.writeObjects([item])
        return pb
    }

    private func pixelSize(of data: Data) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    override func tearDown() {
        NSPasteboard.general.clearContents()
        super.tearDown()
    }

    // MARK: - The actual bug: native-type detection, not blind try-order

    func testReadsNativePNGWithoutTriggeringSynthesis() throws {
        let png = makePNG(width: 640, height: 480)
        let pb = pasteboard(nativeType: .png, data: png)

        // The aggregate accessor advertises .tiff too, via synthesis —
        // exactly the trap a fixed [.tiff, .png] try-order would fall into.
        XCTAssertTrue(pb.types?.contains(.tiff) ?? false,
                      "test setup sanity check: AppKit really does advertise a synthesizable .tiff here")

        let result = try XCTUnwrap(ComposerNSTextView.rawImageData(from: pb))
        // Byte-identical to what was written — proves the NATIVE type was
        // read, not a re-encoded synthesis of it (which would differ).
        XCTAssertEqual(result, png)
        XCTAssertEqual(try XCTUnwrap(pixelSize(of: result)).0, 640)
    }

    func testReadsNativeTIFFWithoutTriggeringSynthesis() throws {
        let tiff = makeTIFF(width: 300, height: 200)
        let pb = pasteboard(nativeType: .tiff, data: tiff)

        let result = try XCTUnwrap(ComposerNSTextView.rawImageData(from: pb))
        XCTAssertEqual(result, tiff)
        XCTAssertEqual(try XCTUnwrap(pixelSize(of: result)).0, 300)
    }

    func testNativeTypeDetectionSurvivesEitherDirection() throws {
        // Both directions in one run, proving the detection isn't
        // order-dependent — a regression here would silently prefer
        // whichever type happens to be checked first again.
        let png = makePNG(width: 100, height: 100)
        let pbPNG = pasteboard(nativeType: .png, data: png)
        XCTAssertEqual(try XCTUnwrap(ComposerNSTextView.rawImageData(from: pbPNG)), png)

        let tiff = makeTIFF(width: 100, height: 100)
        let pbTIFF = pasteboard(nativeType: .tiff, data: tiff)
        XCTAssertEqual(try XCTUnwrap(ComposerNSTextView.rawImageData(from: pbTIFF)), tiff)
    }

    func testEmptyPasteboardReturnsNilRatherThanHanging() {
        let pb = NSPasteboard.general
        pb.clearContents()
        XCTAssertNil(ComposerNSTextView.rawImageData(from: pb))
    }

    // MARK: - V2AttachmentStore: the off-actor pipeline

    func testAddImageDataPersistsAndProducesAThumbnailAsynchronously() async throws {
        let store = V2AttachmentStore()
        let png = makePNG(width: 512, height: 384)

        store.addImageData(png)

        // addImageData's Task is fire-and-forget; poll rather than assume
        // a fixed delay is long enough on a loaded CI machine.
        let deadline = Date().addingTimeInterval(5)
        while store.items.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let attachment = try XCTUnwrap(store.items.first)
        XCTAssertTrue(attachment.isOwned, "a pasted image is written to disk, so it's owned and cleaned up on remove")
        XCTAssertNotNil(attachment.thumbnail, "the thumbnail must be produced, not just the file")
        XCTAssertTrue(FileManager.default.fileExists(atPath: attachment.url.path))

        // Written file must be genuinely valid, decodable image data —
        // not a stub or partial write from the off-actor pipeline.
        let written = try Data(contentsOf: attachment.url)
        XCTAssertNotNil(pixelSize(of: written))

        store.remove(attachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: attachment.url.path),
                       "remove() must delete an owned (disk-written) attachment")
    }

    func testAddImageDataDownsizesAnOversizedSourceRatherThanStoringItRaw() async throws {
        // Larger than V2AttachmentStore's maxPersistedDimension (4096) on
        // its long side — proves the persist step actually bounds output,
        // not just that SOME file gets written.
        let store = V2AttachmentStore()
        let big = makePNG(width: 6000, height: 3000)

        store.addImageData(big)
        let deadline = Date().addingTimeInterval(10)
        while store.items.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        let attachment = try XCTUnwrap(store.items.first)
        let written = try Data(contentsOf: attachment.url)
        let size = try XCTUnwrap(pixelSize(of: written))
        XCTAssertLessThanOrEqual(max(size.0, size.1), 4096,
                                 "the persisted file must be downsized to the documented cap, not stored at native resolution")
    }
}
