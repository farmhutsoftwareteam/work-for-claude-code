// Anthropic Messages API content block — text, tool_use, tool_result, thinking.
// Used inside `assistant` and `user` events and as the payload of
// `content_block_start` SSE events. The tool_result `content` is polymorphic
// (string OR array of blocks) — handled here.

import Foundation
import OSLog

private let log = Logger(subsystem: "com.munyamakosa.work", category: "contentblock")

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
        // Each `try?` below is a decode fallback: if the field is missing or
        // the wrong shape, we render an empty/default block instead of
        // failing the whole event — but silently doing so is indistinguishable
        // from a legitimately empty block (M1, bug-hunt 2026-07-10). Log a
        // warning whenever a fallback actually fires so a real API-shape
        // change shows up somewhere instead of just a blank row.
        switch type {
        case "text":
            if let text = try? c.decode(String.self, forKey: .text) {
                self = .text(text)
            } else {
                log.warning("ContentBlock decode fallback: 'text' missing/invalid on type=text")
                self = .text("")
            }
        case "tool_use":
            let id = try? c.decode(String.self, forKey: .id)
            let name = try? c.decode(String.self, forKey: .name)
            let input = try? c.decode(JSONValue.self, forKey: .input)
            if id == nil || name == nil || input == nil {
                log.warning("ContentBlock decode fallback: id/name/input missing on type=tool_use")
            }
            self = .toolUse(id: id ?? "", name: name ?? "", input: input ?? .object([:]))
        case "tool_result":
            let toolUseId = try? c.decode(String.self, forKey: .toolUseId)
            let content = try? c.decode(ToolResultContent.self, forKey: .content)
            if toolUseId == nil || content == nil {
                log.warning("ContentBlock decode fallback: tool_use_id/content missing on type=tool_result")
            }
            self = .toolResult(
                toolUseId: toolUseId ?? "",
                content: content ?? .text(""),
                isError: try? c.decodeIfPresent(Bool.self, forKey: .isError)
            )
        case "thinking":
            if let text = try? c.decode(String.self, forKey: .thinking) {
                self = .thinking(text: text, signature: try? c.decodeIfPresent(String.self, forKey: .signature))
            } else {
                log.warning("ContentBlock decode fallback: 'thinking' missing/invalid on type=thinking")
                self = .thinking(text: "", signature: try? c.decodeIfPresent(String.self, forKey: .signature))
            }
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
