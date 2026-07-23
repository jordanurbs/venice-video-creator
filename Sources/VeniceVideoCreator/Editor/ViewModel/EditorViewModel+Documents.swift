import Foundation

extension EditorViewModel {
    // MARK: - Reads

    var documents: [ProjectDocument] {
        mediaManifest.documents.sorted { $0.updatedAt > $1.updatedAt }
    }

    func document(id: String) -> ProjectDocument? {
        mediaManifest.documents.first { $0.id == id }
    }

    func document(named name: String) -> ProjectDocument? {
        mediaManifest.documents.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    // MARK: - Writes

    /// Creates a new document or overwrites the existing one with the same name.
    @discardableResult
    func saveDocument(name: String, content: String) -> ProjectDocument {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "Untitled" : trimmedName

        if let idx = mediaManifest.documents.firstIndex(where: {
            $0.name.caseInsensitiveCompare(finalName) == .orderedSame
        }) {
            let previous = mediaManifest.documents[idx]
            mediaManifest.documents[idx].content = content
            mediaManifest.documents[idx].name = finalName
            mediaManifest.documents[idx].updatedAt = Date()
            let updated = mediaManifest.documents[idx]
            registerDocumentUndo(previous: previous, actionName: "Edit Document")
            writeDocumentMirror(updated)
            onProjectContentChanged?()
            requestDebouncedCheckpoint()
            return updated
        }

        let doc = ProjectDocument(name: finalName, content: content)
        mediaManifest.documents.append(doc)
        let id = doc.id
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.deleteDocument(id: id)
        }
        undoManager?.setActionName("New Document")
        writeDocumentMirror(doc)
        onProjectContentChanged?()
        requestDebouncedCheckpoint()
        return doc
    }

    func deleteDocument(id: String) {
        guard let idx = mediaManifest.documents.firstIndex(where: { $0.id == id }) else { return }
        let removed = mediaManifest.documents.remove(at: idx)
        undoManager?.registerUndo(withTarget: self) { vm in
            vm.mediaManifest.documents.append(removed)
            vm.writeDocumentMirror(removed)
            vm.onProjectContentChanged?()
        }
        undoManager?.setActionName("Delete Document")
        removeDocumentMirror(removed)
        onProjectContentChanged?()
        requestDebouncedCheckpoint()
    }

    // MARK: - Undo helper

    private func registerDocumentUndo(previous: ProjectDocument, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { vm in
            if let idx = vm.mediaManifest.documents.firstIndex(where: { $0.id == previous.id }) {
                let current = vm.mediaManifest.documents[idx]
                vm.mediaManifest.documents[idx] = previous
                vm.writeDocumentMirror(previous)
                vm.onProjectContentChanged?()
                vm.registerDocumentUndo(previous: current, actionName: actionName)
            }
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - On-disk mirror (.md file in the media directory)

    /// URL of the `.md` mirror inside the project's media directory, or nil when unsaved.
    func documentFileURL(for doc: ProjectDocument) -> URL? {
        guard let projectURL else { return nil }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        return mediaDir.appendingPathComponent("doc-\(doc.id.prefix(8))-\(Self.safeFilename(doc.name)).md")
    }

    private func writeDocumentMirror(_ doc: ProjectDocument) {
        guard let url = documentFileURL(for: doc) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? doc.content.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    private func removeDocumentMirror(_ doc: ProjectDocument) {
        guard let url = documentFileURL(for: doc) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func safeFilename(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        return String(cleaned).replacingOccurrences(of: " ", with: "-").prefix(48).description
    }
}
