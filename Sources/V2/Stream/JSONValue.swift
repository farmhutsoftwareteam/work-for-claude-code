// Arbitrary JSON value. The Claude stream protocol has fields whose shape is
// not knowable statically — tool inputs, permission `updatedInput`, etc. —
// so we keep them as a tagged union and let the UI pretty-print them.

import Foundation

enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let v = try? container.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? container.decode(Double.self) {
            self = .number(v)
        } else if let v = try? container.decode(String.self) {
            self = .string(v)
        } else if let v = try? container.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unrecognized JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .number(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }

    /// Pretty-print for inline display in tool widgets. Any tool NOT
    /// explicitly modeled by V2LiveToolWidget's target switch falls back to
    /// this — it used to show an object's KEY NAMES only ("{query}" for a
    /// WebSearch call, the actual query invisible), which read as broken for
    /// most of Claude Code's 40 built-in tools. Shows key:value pairs now,
    /// each side truncated, so an unmapped or future tool still surfaces
    /// something real instead of a shape with no content.
    var preview: String {
        switch self {
        case .null:            return "null"
        case .bool(let v):     return String(v)
        case .number(let v):   return v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
        case .string(let v):   return Self.truncate(v, to: 80)
        case .array(let arr):  return "[\(arr.count) items]"
        case .object(let obj):
            if obj.isEmpty { return "{}" }
            let pairs = obj.keys.sorted().map { key in
                "\(key): \(Self.truncate(obj[key]!.preview, to: 40))"
            }
            return Self.truncate("{\(pairs.joined(separator: ", "))}", to: 140)
        }
    }

    private static func truncate(_ s: String, to limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }

    /// Walk into a nested field, e.g. `.dig("command")` for a Bash tool input.
    func dig(_ keys: String...) -> JSONValue? {
        var node: JSONValue = self
        for key in keys {
            guard case .object(let obj) = node, let next = obj[key] else { return nil }
            node = next
        }
        return node
    }

    var asString: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    var asArray: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    var asBool: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    var asDouble: Double? {
        if case .number(let v) = self { return v }
        return nil
    }
}
