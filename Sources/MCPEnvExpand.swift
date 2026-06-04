import Foundation

/// Expand `${VAR}` and `${VAR:-default}` references in a string against the
/// host process's environment. Mirrors Claude Code's syntax for environment
/// variable expansion in `.mcp.json` files, documented at
/// <https://code.claude.com/docs/en/mcp#environment-variable-expansion-in-mcp-json>.
///
/// - `${VAR}` → value of `VAR` in `ProcessInfo.processInfo.environment`,
///   or empty string if unset (Claude's behavior is "fail to parse"; we
///   prefer empty so the server still loads, just possibly broken — the
///   UI surfaces the raw `${VAR}` form so users can spot the issue).
/// - `${VAR:-default}` → value of `VAR` if set, else `default`. Defaults
///   may themselves contain `${VAR}` references; they're expanded
///   recursively up to a small depth cap to avoid infinite loops on
///   pathological inputs.
/// - Strings without `${` pass through unchanged (no allocation).
///
/// Pure function — easy to unit-test, no side effects.
enum MCPEnvExpand {

    /// Convenience overload that reads from the host process environment.
    /// Most callers want this.
    static func expand(_ s: String) -> String {
        expand(s, env: ProcessInfo.processInfo.environment)
    }

    /// Underlying expansion. Takes the env dict explicitly so unit tests
    /// can inject a fixture instead of polluting the process environment.
    static func expand(_ s: String, env: [String: String], maxDepth: Int = 8) -> String {
        guard s.contains("${"), maxDepth > 0 else { return s }

        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            // Look for `${`
            if c == "$",
               s.index(after: i) < s.endIndex,
               s[s.index(after: i)] == "{",
               let close = s[s.index(i, offsetBy: 2)...].firstIndex(of: "}") {

                let inner = s[s.index(i, offsetBy: 2)..<close]
                let (name, defaultValue) = splitDefault(inner)
                let resolved = env[name] ?? defaultValue
                // Defaults can themselves reference more vars — recurse with
                // a depth cap so a cycle like ${A:-${A}} terminates.
                let expanded = expand(resolved, env: env, maxDepth: maxDepth - 1)
                out.append(expanded)
                i = s.index(after: close)
                continue
            }
            out.append(c)
            i = s.index(after: i)
        }
        return out
    }

    /// Split `"VAR:-default"` into `("VAR", "default")`. Without `:-`,
    /// returns `(inner, "")` so unresolved vars become empty.
    private static func splitDefault(_ inner: Substring) -> (name: String, defaultValue: String) {
        if let range = inner.range(of: ":-") {
            return (String(inner[..<range.lowerBound]), String(inner[range.upperBound...]))
        }
        return (String(inner), "")
    }

    /// Convenience: expand every value in a `[String: String]` dict.
    /// Used by the MCP parser on `env` and `headers`.
    static func expand(_ dict: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        out.reserveCapacity(dict.count)
        for (k, v) in dict { out[k] = expand(v) }
        return out
    }
}
