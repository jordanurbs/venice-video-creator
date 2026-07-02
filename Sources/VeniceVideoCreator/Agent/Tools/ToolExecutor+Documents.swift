import Foundation

extension ToolExecutor {
    func saveDocument(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let name = try args.requireString("name")
        let content = try args.requireString("content")
        let doc = editor.saveDocument(name: name, content: content)
        let body: [String: Any] = [
            "id": doc.id,
            "name": doc.name,
            "characters": doc.content.count,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    func readDocument(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let doc: ProjectDocument?
        if let id = args.string("id") {
            doc = editor.document(id: id)
        } else if let name = args.string("name") {
            doc = editor.document(named: name)
        } else {
            throw ToolError("Provide either 'id' or 'name'.")
        }
        guard let doc else {
            let available = editor.documents.map(\.name).joined(separator: ", ")
            throw ToolError("Document not found. Available: \(available.isEmpty ? "(none)" : available)")
        }
        let body: [String: Any] = [
            "id": doc.id,
            "name": doc.name,
            "content": doc.content,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    func listDocuments(_ editor: EditorViewModel) -> ToolResult {
        let docs = editor.documents.map { doc -> [String: Any] in
            [
                "id": doc.id,
                "name": doc.name,
                "characters": doc.content.count,
                "updatedAt": ISO8601DateFormatter().string(from: doc.updatedAt),
            ]
        }
        return .ok(Self.jsonString(["documents": docs]) ?? "{}")
    }
}
