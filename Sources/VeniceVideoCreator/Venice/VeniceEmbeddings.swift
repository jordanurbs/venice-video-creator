import Foundation

extension VeniceAPI {
    /// Venice `/embeddings` — vector embeddings for one or more strings.
    /// Returns one vector per input, in order. Batches large inputs.
    func embeddings(input: [String], model: String) async throws -> [[Float]] {
        guard !input.isEmpty else { return [] }
        var out: [[Float]] = []
        out.reserveCapacity(input.count)
        let batchSize = 64
        var i = 0
        while i < input.count {
            let slice = Array(input[i..<min(i + batchSize, input.count)])
            let obj = try await postJSON(path: "embeddings", body: [
                "model": model,
                "input": slice,
                "encoding_format": "float",
            ])
            guard let data = obj["data"] as? [[String: Any]] else {
                throw VeniceError.decode("no embedding data")
            }
            // Order by `index` to be safe.
            let sorted = data.sorted { (($0["index"] as? Int) ?? 0) < (($1["index"] as? Int) ?? 0) }
            for row in sorted {
                let vec = (row["embedding"] as? [Any])?.compactMap { v -> Float? in
                    if let d = v as? Double { return Float(d) }
                    if let f = v as? NSNumber { return f.floatValue }
                    return nil
                } ?? []
                out.append(vec)
            }
            i += batchSize
        }
        return out
    }
}
