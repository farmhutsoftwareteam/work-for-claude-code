// Anthropic Messages API content block — text, tool_use, tool_result, thinking.
// Used inside `assistant` and `user` events and as the payload of
// `content_block_start` SSE events. The tool_result `content` is polymorphic
// (string OR array of blocks) — handled here.

import Foundation

enum ContentBlock: Decodable, Sendable, Identifiable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONValue)
    case toolResult(toolUseId: String, content: ToolResultContent, isError: Bool?)
    case thinking(text: String, signature: String?)
    case unknown(String)

    var id: String {
        // Stable across renders: previously the .text / .thinking cases
        // generated a NEW UUID on every access, so SwiftUI ForEach saw
        // every text block as a different identity each render — animations
        // broke, scroll position jumped, identical text rows duplicated.
        // Hash of the content is stable for a given block instance and
        // collisions are visually identical anyway.
        switch self {
        case .text(let s):                   return "text-\(s.hashValue)"
        case .toolUse(let id, _, _):         return "use-\(id)"
        case .toolResult(let id, _, _):      return "res-\(id)"
        case .thinking(let t, _):            return "think-\(t.hashValue)"
        case .unknown(let t):                return "unk-\(t)"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, text, id, name, input
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
        case thinking, signature
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "text":
            self = .text((try? c.decode(String.self, forKey: .text)) ?? "")
        case "tool_use":
            self = .toolUse(
                id: (try? c.decode(String.self, forKey: .id)) ?? "",
                name: (try? c.decode(String.self, forKey: .name)) ?? "",
                input: (try? c.decode(JSONValue.self, forKey: .input)) ?? .object([:])
            )
        case "tool_result":
            self = .toolResult(
                toolUseId: (try? c.decode(String.self, forKey: .toolUseId)) ?? "",
                content: (try? c.decode(ToolResultContent.self, forKey: .content)) ?? .text(""),
                isError: try? c.decodeIfPresent(Bool.self, forKey: .isError)
            )
        case "thinking":
            self = .thinking(
                text: (try? c.decode(String.self, forKey: .thinking)) ?? "",
                signature: try? c.decodeIfPresent(String.self, forKey: .signature)
            )
        default:
            self = .unknown(type)
        }
    }
}

/// tool_result.content can be a string or an array of content blocks. The
/// parser dedup rule (per claude-code-parser) preserves the polymorphism.
enum ToolResultContent: Decodable, Sendable {
    case text(String)
    case blocks([ContentBlock])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .text(str)
        } else if let blocks = try? container.decode([ContentBlock].self) {
            self = .blocks(blocks)
        } else {
            self = .text("")
        }
    }

    var asString: String {
        switch self {
        case .text(let s): return s
        case .blocks(let blocks):
            return blocks.compactMap {
                if case .text(let t) = $0 { return t }
                return nil
            }.joined(separator: "\n")
        }
    }
}
