import Foundation

// MARK: - On-disk shape

struct SessionPreferencesData: Codable, Equatable {
    var version: Int = 1
    var aliases: [String: String] = [:]   // sessionId → custom name
    var hidden: [String: Bool] = [:]      // sessionId → true when hidden

    static let empty = SessionPreferencesData()

    func alias(for sessionId: String) -> String? {
        let trimmed = (aliases[sessionId] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func isHidden(_ sessionId: String) -> Bool {
        hidden[sessionId] ?? false
    }
}

// MARK: - Actor-backed store

/// Reads/writes the per-session preferences JSON. Writes are atomic and
/// serialized through the actor; the Store holds a @Published snapshot
/// for SwiftUI to observe.
actor SessionPreferencesStore {
    private(set) var data: SessionPreferencesData = .empty
    private let url: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("com.munyamakosa.work")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.url = dir.appendingPathComponent("session-prefs.json")
    }

    // MARK: - Load

    func load() -> SessionPreferencesData {
        guard FileManager.default.fileExists(atPath: url.path),
              let raw = try? Data(contentsOf: url),
              !raw.isEmpty,
              let decoded = try? JSONDecoder().decode(SessionPreferencesData.self, from: raw) else {
            data = .empty
            return data
        }
        data = decoded
        return decoded
    }

    // MARK: - Mutations

    func setAlias(_ alias: String, for sessionId: String) -> SessionPreferencesData {
        let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            data.aliases.removeValue(forKey: sessionId)
        } else {
            data.aliases[sessionId] = trimmed
        }
        persist()
        return data
    }

    func clearAlias(for sessionId: String) -> SessionPreferencesData {
        data.aliases.removeValue(forKey: sessionId)
        persist()
        return data
    }

    func setHidden(_ isHidden: Bool, for sessionId: String) -> SessionPreferencesData {
        if isHidden {
            data.hidden[sessionId] = true
        } else {
            data.hidden.removeValue(forKey: sessionId)
        }
        persist()
        return data
    }

    // MARK: - Persist (atomic)

    private func persist() {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(data)
            try bytes.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode_t(0o600))],
                ofItemAtPath: url.path
            )
        } catch {
            // Silent: preferences are non-critical; worst case prefs don't persist this session
        }
    }
}
