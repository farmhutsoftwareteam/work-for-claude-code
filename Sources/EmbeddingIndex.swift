import Foundation
import NaturalLanguage
import Accelerate

// MARK: - Semantic search index backed by NLEmbedding

actor EmbeddingIndex {

    // MARK: - Types

    struct MessageChunk: Sendable {
        let messageId: UUID
        let chunkIndex: Int
        let text: String
        var vector: [Float]
    }

    struct SearchResult: Sendable {
        let messageId: UUID
        let score: Float
    }

    // MARK: - State

    private var chunks: [MessageChunk] = []
    private var embedding: NLEmbedding?
    private var isReady = false

    // MARK: - Build index

    func buildIndex(
        for sessionId: String,
        cwd: String,
        messages: [ChatMessage],
        progress: @Sendable @escaping (Double) -> Void
    ) async {
        let encodedCwd = cwd.replacingOccurrences(of: "/", with: "-")

        // Try loading from cache
        if let cached = loadCache(sessionId: sessionId, encodedCwd: encodedCwd, expectedCount: messages.count) {
            chunks = cached
            isReady = true
            progress(1.0)
            return
        }

        // Initialize NLEmbedding
        guard let nlEmbedding = NLEmbedding.sentenceEmbedding(for: .english) else {
            // Fall back — no embedding available, lexical only
            chunks = messages.flatMap { msg in
                Self.shouldIndex(msg)
                    ? chunkText(msg).enumerated().map { (i, text) in
                        MessageChunk(messageId: msg.id, chunkIndex: i, text: text, vector: [])
                    }
                    : []
            }
            isReady = true
            progress(1.0)
            return
        }
        embedding = nlEmbedding

        // Chunk all messages — but skip `.toolResult` rows. Tool output is
        // typically multi-MB file dumps / grep output that nobody wants to
        // semantic-search. Indexing them was the dominant memory cost of
        // this actor (a 191MB session produced ~1GB of chunk+vector data).
        // We still index user prompts and assistant text replies via
        // `shouldIndex`, which is the part anyone actually searches for.
        var allChunks: [MessageChunk] = []
        let total = Double(messages.count)
        for (idx, msg) in messages.enumerated() {
            defer { progress(Double(idx + 1) / total) }
            guard Self.shouldIndex(msg) else { continue }
            let texts = chunkText(msg)
            for (ci, text) in texts.enumerated() {
                let vector = embed(text, using: nlEmbedding)
                allChunks.append(MessageChunk(
                    messageId: msg.id,
                    chunkIndex: ci,
                    text: text,
                    vector: vector
                ))
            }
        }

        chunks = allChunks
        isReady = true

        // Save to cache
        saveCache(chunks: allChunks, sessionId: sessionId, encodedCwd: encodedCwd, messageCount: messages.count)
    }

    /// Whether to feed this message into the index at all. Tool results are
    /// excluded — see the long-form note in `buildIndex`.
    private static func shouldIndex(_ msg: ChatMessage) -> Bool {
        switch msg.kind {
        case .text, .toolUse: return true
        case .toolResult:     return false
        }
    }

    /// Cap on how many 512-char chunks we'll emit per single message. A pasted
    /// 5MB log file shouldn't blow up the index — the first ~16KB (32 × 512)
    /// is enough for semantic search to land you on the right message; you
    /// can read the rest in the row view.
    private static let maxChunksPerMessage = 32

    // MARK: - Search

    func search(query: String, topK: Int = 15) -> [SearchResult] {
        guard isReady, !query.isEmpty else { return [] }

        let queryLower = query.lowercased()

        // Embed the query if we have the embedding model
        let queryVector: [Float]?
        if let nlEmbedding = embedding {
            let vec = embed(query, using: nlEmbedding)
            queryVector = vec.isEmpty ? nil : vec
        } else {
            queryVector = nil
        }

        // Score each chunk
        var messageScores: [UUID: Float] = [:]
        for chunk in chunks {
            var score: Float = 0

            // Semantic score
            if let qv = queryVector, !chunk.vector.isEmpty {
                let sim = cosineSimilarity(qv, chunk.vector)
                score += 0.75 * max(0, sim)
            }

            // Lexical score
            if chunk.text.lowercased().contains(queryLower) {
                score += 0.25
            }

            // Keep max score per message
            if let existing = messageScores[chunk.messageId] {
                messageScores[chunk.messageId] = max(existing, score)
            } else {
                messageScores[chunk.messageId] = score
            }
        }

        // Sort and return top K
        return messageScores
            .map { SearchResult(messageId: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .filter { $0.score > 0.05 }
            .map { $0 }
    }

    // MARK: - Reset

    func reset() {
        chunks = []
        isReady = false
    }

    // MARK: - Chunking

    private func chunkText(_ message: ChatMessage) -> [String] {
        let text = message.text
        // Short messages: embed whole
        if text.count <= 512 { return [text] }

        // Split on paragraph boundaries
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        outer: for para in paragraphs {
            if para.count <= 512 {
                result.append(para)
                if result.count >= Self.maxChunksPerMessage { break outer }
            } else {
                // Split long paragraphs by sentences
                let tokenizer = NLTokenizer(unit: .sentence)
                tokenizer.string = para
                var sentences: [String] = []
                tokenizer.enumerateTokens(in: para.startIndex..<para.endIndex) { range, _ in
                    sentences.append(String(para[range]))
                    return true
                }
                // Group sentences into ~512 char chunks
                var current = ""
                for sentence in sentences {
                    if current.count + sentence.count > 512 && !current.isEmpty {
                        result.append(current)
                        if result.count >= Self.maxChunksPerMessage { break outer }
                        current = sentence
                    } else {
                        current += (current.isEmpty ? "" : " ") + sentence
                    }
                }
                if !current.isEmpty {
                    result.append(current)
                    if result.count >= Self.maxChunksPerMessage { break outer }
                }
            }
        }
        return result.isEmpty ? [text] : result
    }

    // MARK: - Embedding

    private func embed(_ text: String, using nlEmbedding: NLEmbedding) -> [Float] {
        guard let vector = nlEmbedding.vector(for: text) else { return [] }
        return vector.map { Float($0) }
    }

    // MARK: - Cosine similarity (Accelerate/vDSP)

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        let count = vDSP_Length(a.count)
        vDSP_dotpr(a, 1, b, 1, &dotProduct, count)
        vDSP_svesq(a, 1, &normA, count)
        vDSP_svesq(b, 1, &normB, count)
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 1e-8 ? dotProduct / denom : 0
    }

    // MARK: - Disk cache

    private func cacheDir(encodedCwd: String) -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("com.munyamakosa.work")
            .appendingPathComponent("embeddings")
            .appendingPathComponent(encodedCwd)
    }

    private func cacheURL(sessionId: String, encodedCwd: String) -> URL {
        cacheDir(encodedCwd: encodedCwd).appendingPathComponent(sessionId + ".bin")
    }

    private func loadCache(sessionId: String, encodedCwd: String, expectedCount: Int) -> [MessageChunk]? {
        let url = cacheURL(sessionId: sessionId, encodedCwd: encodedCwd)
        guard let data = try? Data(contentsOf: url) else { return nil }

        // Binary format: [UInt32 version][UInt32 messageCount][UInt32 chunkCount]
        // Per chunk: [16 bytes UUID][Int32 chunkIndex][UInt32 textLen][text bytes][UInt32 vecLen][Float bytes]
        var offset = 0

        func readUInt32() -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            let value = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            offset += 4
            return value
        }

        guard let version = readUInt32(), version == 1,
              let msgCount = readUInt32(), msgCount == UInt32(expectedCount),
              let chunkCount = readUInt32() else { return nil }

        var result: [MessageChunk] = []
        for _ in 0..<chunkCount {
            // UUID (16 bytes)
            guard offset + 16 <= data.count else { return nil }
            let uuid = data.subdata(in: offset..<offset+16).withUnsafeBytes { buf in
                UUID(uuid: buf.load(as: uuid_t.self))
            }
            offset += 16

            // chunkIndex
            guard offset + 4 <= data.count else { return nil }
            let ci = data.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: Int32.self) }
            offset += 4

            // text
            guard let textLen = readUInt32(), offset + Int(textLen) <= data.count else { return nil }
            let text = String(data: data.subdata(in: offset..<offset+Int(textLen)), encoding: .utf8) ?? ""
            offset += Int(textLen)

            // vector
            guard let vecLen = readUInt32(), offset + Int(vecLen) * 4 <= data.count else { return nil }
            let floatCount = Int(vecLen)
            let vector: [Float] = data.subdata(in: offset..<offset + floatCount * 4).withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            }
            offset += floatCount * 4

            result.append(MessageChunk(messageId: uuid, chunkIndex: Int(ci), text: text, vector: vector))
        }
        return result
    }

    private func saveCache(chunks: [MessageChunk], sessionId: String, encodedCwd: String, messageCount: Int) {
        let dir = cacheDir(encodedCwd: encodedCwd)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var data = Data()

        func appendUInt32(_ v: UInt32) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
        func appendInt32(_ v: Int32) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }

        appendUInt32(1) // version
        appendUInt32(UInt32(messageCount))
        appendUInt32(UInt32(chunks.count))

        for chunk in chunks {
            // UUID
            withUnsafeBytes(of: chunk.messageId.uuid) { data.append(contentsOf: $0) }
            // chunkIndex
            appendInt32(Int32(chunk.chunkIndex))
            // text
            let textData = Data(chunk.text.utf8)
            appendUInt32(UInt32(textData.count))
            data.append(textData)
            // vector
            appendUInt32(UInt32(chunk.vector.count))
            chunk.vector.withUnsafeBytes { data.append(contentsOf: $0) }
        }

        let url = cacheURL(sessionId: sessionId, encodedCwd: encodedCwd)
        try? data.write(to: url)
    }
}
