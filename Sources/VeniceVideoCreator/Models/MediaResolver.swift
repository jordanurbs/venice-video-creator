import Foundation

/// Resolves asset IDs to file URLs using the media manifest.
final class MediaResolver: @unchecked Sendable {
    private let manifest: () -> MediaManifest
    private let projectURL: () -> URL?

    init(manifest: @escaping () -> MediaManifest, projectURL: @escaping () -> URL?) {
        self.manifest = manifest
        self.projectURL = projectURL
    }

    func resolveURL(for assetId: String) -> URL? {
        guard let entry = entry(for: assetId) else { return nil }
        return Self.existingURL(for: entry, projectURL: projectURL())
    }

    func expectedURL(for assetId: String) -> URL? {
        guard let entry = entry(for: assetId) else { return nil }
        return Self.expectedURL(for: entry, projectURL: projectURL())
    }

    func expectedURLMap() -> [String: URL] {
        Self.expectedURLMap(entries: manifest().entries, projectURL: projectURL())
    }

    /// Resolved URLs preferring files that actually exist on disk (healing stale
    /// paths), falling back to the nominal path so callers can report offline.
    static func expectedURLMap(entries: [MediaManifestEntry], projectURL: URL?) -> [String: URL] {
        Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            let url = existingURL(for: entry, projectURL: projectURL)
                ?? expectedURL(for: entry, projectURL: projectURL)
            return url.map { (entry.id, $0) }
        })
    }

    static func expectedURL(for entry: MediaManifestEntry, projectURL: URL?) -> URL? {
        switch entry.source {
        case .external(let absolutePath):
            return URL(fileURLWithPath: absolutePath, isDirectory: false)
        case .project(let relativePath):
            guard let base = projectURL else { return nil }
            return base.appendingPathComponent(relativePath, isDirectory: false)
        }
    }

    private static func isRegularFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
    }

    /// Resolve an entry to a real file on disk. Heals stale paths (temp dir, moved
    /// or renamed package, or a degenerate path pointing at a directory) by locating
    /// the asset inside the project's `media/` folder, where generated assets live.
    static func existingURL(for entry: MediaManifestEntry, projectURL: URL?) -> URL? {
        // 1. The stored path — but only if it's an actual file, not a directory.
        if let url = expectedURL(for: entry, projectURL: projectURL), isRegularFile(url) {
            return url
        }
        guard let projectURL else { return nil }
        let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)

        // 2. Same filename inside media/ (relocated/renamed package).
        let byName = mediaDir.appendingPathComponent(entry.source.basename)
        if isRegularFile(byName) { return byName }

        // 3. Generated assets are named after the entry id: gen-<id8>.<ext>. This
        //    recovers entries whose stored path was lost entirely.
        let stem = "gen-" + entry.id.prefix(8)
        if let items = try? FileManager.default.contentsOfDirectory(
            at: mediaDir, includingPropertiesForKeys: [.isRegularFileKey]
        ), let match = items.first(where: { $0.deletingPathExtension().lastPathComponent == stem }) {
            return match
        }
        return nil
    }

    func isMissing(for assetId: String) -> Bool {
        guard let entry = entry(for: assetId) else { return true }
        return Self.existingURL(for: entry, projectURL: projectURL()) == nil
    }

    /// Compute the set of asset IDs whose backing file is missing on disk, from a
    /// snapshot of manifest entries + the project base path
    static func missingAssetIds(entries: [MediaManifestEntry], projectPath: String?) -> Set<String> {
        let projectURL = projectPath.map { URL(fileURLWithPath: $0) }
        var missing: Set<String> = []
        for entry in entries where existingURL(for: entry, projectURL: projectURL) == nil {
            missing.insert(entry.id)
        }
        return missing
    }

    func displayName(for assetId: String) -> String {
        entry(for: assetId)?.name ?? "Offline"
    }

    func entry(for assetId: String) -> MediaManifestEntry? {
        manifest().entries.first(where: { $0.id == assetId })
    }
}
