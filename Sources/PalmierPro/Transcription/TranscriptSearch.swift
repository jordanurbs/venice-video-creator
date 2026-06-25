import Accelerate
import CryptoKit
import Foundation

/// Keyword + (Venice embedding) semantic search over cached transcripts.
enum TranscriptSearch {
    struct Hit: Equatable {
        let assetID: String
        let start: Double
        let end: Double
        let text: String
        var score: Double = 0
    }

    // MARK: - Semantic search (Venice embeddings)

    /// Ranks transcript segments by cosine similarity to the query embedding.
    /// Requires a Venice key + an embedding model; returns nil to signal the
    /// caller should fall back to keyword search.
    static func semanticSearch(
        query: String, assets: [(id: String, url: URL)], limit: Int = 20
    ) async -> [Hit]? {
        guard let api = await MainActor.run(body: { VeniceAPI.fromKeychain() }),
              let model = await MainActor.run(body: { ModelCatalog.shared.defaultEmbeddingModel })
        else { return nil }

        guard let queryVec = (try? await api.embeddings(input: [query], model: model))?.first,
              !queryVec.isEmpty else { return nil }

        var scored: [Hit] = []
        for asset in assets {
            guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url),
                  !transcript.segments.isEmpty else { continue }
            guard let vectors = await TranscriptEmbeddingStore.shared.embeddings(
                for: asset.url, segments: transcript.segments, model: model, api: api
            ) else { continue }
            for (i, segment) in transcript.segments.enumerated() where i < vectors.count {
                let score = cosine(queryVec, vectors[i])
                scored.append(Hit(assetID: asset.id, start: segment.start, end: segment.end,
                                  text: segment.text, score: Double(score)))
            }
        }
        guard !scored.isEmpty else { return [] }
        return Array(scored.sorted { $0.score > $1.score }.prefix(limit))
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        guard n > 0 else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(n))
        vDSP_dotpr(a, 1, a, 1, &na, vDSP_Length(n))
        vDSP_dotpr(b, 1, b, 1, &nb, vDSP_Length(n))
        let denom = (na.squareRoot() * nb.squareRoot())
        return denom > 0 ? dot / denom : 0
    }

    // MARK: - Keyword search

    static func search(query: String, assets: [(id: String, url: URL)], limit: Int = 20) -> [Hit] {
        let terms = terms(in: query)
        guard !terms.isEmpty else { return [] }

        var hits: [Hit] = []
        for asset in assets {
            guard let transcript = TranscriptCache.cachedOnDisk(for: asset.url) else { continue }
            for segment in transcript.segments where matches(segment.text, terms: terms) {
                hits.append(Hit(assetID: asset.id, start: segment.start, end: segment.end, text: segment.text))
                if hits.count >= limit { return hits }
            }
        }
        return hits
    }

    /// Query split into words, edge punctuation stripped (so "budget," → "budget").
    static func terms(in query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ text: String, terms: [String]) -> Bool {
        terms.allSatisfy { text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
