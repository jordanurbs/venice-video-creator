import AppKit

// Reclaim disk space: deleted assets stay on disk inside the package (delete is
// undoable), so orphaned files accumulate until this maintenance pass removes them.
extension EditorViewModel {

    struct UnusedMediaScan {
        let urls: [URL]
        let totalBytes: Int64
    }

    /// Files in the package's media directory that no manifest entry, document
    /// mirror, or live asset references.
    func scanUnusedMedia() -> UnusedMediaScan {
        guard let projectURL else { return UnusedMediaScan(urls: [], totalBytes: 0) }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)

        var referenced = Set<String>()
        for entry in mediaManifest.entries {
            if case .project(let rel) = entry.source {
                referenced.insert(projectURL.appendingPathComponent(rel).standardizedFileURL.path)
            }
        }
        for doc in mediaManifest.documents {
            if let url = documentFileURL(for: doc) {
                referenced.insert(url.standardizedFileURL.path)
            }
        }
        for asset in mediaAssets {
            referenced.insert(asset.url.standardizedFileURL.path)
        }

        var urls: [URL] = []
        var bytes: Int64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: mediaDir, includingPropertiesForKeys: Array(keys)) else {
            return UnusedMediaScan(urls: [], totalBytes: 0)
        }
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            guard !referenced.contains(url.standardizedFileURL.path) else { continue }
            urls.append(url)
            bytes += Int64(values.fileSize ?? 0)
        }
        return UnusedMediaScan(urls: urls, totalBytes: bytes)
    }

    func removeUnusedMedia() {
        let scan = scanUnusedMedia()
        guard !scan.urls.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No unused media."
            alert.informativeText = "Every file in this project's media folder is referenced."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let size = ByteCountFormatter.string(fromByteCount: scan.totalBytes, countStyle: .file)
        let alert = NSAlert()
        alert.messageText = "Remove \(scan.urls.count) unused file\(scan.urls.count == 1 ? "" : "s") (\(size))?"
        alert.informativeText = "Files nothing in this project references are moved to the Trash. Undo history is cleared, since undone deletions could point at removed files."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Remove")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        var failed = 0
        for url in scan.urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                failed += 1
                Log.project.error("remove unused media failed: \(Log.ref(url)): \(error.localizedDescription)")
            }
        }
        undoManager?.removeAllActions()
        onProjectContentChanged?()

        if failed > 0 {
            let failAlert = NSAlert()
            failAlert.messageText = "Removed \(scan.urls.count - failed) of \(scan.urls.count) files."
            failAlert.informativeText = "\(failed) file\(failed == 1 ? "" : "s") couldn't be moved to the Trash."
            failAlert.addButton(withTitle: "OK")
            failAlert.runModal()
        }
    }
}
