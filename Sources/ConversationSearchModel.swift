import Foundation

// MARK: - View model bridging EmbeddingIndex actor to ConversationView

@MainActor
final class ConversationSearchModel: ObservableObject {
    @Published var query: String = ""
    @Published var indexingState: IndexingState = .idle
    @Published var results: [EmbeddingIndex.SearchResult] = []

    enum IndexingState: Equatable {
        case idle
        case indexing(progress: Double)
        case ready
        case failed(String)

        static func == (lhs: IndexingState, rhs: IndexingState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.ready, .ready): return true
            case (.indexing(let a), .indexing(let b)): return a == b
            case (.failed(let a), .failed(let b)): return a == b
            default: return false
            }
        }
    }

    private let index = EmbeddingIndex()
    private var searchTask: Task<Void, Never>?
    private var currentSessionId: String?

    // MARK: - Indexing

    func beginIndexing(sessionId: String, cwd: String, messages: [ChatMessage]) async {
        currentSessionId = sessionId
        indexingState = .indexing(progress: 0)

        await index.buildIndex(for: sessionId, cwd: cwd, messages: messages) { [weak self] p in
            Task { @MainActor [weak self] in
                guard self?.currentSessionId == sessionId else { return }
                self?.indexingState = .indexing(progress: p)
            }
        }

        guard currentSessionId == sessionId else { return }
        indexingState = .ready
    }

    // MARK: - Search (debounced)

    func scheduleSearch() {
        searchTask?.cancel()

        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            results = []
            return
        }

        let currentQuery = query
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            let found = await index.search(query: currentQuery)
            guard !Task.isCancelled else { return }
            results = found
        }
    }

    // MARK: - Reset

    func reset() {
        query = ""
        results = []
        indexingState = .idle
        searchTask?.cancel()
        currentSessionId = nil
        Task { await index.reset() }
    }
}
