import AppKit
import Foundation
import OSLog
#if canImport(MetricKit)
import MetricKit
#endif

/// The only persistent diagnostic record Atelier creates by default. Its
/// fields are deliberately narrow: conversation data, tool payloads, paths,
/// credentials, environment values, and raw process output have no place to
/// go in this type.
struct DiagnosticsEvent: Codable, Sendable, Identifiable, Equatable {
    enum Severity: String, Codable, Sendable { case debug, info, notice, warning, error, fault }
    enum Subsystem: String, Codable, Sendable {
        case app, workspace, claude, codex, acp, process, mcp, storage, network, update, hang, diagnostics
    }
    enum Operation: String, Codable, Sendable {
        case launch, quit, streamStart, streamHandshake, streamEnd, streamDecode, streamStderr
        case codexServerStart, codexRequest, codexServerEnd, codexStderr
        case subprocessRun, subprocessStderr, pricingFetch, hangDetected, hangSample
        case metricCrash, metricHang, export, cleanup, fileWatch, preferences
    }
    enum Outcome: String, Codable, Sendable { case started, succeeded, failed, cancelled, timedOut, observed }
    enum Provider: String, Codable, Sendable { case claude, codex, acp }

    let id: String
    let schemaVersion: Int
    let timestamp: Date
    let launchID: String
    let operationID: String?
    let severity: Severity
    let subsystem: Subsystem
    let operation: Operation
    let outcome: Outcome
    let provider: Provider?
    /// A vetted machine-readable classification, never an error description.
    let code: String?
    let durationMilliseconds: Int?
    /// Counts only (bytes, lines, event count, exit status). No free-form data.
    let measurements: [String: Int]

    init(
        launchID: String,
        operationID: String? = nil,
        severity: Severity = .info,
        subsystem: Subsystem,
        operation: Operation,
        outcome: Outcome,
        provider: Provider? = nil,
        code: String? = nil,
        durationMilliseconds: Int? = nil,
        measurements: [String: Int] = [:],
        timestamp: Date = Date()
    ) {
        self.id = UUID().uuidString
        self.schemaVersion = 1
        self.timestamp = timestamp
        self.launchID = launchID
        self.operationID = operationID
        self.severity = severity
        self.subsystem = subsystem
        self.operation = operation
        self.outcome = outcome
        self.provider = provider
        self.code = Self.safeCode(code)
        self.durationMilliseconds = durationMilliseconds.map { min(max($0, 0), 86_400_000) }
        self.measurements = measurements.reduce(into: [:]) { result, pair in
            guard Self.safeMeasurementKey(pair.key) else { return }
            result[pair.key] = min(max(pair.value, -1_000_000_000), 1_000_000_000)
        }
    }

    private static func safeCode(_ code: String?) -> String? {
        guard let code, !code.isEmpty else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard code.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "invalid-code" }
        return String(code.prefix(80))
    }

    private static func safeMeasurementKey(_ key: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        return !key.isEmpty && key.count <= 40 && key.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

enum DiagnosticsPaths {
    static func root() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return appSupport
            .appendingPathComponent("com.munyamakosa.work", isDirectory: true)
            .appendingPathComponent("diagnostics", isDirectory: true)
    }

    static func hangs() -> URL { root().appendingPathComponent("hangs", isDirectory: true) }
}

/// Serial, bounded local storage. It is intentionally not observable: stream
/// events must never cause a SwiftUI update or add work to the token hot path.
actor DiagnosticsRecorder {
    static let shared = DiagnosticsRecorder()

    private let root: URL
    private let eventsURL: URL
    private let maximumBytes: Int
    private let maximumAge: TimeInterval
    private let launchID = UUID().uuidString
    private var appendedSinceCleanup = 0

    init(
        root: URL = DiagnosticsPaths.root(),
        maximumBytes: Int = 10 * 1_024 * 1_024,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.root = root
        self.eventsURL = root.appendingPathComponent("events.ndjson")
        self.maximumBytes = maximumBytes
        self.maximumAge = maximumAge
    }

    func newOperationID() -> String { UUID().uuidString }

    func record(
        severity: DiagnosticsEvent.Severity = .info,
        subsystem: DiagnosticsEvent.Subsystem,
        operation: DiagnosticsEvent.Operation,
        outcome: DiagnosticsEvent.Outcome,
        provider: DiagnosticsEvent.Provider? = nil,
        operationID: String? = nil,
        code: String? = nil,
        durationMilliseconds: Int? = nil,
        measurements: [String: Int] = [:]
    ) {
        let event = DiagnosticsEvent(
            launchID: launchID,
            operationID: operationID,
            severity: severity,
            subsystem: subsystem,
            operation: operation,
            outcome: outcome,
            provider: provider,
            code: code,
            durationMilliseconds: durationMilliseconds,
            measurements: measurements
        )
        writeUnifiedLog(event)
        do {
            try prepareDirectory()
            try append(event)
        } catch {
            // Do not include the error text: file paths and user account names
            // may be part of Foundation's localized description.
            Logger.diagnostics.error("Diagnostic event could not be persisted")
        }
    }

    func recentEvents() throws -> [DiagnosticsEvent] {
        try readEvents().filter { Date().timeIntervalSince($0.timestamp) <= maximumAge }
    }

    func latestIncidentID() -> String? {
        guard let events = try? recentEvents() else { return nil }
        return events.reversed().first {
            $0.severity == .warning || $0.severity == .error || $0.severity == .fault
        }?.id
    }

    func clear() throws {
        try? FileManager.default.removeItem(at: eventsURL)
        try? FileManager.default.removeItem(at: root.appendingPathComponent("events.previous.ndjson"))
        try? FileManager.default.removeItem(at: DiagnosticsPaths.hangs())
        try prepareDirectory()
        try FileManager.default.createDirectory(at: DiagnosticsPaths.hangs(), withIntermediateDirectories: true)
        try applyOwnerOnlyPermissions(to: DiagnosticsPaths.hangs(), isDirectory: true)
    }

    /// Creates a user-selected ZIP containing only the allow-listed event
    /// timeline, a manifest, and already-local hang samples. Caller must run
    /// this away from the main actor because `/usr/bin/ditto` waits for exit.
    func export(to destination: URL) throws {
        try prepareDirectory()
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("atelier-diagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try applyOwnerOnlyPermissions(to: staging, isDirectory: true)

        let events = try recentEvents()
        let eventData = try Self.encoder.encode(events)
        try eventData.write(to: staging.appendingPathComponent("events.json"), options: .atomic)

        let manifest = DiagnosticBundleManifest(
            schemaVersion: 1,
            exportedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architecture,
            eventCount: events.count,
            excluded: [
                "conversation and transcript content",
                "tool inputs and results",
                "attachments",
                "credentials, tokens, and authorization URLs",
                "environment values and MCP configuration",
                "raw stdout, stderr, and protocol payloads",
                "absolute paths and native session identifiers"
            ]
        )
        try Self.encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        try "# Atelier diagnostic bundle\n\nAttach this ZIP only if you are comfortable sharing the redacted metadata described in `manifest.json`. Add the incident ID, approximate time, expected behavior, actual behavior, and reproduction steps to your report.\n".write(
            to: staging.appendingPathComponent("README.md"), atomically: true, encoding: .utf8
        )
        try copyRecentHangSamples(to: staging)

        try? fm.removeItem(at: destination)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ExportError.archiveFailed }
        try applyOwnerOnlyPermissions(to: destination)
    }

    private func append(_ event: DiagnosticsEvent) throws {
        let encoded = try Self.encoder.encode(event) + Data([0x0A])
        if let size = (try? FileManager.default.attributesOfItem(atPath: eventsURL.path)[.size] as? NSNumber)?.intValue,
           size + encoded.count > maximumBytes {
            try rotate()
        }
        if FileManager.default.fileExists(atPath: eventsURL.path) {
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: encoded)
        } else {
            try encoded.write(to: eventsURL, options: .atomic)
            try applyOwnerOnlyPermissions(to: eventsURL)
        }
        appendedSinceCleanup += 1
        if appendedSinceCleanup >= 32 {
            appendedSinceCleanup = 0
            try pruneExpiredEvents()
        }
    }

    private func rotate() throws {
        // Keep the on-disk budget hard: this is a diagnostic ring, not an
        // audit log. The newest timeline is more useful for a fresh report.
        try? FileManager.default.removeItem(at: eventsURL)
    }

    private func pruneExpiredEvents() throws {
        let valid = try readEvents().filter { Date().timeIntervalSince($0.timestamp) <= maximumAge }
        guard valid.count < (try readEvents().count) else { return }
        try Self.encoder.encode(valid).write(to: eventsURL, options: .atomic)
        try applyOwnerOnlyPermissions(to: eventsURL)
    }

    private func readEvents() throws -> [DiagnosticsEvent] {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else { return [] }
        let data = try Data(contentsOf: eventsURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticsEvent.self, from: Data($0)) }
    }

    private func copyRecentHangSamples(to staging: URL) throws {
        let fm = FileManager.default
        let source = DiagnosticsPaths.hangs()
        guard let samples = try? fm.contentsOfDirectory(at: source, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let destination = staging.appendingPathComponent("hangs", isDirectory: true)
        let recent = samples
            .filter { $0.pathExtension == "txt" }
            .sorted {
                ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .prefix(10)
        guard !recent.isEmpty else { return }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        for sample in recent { try fm.copyItem(at: sample, to: destination.appendingPathComponent(sample.lastPathComponent)) }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try applyOwnerOnlyPermissions(to: root, isDirectory: true)
    }

    private func applyOwnerOnlyPermissions(to url: URL, isDirectory: Bool = false) throws {
        let mode: mode_t = isDirectory ? 0o700 : 0o600
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
    }

    private func writeUnifiedLog(_ event: DiagnosticsEvent) {
        // Every component is an enum or a restricted machine-readable code.
        // Build it as a String first so Logger sees one reviewed public value.
        let message = "diagnostic subsystem=\(event.subsystem.rawValue) operation=\(event.operation.rawValue) outcome=\(event.outcome.rawValue) code=\(event.code ?? "none")"
        switch event.severity {
        case .debug: Logger.diagnostics.debug("\(message, privacy: .public)")
        case .info: Logger.diagnostics.info("\(message, privacy: .public)")
        case .notice: Logger.diagnostics.notice("\(message, privacy: .public)")
        case .warning: Logger.diagnostics.warning("\(message, privacy: .public)")
        case .error: Logger.diagnostics.error("\(message, privacy: .public)")
        case .fault: Logger.diagnostics.fault("\(message, privacy: .public)")
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    enum ExportError: LocalizedError { case archiveFailed }
}

private struct DiagnosticBundleManifest: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let build: String
    let macOSVersion: String
    let architecture: String
    let eventCount: Int
    let excluded: [String]
}

private extension Logger {
    static let diagnostics = Logger(subsystem: "com.munyamakosa.work", category: "diagnostics")
}

/// Synchronous call sites can safely use this facade; persistence happens on a
/// utility task and diagnostic state never participates in view observation.
enum Diagnostics {
    static func record(
        severity: DiagnosticsEvent.Severity = .info,
        subsystem: DiagnosticsEvent.Subsystem,
        operation: DiagnosticsEvent.Operation,
        outcome: DiagnosticsEvent.Outcome,
        provider: DiagnosticsEvent.Provider? = nil,
        operationID: String? = nil,
        code: String? = nil,
        durationMilliseconds: Int? = nil,
        measurements: [String: Int] = [:]
    ) {
        Task.detached(priority: .utility) {
            await DiagnosticsRecorder.shared.record(
                severity: severity, subsystem: subsystem, operation: operation, outcome: outcome,
                provider: provider, operationID: operationID, code: code,
                durationMilliseconds: durationMilliseconds, measurements: measurements
            )
        }
    }
}

/// MetricKit is system-produced local evidence. Atelier records only the
/// diagnostic category/count; it never uploads MetricKit payloads itself.
#if canImport(MetricKit)
final class MetricKitDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitDiagnostics()

    func start() { MXMetricManager.shared.add(self) }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let crashes = payload.crashDiagnostics?.count ?? 0
            let hangs = payload.hangDiagnostics?.count ?? 0
            if crashes > 0 {
                Diagnostics.record(
                    severity: .fault, subsystem: .diagnostics, operation: .metricCrash, outcome: .observed,
                    code: "metrickit-crash", measurements: ["count": crashes]
                )
            }
            if hangs > 0 {
                Diagnostics.record(
                    severity: .fault, subsystem: .diagnostics, operation: .metricHang, outcome: .observed,
                    code: "metrickit-hang", measurements: ["count": hangs]
                )
            }
        }
    }
}
#else
final class MetricKitDiagnostics: @unchecked Sendable {
    static let shared = MetricKitDiagnostics()
    func start() {}
}
#endif

@MainActor
enum DiagnosticReportController {
    static func present() {
        let alert = NSAlert()
        alert.messageText = "Report a Problem"
        alert.informativeText = "Atelier can create a redacted diagnostic bundle. It contains app and system versions, operation outcomes, and recent hang samples—not conversations, tool output, credentials, configuration, or paths."
        alert.addButton(withTitle: "Export Diagnostics…")
        alert.addButton(withTitle: "Reveal Diagnostics")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: export()
        case .alertSecondButtonReturn: reveal()
        default: break
        }
    }

    static func reveal() {
        let root = DiagnosticsPaths.root()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }

    static func clear() {
        Task {
            try? await DiagnosticsRecorder.shared.clear()
        }
    }

    private static func export() {
        let panel = NSSavePanel()
        panel.title = "Export Atelier Diagnostics"
        panel.message = "Review the bundle before attaching it to a bug report."
        panel.nameFieldStringValue = "atelier-diagnostics.zip"
        panel.allowedContentTypes = [.zip]
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task.detached(priority: .userInitiated) {
            let result: Result<Void, Error>
            do {
                try await DiagnosticsRecorder.shared.export(to: destination)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            let incidentID = await DiagnosticsRecorder.shared.latestIncidentID()
            await MainActor.run {
                let resultAlert = NSAlert()
                switch result {
                case .success:
                    resultAlert.messageText = "Diagnostics Exported"
                    resultAlert.informativeText = incidentID.map {
                        "Incident ID: \($0)\n\nReview the ZIP before attaching it to an issue."
                    } ?? "Review the ZIP before attaching it to an issue."
                    resultAlert.addButton(withTitle: "Open Issue Form")
                    resultAlert.addButton(withTitle: "Reveal in Finder")
                    resultAlert.addButton(withTitle: "Done")
                    switch resultAlert.runModal() {
                    case .alertFirstButtonReturn:
                        openIssueForm(incidentID: incidentID)
                    case .alertSecondButtonReturn:
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    default:
                        break
                    }
                case .failure:
                    resultAlert.messageText = "Couldn’t Export Diagnostics"
                    resultAlert.informativeText = "The diagnostic bundle could not be created. Try a different destination with available space."
                    resultAlert.addButton(withTitle: "OK")
                    resultAlert.runModal()
                }
            }
        }
    }

    private static func openIssueForm(incidentID: String?) {
        var components = URLComponents(string: "https://github.com/farmhutsoftwareteam/work-for-claude-code/issues/new")!
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        components.queryItems = [
            URLQueryItem(name: "title", value: "Bug: "),
            URLQueryItem(
                name: "body",
                value: "## What happened?\n\n\n## Steps to reproduce\n\n\n## Expected behavior\n\n\n## Environment\n- Atelier: \(version) (\(build))\n- macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)\n\(incidentID.map { "- Incident ID: \($0)" } ?? "")\n\nI reviewed the diagnostic bundle before attaching it."
            )
        ]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }
}
