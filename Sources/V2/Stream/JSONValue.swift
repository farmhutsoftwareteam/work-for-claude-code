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

    /// Pretty-print for inline display in tool widgets.
    var preview: String {
        switch self {
        case .null:            return "null"
        case .bool(let v):     return String(v)
        case .number(let v):   return v.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(v)) : String(v)
        case .string(let v):   return v
        case .array(let arr):  return "[\(arr.count) items]"
        case .object(let obj): return "{\(obj.keys.sorted().joined(separator: ", "))}"
        }
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
}
