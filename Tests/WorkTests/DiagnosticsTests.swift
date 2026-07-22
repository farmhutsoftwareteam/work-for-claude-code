import Foundation
import XCTest
@testable import Work

final class DiagnosticsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("atelier-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testEventRejectsFreeFormCodeAndUnknownMeasurements() async throws {
        let recorder = DiagnosticsRecorder(root: tmp)
        await recorder.record(
            severity: .warning, subsystem: .claude, operation: .streamStderr, outcome: .observed,
            provider: .claude, code: "Authorization: Bearer top-secret", measurements: ["bytes": 20, "prompt text": 1]
        )

        let events = try await recorder.recentEvents()
        let event = try XCTUnwrap(events.first)
        XCTAssertEqual(event.code, "invalid-code")
        XCTAssertEqual(event.measurements, ["bytes": 20])

        let bytes = try Data(contentsOf: tmp.appendingPathComponent("events.ndjson"))
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(text.contains("top-secret"))
        XCTAssertFalse(text.contains("prompt text"))
    }

    func testExportContainsOnlyRedactedAllowListedData() async throws {
        let recorder = DiagnosticsRecorder(root: tmp)
        await recorder.record(
            severity: .error, subsystem: .process, operation: .subprocessRun, outcome: .failed,
            code: "prompt=do-not-store-this", measurements: ["exit_status": 1]
        )

        let archive = tmp.appendingPathComponent("diagnostics.zip")
        try await recorder.export(to: archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))

        let extracted = tmp.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let bundle = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil).first)
        let text = try String(contentsOf: bundle.appendingPathComponent("events.json"), encoding: .utf8)
        let manifest = try String(contentsOf: bundle.appendingPathComponent("manifest.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("do-not-store-this"))
        XCTAssertTrue(manifest.contains("conversation and transcript content"))
    }

    func testEventsAreBoundedByConfiguredSize() async throws {
        let recorder = DiagnosticsRecorder(root: tmp, maximumBytes: 350)
        for _ in 0..<20 {
            await recorder.record(subsystem: .claude, operation: .streamEnd, outcome: .observed, code: "stream-closed")
        }

        let size = try XCTUnwrap(
            (try FileManager.default.attributesOfItem(atPath: tmp.appendingPathComponent("events.ndjson").path)[.size] as? NSNumber)?.intValue
        )
        XCTAssertLessThanOrEqual(size, 350)
    }
}
