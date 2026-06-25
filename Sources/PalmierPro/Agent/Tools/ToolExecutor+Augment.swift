import Foundation

extension ToolExecutor {
    private func veniceAPI() throws -> VeniceAPI {
        guard let api = VeniceAPI.fromKeychain() else {
            throw ToolError("This requires a Venice API key. Tell the user to add it in Settings.")
        }
        return api
    }

    func webSearch(_ args: [String: Any]) async throws -> ToolResult {
        let query = try args.requireString("query")
        guard query.count <= 400 else {
            throw ToolError("query must be 1–400 characters (got \(query.count)).")
        }
        let api = try veniceAPI()
        let limit = args.int("limit") ?? 10
        let provider = args.string("provider") ?? "brave"
        let results = try await api.augmentSearch(query: query, limit: limit, provider: provider)
        guard !results.isEmpty else {
            return .ok("No results for \"\(query)\".")
        }
        let payload: [String: Any] = [
            "query": query,
            "results": results.map { r -> [String: Any] in
                var out: [String: Any] = ["title": r.title, "url": r.url, "content": r.content]
                if let date = r.date { out["date"] = date }
                return out
            },
        ]
        guard let json = Self.jsonString(payload) else {
            return .error("Failed to encode search results.")
        }
        return .ok(json)
    }

    func fetchURL(_ args: [String: Any]) async throws -> ToolResult {
        let url = try args.requireString("url")
        let api = try veniceAPI()
        let markdown = try await api.augmentScrape(url: url)
        guard !markdown.isEmpty else {
            return .ok("The page returned no readable content.")
        }
        return .ok(markdown)
    }

    func parseDocument(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let path = try args.requireString("path")
        let fileURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ToolError("No file at path: \(fileURL.path)")
        }
        let api = try veniceAPI()
        let (text, tokens) = try await api.augmentParseDocument(fileURL: fileURL)
        let header = tokens.map { "Extracted \($0) tokens from \(fileURL.lastPathComponent):\n\n" }
            ?? "Extracted text from \(fileURL.lastPathComponent):\n\n"
        return .ok(header + text)
    }
}
