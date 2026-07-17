import Foundation

struct MediaManifest: Codable, Sendable, Equatable {
    var version: Int = 3
    var entries: [MediaManifestEntry] = []
    var folders: [MediaFolder] = []
    var documents: [ProjectDocument] = []
    /// The agent/production shot plan for this project, if any (version 3+).
    var shotPlan: ShotPlan?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        entries = try c.decodeIfPresent([MediaManifestEntry].self, forKey: .entries) ?? []
        folders = try c.decodeIfPresent([MediaFolder].self, forKey: .folders) ?? []
        documents = try c.decodeIfPresent([ProjectDocument].self, forKey: .documents) ?? []
        shotPlan = try c.decodeIfPresent(ShotPlan.self, forKey: .shotPlan)
    }

    init() {}

    private enum CodingKeys: String, CodingKey { case version, entries, folders, documents, shotPlan }
}

/// A markdown document authored in the project (scripts, storyboards, shot lists).
/// Stored in the manifest so it persists and travels with the project; also mirrored
/// as a real `.md` file in the media directory for external editing.
struct ProjectDocument: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var content: String
    var updatedAt: Date

    init(id: String = UUID().uuidString, name: String, content: String, updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.content = content
        self.updatedAt = updatedAt
    }
}

struct MediaManifestEntry: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var type: ClipType
    var source: MediaSource
    var duration: Double
    var generationInput: GenerationInput?
    var sourceWidth: Int?
    var sourceHeight: Int?
    var sourceFPS: Double?
    var hasAudio: Bool?
    var folderId: String?
    var cachedRemoteURL: String?
    var cachedRemoteURLExpiresAt: Date?
    var generationStatus: String?
    var importInput: MediaImportInput?
}

struct MediaImportInput: Codable, Sendable, Equatable {
    var sourceURL: String? = nil
    var sourcePath: String? = nil
    var createdAt: Date? = nil
}

struct GenerationInput: Codable, Sendable, Equatable {
    var prompt: String
    var model: String
    var duration: Int
    var aspectRatio: String
    var resolution: String?
    var quality: String?
    var imageURLs: [String]?
    /// Image-only
    var numImages: Int?
    /// Image-only: Venice `/image/generate` style preset (from `/image/styles`).
    var stylePreset: String?
    /// Audio-only
    var voice: String?
    var lyrics: String?
    var styleInstructions: String?
    var instrumental: Bool?
    /// Video-only
    var generateAudio: Bool?
    var referenceImageURLs: [String]?
    var referenceVideoURLs: [String]?
    var referenceAudioURLs: [String]?

    /// Asset IDs for the references.
    var imageURLAssetIds: [String]?
    var referenceImageAssetIds: [String]?
    var referenceVideoAssetIds: [String]?
    var referenceAudioAssetIds: [String]?
    var createdAt: Date?
    var backendJobId: String?
    var outputIndex: Int?
    var resultURLs: [String]?
    /// Venice queue id for async video/audio jobs; the handle that survives relaunch.
    var queueId: String?
    var queueDownloadURL: String?
}

enum MediaSource: Codable, Sendable, Equatable {
    case external(absolutePath: String)
    case project(relativePath: String)

    var basename: String {
        switch self {
        case .external(let p): return (p as NSString).lastPathComponent
        case .project(let p): return (p as NSString).lastPathComponent
        }
    }

    /// Classify a file URL relative to the project package. A file that physically
    /// lives inside the project is stored relative so the project stays portable
    /// (survives moves/renames); anything else is stored as an absolute path.
    static func make(for url: URL, projectURL: URL?) -> MediaSource {
        if let projectURL, let relative = relativePath(of: url, under: projectURL) {
            return .project(relativePath: relative)
        }
        return .external(absolutePath: url.standardizedFileURL.path)
    }

    /// Path of `url` relative to `base`, or nil when `url` is not inside `base`.
    /// Normalizes symlinks so `/var` vs `/private/var` (and `~`) don't misclassify
    /// an in-project file as external.
    static func relativePath(of url: URL, under base: URL) -> String? {
        let baseParts = base.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let urlParts = url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        guard urlParts.count > baseParts.count,
              Array(urlParts.prefix(baseParts.count)) == baseParts else { return nil }
        return urlParts.dropFirst(baseParts.count).joined(separator: "/")
    }
}
