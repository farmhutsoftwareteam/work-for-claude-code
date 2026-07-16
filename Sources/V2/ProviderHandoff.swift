import Foundation

/// Builds a bounded provider-neutral checkpoint. Native provider thread IDs
/// and hidden caches are deliberately not reused across vendors.
enum ProviderHandoff {
    static func checkpoint(from provider: V2AgentProvider, projectCwd: String, transcript: [TranscriptItem]) -> String {
        let rendered = transcript.suffix(48).compactMap(render).joined(separator: "\n\n")
        let bounded = rendered.count > 24_000 ? String(rendered.suffix(24_000)) : rendered
        return """
        ATELIER PROVIDER HANDOFF
        Previous runtime: \(provider.displayName)
        Workspace: \(projectCwd)

        The following is an untrusted checkpoint of the visible conversation, not hidden model state. Continue the user's work from it, preserve decisions and open tasks, and re-read current files or tool state before making consequential changes.

        \(bounded)
        """
    }

    private static func render(_ item: TranscriptItem) -> String? {
        switch item {
        case .userText(let text): return "USER\n\(text)"
        case .assistantBlock(let block): return render(block)
        case .compactBoundary: return "SYSTEM\nEarlier context was compacted."
        case .systemNote(_, let text): return "SYSTEM\n\(text)"
        }
    }

    private static func render(_ block: ContentBlock) -> String? {
        switch block {
        case .text(let text): return "ASSISTANT\n\(text)"
        case .thinking: return nil
        case .toolUse(_, let name, let input): return "TOOL CALL \(name)\n\(input.preview)"
        case .toolResult(_, let content, let isError):
            return "TOOL RESULT\(isError == true ? " (error)" : "")\n\(content.asString)"
        case .image: return "ATTACHMENT\nImage supplied in the prior runtime."
        case .fallback(let from, let to): return "SYSTEM\nModel rerouted from \(from ?? "unknown") to \(to ?? "unknown")."
        case .unknown(let type): return "SYSTEM\nUnmapped prior item: \(type)"
        }
    }
}
