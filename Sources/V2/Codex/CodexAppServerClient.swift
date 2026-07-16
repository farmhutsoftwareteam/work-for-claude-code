import Foundation
import OSLog

enum CodexAppServerError: LocalizedError {
    case notRunning
    case invalidResponse
    case rpc(code: Int?, message: String)
    case processEnded(String)
    case timedOut(method: String, seconds: Int)

    var errorDescription: String? {
        switch self {
        case .notRunning: return "Codex app-server is not running."
        case .invalidResponse: return "Codex app-server returned an invalid response."
        case .rpc(let code, let message):
            return code.map { "Codex error \($0): \(message)" } ?? message
        case .processEnded(let message): return message
        case .timedOut(let method, let seconds):
            return "Codex request \(method) timed out after \(seconds) seconds."
        }
    }
}

/// Small JSON-RPC 2.0 transport for the local Codex app-server. It deliberately
/// keeps protocol payloads as dictionaries: app-server is versioned and adds
/// fields frequently, while Atelier only needs a stable subset of each event.
struct CodexJSONObject: @unchecked Sendable, ExpressibleByDictionaryLiteral {
    let raw: [String: Any]

    init(_ raw: [String: Any] = [:]) { self.raw = raw }

    init(dictionaryLiteral elements: (String, Any)...) {
        raw = Dictionary(uniqueKeysWithValues: elements)
    }

    subscript(key: String) -> Any? { raw[key] }
}

final class CodexAppServerClient: @unchecked Sendable {
    typealias JSONObject = CodexJSONObject
    typealias NotificationHandler = @Sendable (String, JSONObject) -> Void
    typealias ServerRequestHandler = @Sendable (String, String, JSONObject) -> Void

    private let log = Logger(subsystem: "com.munyamakosa.work", category: "codex-app-server")
    private let binary: URL
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let ioQueue = DispatchQueue(label: "atelier.codex.app-server.io", qos: .userInitiated)
    private let lock = NSLock()
    private var nextID = 1
    private struct PendingRequest {
        let method: String
        let startedAt: ContinuousClock.Instant
        let continuation: CheckedContinuation<JSONObject, Error>
    }
    private var pending: [String: PendingRequest] = [:]
    private var readBuffer = Data()
    private var stopped = false

    var onNotification: NotificationHandler?
    var onServerRequest: ServerRequestHandler?
    var onTermination: (@Sendable (String) -> Void)?

    init(binary: URL) { self.binary = binary }

    func start() async throws {
        process.executableURL = binary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = AtelierProcessEnvironment.enriched()

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            guard let self else { return }
            self.ioQueue.async { self.consume(data) }
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.log.debug("Codex app-server wrote \(data.count) stderr bytes")
        }
        process.terminationHandler = { [weak self] process in
            self?.finish(reason: "Codex app-server exited with status \(process.terminationStatus).")
        }
        try process.run()

        _ = try await request("initialize", params: [
            "clientInfo": [
                "name": "atelier",
                "title": "Atelier",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            ],
            "capabilities": [:]
        ])
        try sendNotification("initialized", params: [:])
    }

    func request(_ method: String, params: JSONObject = [:]) async throws -> JSONObject {
        try await request(method, wireParams: params.raw)
    }

    /// A small number of app-server methods require JSON-RPC `params: null`
    /// rather than an empty object. Keep that distinction explicit so adding a
    /// parameterless call cannot silently drift from the generated protocol.
    func requestWithNullParams(_ method: String) async throws -> JSONObject {
        try await request(method, wireParams: NSNull())
    }

    private func request(_ method: String, wireParams: Any) async throws -> JSONObject {
        guard process.isRunning, !lock.withLock({ stopped }) else {
            throw CodexAppServerError.notRunning
        }
        let id: String = lock.withLock {
            defer { nextID += 1 }
            return String(nextID)
        }
        let timeout = Self.timeout(for: method)
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                pending[id] = PendingRequest(
                    method: method,
                    startedAt: ContinuousClock.now,
                    continuation: continuation
                )
            }
            ioQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.expireRequest(id: id, method: method, timeout: timeout)
            }
            do {
                try write(["jsonrpc": "2.0", "id": Int(id) ?? id, "method": method, "params": wireParams])
            } catch {
                let waiting = lock.withLock { pending.removeValue(forKey: id) }
                waiting?.continuation.resume(throwing: error)
            }
        }
    }

    func respond(id: String, result: Any) throws {
        let wireID: Any = Int(id) ?? id
        try write(["jsonrpc": "2.0", "id": wireID, "result": result])
    }

    func respondError(id: String, code: Int, message: String) throws {
        let wireID: Any = Int(id) ?? id
        try write([
            "jsonrpc": "2.0",
            "id": wireID,
            "error": ["code": code, "message": message]
        ])
    }

    func sendNotification(_ method: String, params: JSONObject = [:]) throws {
        try write(["jsonrpc": "2.0", "method": method, "params": params.raw])
    }

    func stop() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        shutdown(reason: "Codex app-server stopped.", notify: false)
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }

    func terminateNow() { stop() }

    private func write(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var framed = data
        framed.append(0x0A)
        let line = framed
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.process.isRunning else {
                self.finish(reason: "Codex app-server ended before a request could be written.")
                return
            }
            do { try self.input.fileHandleForWriting.write(contentsOf: line) }
            catch { self.finish(reason: "Codex app-server write failed: \(error.localizedDescription)") }
        }
    }

    private func consume(_ data: Data) {
        readBuffer.append(data)
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = readBuffer.prefix(upTo: newline)
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: line),
                  let object = value as? [String: Any] else { continue }
            route(object)
        }
    }

    private func route(_ object: [String: Any]) {
        let id = Self.rpcID(object["id"])
        if let id, object["method"] == nil {
            let request = lock.withLock { pending.removeValue(forKey: id) }
            if let request {
                let elapsed = request.startedAt.duration(to: .now)
                log.debug("Codex request \(request.method, privacy: .public) completed in \(String(describing: elapsed), privacy: .public)")
            }
            if let error = object["error"] as? [String: Any] {
                request?.continuation.resume(throwing: CodexAppServerError.rpc(
                    code: error["code"] as? Int,
                    message: error["message"] as? String ?? "Unknown Codex error"
                ))
            } else if let result = object["result"] as? [String: Any] {
                request?.continuation.resume(returning: JSONObject(result))
            } else if object["result"] is NSNull {
                request?.continuation.resume(returning: JSONObject())
            } else {
                request?.continuation.resume(throwing: CodexAppServerError.invalidResponse)
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = JSONObject(object["params"] as? [String: Any] ?? [:])
        if let id { onServerRequest?(id, method, params) }
        else { onNotification?(method, params) }
    }

    private func finish(reason: String) {
        shutdown(reason: reason, notify: true)
    }

    private func shutdown(reason: String, notify: Bool) {
        let requests: [PendingRequest]? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        guard let requests else { return }
        requests.forEach {
            $0.continuation.resume(throwing: CodexAppServerError.processEnded(reason))
        }
        if notify { onTermination?(reason) }
    }

    private func expireRequest(id: String, method: String, timeout: TimeInterval) {
        guard let request = lock.withLock({ pending.removeValue(forKey: id) }) else { return }
        request.continuation.resume(throwing: CodexAppServerError.timedOut(
            method: method,
            seconds: Int(timeout)
        ))
    }

    private static func timeout(for method: String) -> TimeInterval {
        if method.hasPrefix("mcpServer") || method == "config/mcpServer/reload" { return 60 }
        if method == "turn/start" || method == "thread/start" || method == "thread/resume" { return 30 }
        return 15
    }

    private static func rpcID(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}
