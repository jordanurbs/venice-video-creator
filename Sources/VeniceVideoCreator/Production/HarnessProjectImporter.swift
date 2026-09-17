import Foundation

/// One-way import of a venice-video-harness project directory
/// (`VeniceVideos/<project>/`: series.json, episodes/episode-NNN/script.json,
/// rendered shot clips + provenance sidecars) into this app's document model.
///
/// The importer NEVER writes into the harness project — it reads state, copies
/// media into the package, and maps the harness script onto `ShotPlan`. The
/// source path is recorded on the shot plan document so "Refresh from Harness"
/// can re-scan later (additive: new clips and shots are added, app-side edits
/// are never overwritten or deleted).
enum HarnessProjectImporter {

    // MARK: - Harness on-disk shapes (tolerant subsets)

    struct HarnessSeries: Decodable {
        var name: String?
        var slug: String?
        var concept: String?
        var aesthetic: HarnessAesthetic?
        var characters: [HarnessCharacter]?
        var locations: [HarnessLocation]?
        var episodes: [HarnessEpisodeMeta]?
        var storyboardAspectRatio: String?
    }

    struct HarnessAesthetic: Decodable {
        var style: String?
        var palette: String?
    }

    struct HarnessCharacter: Decodable {
        var name: String?
        var description: String?
        var fullDescription: String?
        var voiceId: String?
    }

    struct HarnessLocation: Decodable {
        var name: String?
        var slug: String?
        var description: String?
        var lightingNotes: String?
        var spatialAnchors: String?
    }

    struct HarnessEpisodeMeta: Decodable {
        var number: Int?
        var title: String?
        var status: String?
    }

    struct HarnessScript: Decodable {
        var episode: Int?
        var title: String?
        var totalDuration: String?
        var status: String?
        var shots: [HarnessShot]?
    }

    struct HarnessShot: Decodable {
        var shotNumber: Int?
        var shotIdSuffix: String?
        var type: String?
        var duration: String?
        var description: String?
        var panelDescription: String?
        var characters: [String]?
        var location: String?
        var blocking: String?
        var dialogue: HarnessDialogue?
        var cameraMovement: String?
        var cameraTrajectory: CameraTrajectory?
        var camera_trajectory: CameraTrajectory?
        var transition: String?
    }

    struct HarnessDialogue: Decodable {
        var character: String?
        var line: String?
    }

    struct HarnessVideoSidecar: Decodable {
        struct Video: Decodable {
            var model: String?
            var prompt: String?
            var camera_trajectory: CameraTrajectory?
            var cameraTrajectory: CameraTrajectory?
        }
        var video: Video?
    }

    // MARK: - Scan result

    /// Everything found in one pass over the harness project, path-based and
    /// Sendable so the scan can run off the main actor before the view model
    /// applies it.
    struct Scan: Sendable {
        struct ShotEntry: Sendable {
            /// Zero-padded shot key including insert suffix, e.g. "003" / "003b".
            var key: String
            var shotNumber: Int
            var summary: String
            var prompt: String
            var storyboardPrompt: String?
            var durationSeconds: Double
            var characterNames: [String]
            var locationSlug: String?
            var blocking: String?
            var dialogue: [(speaker: String, line: String)]
            var transition: String?
            /// Rendered clip on disk (scene-001/shot-KEY.mp4), if present.
            var clipPath: String?
            /// Storyboard panel on disk (scene-001/shot-KEY.png), if present.
            var panelPath: String?
            /// Model recorded in the shot's .video.json sidecar, if present.
            var renderModel: String?
            var cameraTrajectory: CameraTrajectory?
        }

        struct CharacterEntry: Sendable {
            var name: String
            var description: String?
            /// Reference angle images under characters/<slug>/ (png only).
            var referencePaths: [String]
        }

        struct LocationEntry: Sendable {
            var name: String
            var slug: String
            var description: String?
            var lightingNotes: String?
            var spatialAnchors: String?
            var referencePaths: [String]
        }

        var projectPath: String
        var seriesName: String
        var concept: String?
        var styleBlock: String?
        var aspectRatio: String
        var episode: Int
        var episodeTitle: String?
        var shots: [ShotEntry]
        var characters: [CharacterEntry]
        var locations: [LocationEntry]
        /// Final assembled cut, if present.
        var finalCutPath: String?
        /// Music bed, if present.
        var musicPath: String?
    }

    enum ImportError: LocalizedError {
        case notAHarnessProject(String)
        case noEpisodes

        var errorDescription: String? {
            switch self {
            case .notAHarnessProject(let path):
                "No series.json found in \(path) — choose a harness project folder (VeniceVideos/<project>)."
            case .noEpisodes:
                "This harness project has no episodes with a script yet."
            }
        }
    }

    // MARK: - Scan

    private static func decodeJSON<T: Decodable>(_ type: T.Type, at path: String) -> T? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Parse a harness duration string ("12s", "8") into seconds.
    private static func seconds(from duration: String?) -> Double {
        guard let duration else { return 5 }
        let trimmed = duration.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "s", with: "")
        return Double(trimmed) ?? 5
    }

    private static func shotKey(number: Int, suffix: String?) -> String {
        String(format: "%03d", number) + (suffix ?? "")
    }

    private static func referenceImages(inDirectory dir: String) -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { name in
                name.hasSuffix(".png")
                    && !name.contains("-pre-")
                    && !name.contains("archive")
                    && !name.contains("anchor")
            }
            .sorted()
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    /// Read the harness project at `projectURL`. Imports the requested episode
    /// (or the first episode that has a script). Pure filesystem read.
    static func scan(projectURL: URL, episode requestedEpisode: Int? = nil) throws -> Scan {
        let root = projectURL.standardizedFileURL.path
        let seriesPath = (root as NSString).appendingPathComponent("series.json")
        guard let series = decodeJSON(HarnessSeries.self, at: seriesPath) else {
            throw ImportError.notAHarnessProject(root)
        }

        let episodeNumbers = (series.episodes ?? []).compactMap(\.number).sorted()
        let candidates = requestedEpisode.map { [$0] } ?? (episodeNumbers.isEmpty ? [1] : episodeNumbers)

        var chosen: (number: Int, script: HarnessScript)? = nil
        for number in candidates {
            let episodeDir = (root as NSString)
                .appendingPathComponent("episodes/episode-\(String(format: "%03d", number))")
            let scriptPath = (episodeDir as NSString).appendingPathComponent("script.json")
            if let script = decodeJSON(HarnessScript.self, at: scriptPath) {
                chosen = (number, script)
                break
            }
        }
        guard let (episodeNumber, script) = chosen else { throw ImportError.noEpisodes }

        let episodeDir = (root as NSString)
            .appendingPathComponent("episodes/episode-\(String(format: "%03d", episodeNumber))")
        let sceneDir = (episodeDir as NSString).appendingPathComponent("scene-001")
        let audioDir = (episodeDir as NSString).appendingPathComponent("audio")
        let fm = FileManager.default

        var shots: [Scan.ShotEntry] = []
        for shot in script.shots ?? [] {
            guard let number = shot.shotNumber else { continue }
            let key = shotKey(number: number, suffix: shot.shotIdSuffix)
            let clip = (sceneDir as NSString).appendingPathComponent("shot-\(key).mp4")
            let panel = (sceneDir as NSString).appendingPathComponent("shot-\(key).png")
            let sidecarPath = (sceneDir as NSString).appendingPathComponent("shot-\(key).video.json")
            let sidecar = decodeJSON(HarnessVideoSidecar.self, at: sidecarPath)

            var dialogue: [(speaker: String, line: String)] = []
            if let line = shot.dialogue, let text = line.line, !text.isEmpty {
                dialogue.append((speaker: line.character ?? "", line: text))
            }

            shots.append(Scan.ShotEntry(
                key: key,
                shotNumber: number,
                summary: shot.panelDescription ?? shot.description ?? "Shot \(number)",
                prompt: shot.description ?? "",
                storyboardPrompt: shot.panelDescription,
                durationSeconds: seconds(from: shot.duration),
                characterNames: shot.characters ?? [],
                locationSlug: shot.location,
                blocking: shot.blocking,
                dialogue: dialogue,
                transition: shot.transition,
                clipPath: fm.fileExists(atPath: clip) ? clip : nil,
                panelPath: fm.fileExists(atPath: panel) ? panel : nil,
                renderModel: sidecar?.video?.model,
                cameraTrajectory: sidecar?.video?.camera_trajectory ?? sidecar?.video?.cameraTrajectory ?? shot.cameraTrajectory ?? shot.camera_trajectory
            ))
        }

        var characters: [Scan.CharacterEntry] = []
        let charactersDir = (root as NSString).appendingPathComponent("characters")
        for character in series.characters ?? [] {
            guard let name = character.name else { continue }
            let slug = name.lowercased()
                .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let dir = (charactersDir as NSString).appendingPathComponent(slug)
            characters.append(Scan.CharacterEntry(
                name: name,
                description: character.description ?? character.fullDescription,
                referencePaths: referenceImages(inDirectory: dir)
            ))
        }

        var locations: [Scan.LocationEntry] = []
        let locationsDir = (root as NSString).appendingPathComponent("locations")
        for location in series.locations ?? [] {
            guard let name = location.name, let slug = location.slug else { continue }
            let dir = (locationsDir as NSString).appendingPathComponent(slug)
            locations.append(Scan.LocationEntry(
                name: name,
                slug: slug,
                description: location.description,
                lightingNotes: location.lightingNotes,
                spatialAnchors: location.spatialAnchors,
                referencePaths: referenceImages(inDirectory: dir)
            ))
        }

        let finalCut = (episodeDir as NSString)
            .appendingPathComponent("episode-\(String(format: "%03d", episodeNumber))-final.mp4")
        let music = (audioDir as NSString).appendingPathComponent("music.mp3")

        return Scan(
            projectPath: root,
            seriesName: series.name ?? projectURL.lastPathComponent,
            concept: series.concept,
            styleBlock: series.aesthetic?.style,
            aspectRatio: series.storyboardAspectRatio ?? "16:9",
            episode: episodeNumber,
            episodeTitle: script.title
                ?? (series.episodes ?? []).first(where: { $0.number == episodeNumber })?.title,
            shots: shots,
            characters: characters,
            locations: locations,
            finalCutPath: fm.fileExists(atPath: finalCut) ? finalCut : nil,
            musicPath: fm.fileExists(atPath: music) ? music : nil
        )
    }
}
