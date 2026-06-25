import CryptoKit
import Foundation

/// Disk cache of per-segment transcript embeddings, keyed by file identity +
/// transcript content + embedding model, so it invalidates when any of those
/// change. Embeds missing entries via Venice once, then reuses them for search.
actor TranscriptEmbeddingStore {
    static let shared = TranscriptEmbeddingStore()

    private var memory: [String: [[Float]]] = [:]
    private static let memoryMax = 8

    func embeddings(
        for url: URL, segments: [TranscriptionSegment], model: String, api: VeniceAPI
    ) async -> [[Float]]? {
        let key = Self.key(url: url, segments: segments, model: model)
        if let cached = memory[key] { return cached }
        if let onDisk = Self.load(key) {
            remember(onDisk, key: key)
            return onDisk
        }
        // Compute and cache.
        let texts = segments.map(\.text)
        guard let vectors = try? await api.embeddings(input: texts, model: model),
              vectors.count == texts.count else {
            return nil
        }
        remember(vectors, key: key)
        Self.save(vectors, key: key)
        return vectors
    }

    private func remember(_ vectors: [[Float]], key: String) {
        if memory.count >= Self.memoryMax { memory.removeAll() }
        memory[key] = vectors
    }

    private static let directory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("\(Log.subsystem)/TranscriptEmbeddings", isDirectory: true)

    private static func diskURL(_ key: String) -> URL {
        directory.appendingPathComponent("\(key).json")
    }

    private static func load(_ key: String) -> [[Float]]? {
        guard let data = try? Data(contentsOf: diskURL(key)) else { return nil }
        return try? JSONDecoder().decode([[Float]].self, from: data)
    }

    private static func save(_ vectors: [[Float]], key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(vectors) {
            try? data.write(to: diskURL(key))
        }
    }

    private static func key(url: URL, segments: [TranscriptionSegment], model: String) -> String {
        var hasher = SHA256()
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) {
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            hasher.update(data: Data("\(url.path)|\(size)|\(mtime)".utf8))
        } else {
            hasher.update(data: Data(url.path.utf8))
        }
        hasher.update(data: Data("|\(model)|\(segments.count)|".utf8))
        for s in segments { hasher.update(data: Data(s.text.utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(32).description
    }
}
