import Foundation

/// Shared helper for detecting env-var keys that likely contain secrets.
/// Used by MCPEditor, ExtensionsView's env detail, and the auth-method inference.
enum SecretDetection {
    /// True if the given env-var key looks like it contains sensitive material.
    /// Uses word-boundary matching to avoid false positives like "bypass" or "compass".
    static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()

        // Direct word matches (most reliable)
        let words = ["token", "secret", "password", "credential", "api_key", "apikey", "auth"]
        for word in words {
            if lower.contains(word) { return true }
        }

        // "key" requires word-like boundary so "keychain", "_key", "-key", "KEY=" match
        // but random substrings don't
        if lower.range(of: #"(^|[^a-z])key([^a-z]|$)"#, options: .regularExpression) != nil {
            return true
        }

        // "pass" requires word boundary so bypass/compass don't match
        if lower.range(of: #"(^|[^a-z])pass([^a-z]|$)"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }
}
