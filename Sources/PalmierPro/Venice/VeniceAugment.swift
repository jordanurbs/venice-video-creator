import Foundation

/// A single web search result from Venice `/augment/search`.
struct VeniceSearchResult: Sendable {
    let title: String
    let url: String
    let content: String
    let date: String?
}

extension VeniceAPI {
    /// Venice `/augment/search` — privacy-preserving web search.
    func augmentSearch(query: String, limit: Int = 10, provider: String = "brave") async throws -> [VeniceSearchResult] {
        let body: [String: Any] = [
            "query": query,
            "limit": max(1, min(20, limit)),
            "search_provider": provider,
        ]
        let obj = try await postJSON(path: "augment/search", body: body)
        let results = (obj["results"] as? [[String: Any]]) ?? []
        return results.map {
            VeniceSearchResult(
                title: ($0["title"] as? String) ?? "",
                url: ($0["url"] as? String) ?? "",
                content: ($0["content"] as? String) ?? "",
                date: $0["date"] as? String
            )
        }
    }

    /// Venice `/augment/scrape` — fetch a URL and return markdown.
    func augmentScrape(url: String) async throws -> String {
        let obj = try await postJSON(path: "augment/scrape", body: ["url": url])
        guard let content = obj["content"] as? String else {
            throw VeniceError.decode("no content in scrape response")
        }
        return content
    }

    /// Venice `/augment/text-parser` — extract text from a document file.
    /// Returns the extracted text and an approximate token count.
    func augmentParseDocument(fileURL: URL) async throws -> (text: String, tokens: Int?) {
        let data = try Data(contentsOf: fileURL)
        let contentType = Self.documentContentType(for: fileURL)
        let request = makeMultipartRequest(
            path: "augment/text-parser",
            fields: ["response_format": "json"],
            file: (field: "file", filename: fileURL.lastPathComponent, contentType: contentType, data: data)
        )
        let (respData, response) = try await self.data(for: request)
        try Self.assertOK(data: respData, response: response)
        guard let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let text = obj["text"] as? String else {
            throw VeniceError.decode("no text in parser response")
        }
        return (text, obj["tokens"] as? Int)
    }

    private static func documentContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "txt", "md": return "text/plain"
        default: return "application/octet-stream"
        }
    }
}
