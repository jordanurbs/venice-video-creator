import Foundation

/// Applying a harness project scan to the open document: copy media into the
/// package, register manifest entries, and map the harness script onto the
/// shot plan. One-way — the harness project is never written to.
extension EditorViewModel {

    /// Import a harness project folder into this document. Replaces the shot
    /// plan when none exists or the user confirmed; media lands in a
    /// "Harness/<series>" folder tree in the library.
    func importHarnessProject(from url: URL) {
        let scanResult: HarnessProjectImporter.Scan
        do {
            scanResult = try HarnessProjectImporter.scan(projectURL: url)
        } catch {
            editorToast = MediaPanelToast(message: error.localizedDescription)
            return
        }
        applyHarnessScan(scanResult, refreshing: false)
    }

    /// Re-scan the shot plan's recorded harness source and additively merge:
    /// new clips/panels are imported and attached, new shots appended. Existing
    /// app-side edits (prompts, ordering, takes) are left alone.
    func refreshFromHarness() {
        guard let plan = mediaManifest.shotPlan,
              let sourcePath = plan.harnessSourcePath else {
            editorToast = MediaPanelToast(message: "This project was not imported from a harness project.")
            return
        }
        let url = URL(fileURLWithPath: sourcePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: sourcePath) else {
            editorToast = MediaPanelToast(message: "Harness project not found at \(sourcePath).")
            return
        }
        let scanResult: HarnessProjectImporter.Scan
        do {
            scanResult = try HarnessProjectImporter.scan(projectURL: url, episode: plan.harnessEpisode)
        } catch {
            editorToast = MediaPanelToast(message: error.localizedDescription)
            return
        }
        applyHarnessScan(scanResult, refreshing: true)
    }

    // MARK: - Apply

    private func applyHarnessScan(_ scan: HarnessProjectImporter.Scan, refreshing: Bool) {
        var plan = mediaManifest.shotPlan ?? ShotPlan()
        if !refreshing {
            plan.title = scan.episodeTitle ?? scan.seriesName
            plan.logline = scan.concept
            plan.aspectRatio = scan.aspectRatio
            if let style = scan.styleBlock, !style.isEmpty { plan.styleBlock = style }
        }
        plan.harnessSourcePath = scan.projectPath
        plan.harnessEpisode = scan.episode

        // Library folder tree for imported media.
        let rootFolderId = findOrCreateFolder(named: "Harness — \(scan.seriesName)", parent: nil)
        let shotsFolderId = findOrCreateFolder(named: "Episode \(scan.episode) shots", parent: rootFolderId)
        let castFolderId = findOrCreateFolder(named: "Cast references", parent: rootFolderId)
        let locationsFolderId = findOrCreateFolder(named: "Location references", parent: rootFolderId)

        var importedCount = 0

        // Characters: match by (case-insensitive) name on refresh.
        for entry in scan.characters {
            let existing = plan.characters.first { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            var spec = existing ?? CharacterSpec(name: entry.name)
            if spec.description == nil { spec.description = entry.description }
            for path in entry.referencePaths {
                guard let asset = importHarnessFile(path, folderId: castFolderId, imported: &importedCount) else { continue }
                if !spec.referenceImageAssetIds.contains(asset.id) {
                    spec.referenceImageAssetIds.append(asset.id)
                }
            }
            if let index = plan.characters.firstIndex(where: { $0.id == spec.id }) {
                plan.characters[index] = spec
            } else {
                plan.characters.append(spec)
            }
        }

        // Locations: match by name on refresh.
        var locationIdBySlug: [String: String] = [:]
        for entry in scan.locations {
            let existing = plan.locations.first { $0.name.caseInsensitiveCompare(entry.name) == .orderedSame }
            var spec = existing ?? LocationSpec(name: entry.name)
            if spec.description == nil { spec.description = entry.description }
            if spec.lightingNotes == nil { spec.lightingNotes = entry.lightingNotes }
            if spec.spatialAnchors == nil { spec.spatialAnchors = entry.spatialAnchors }
            for path in entry.referencePaths {
                guard let asset = importHarnessFile(path, folderId: locationsFolderId, imported: &importedCount) else { continue }
                if !spec.referenceImageAssetIds.contains(asset.id) {
                    spec.referenceImageAssetIds.append(asset.id)
                }
            }
            if let index = plan.locations.firstIndex(where: { $0.id == spec.id }) {
                plan.locations[index] = spec
            } else {
                plan.locations.append(spec)
            }
            locationIdBySlug[entry.slug] = spec.id
        }
        let characterIdByName = Dictionary(
            plan.characters.map { ($0.name.uppercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )

        // Shots: keyed by harness slug ("H003" etc.) so refresh is idempotent.
        for entry in scan.shots {
            let slug = "H\(entry.key)"
            let existingIndex = plan.shots.firstIndex { $0.slug == slug }
            var shot = existingIndex.map { plan.shots[$0] } ?? Shot(slug: slug)
            if existingIndex == nil {
                shot.cameraTrajectory = entry.cameraTrajectory
                if entry.cameraTrajectory != nil { shot.modelOverride = entry.renderModel ?? VideoModelCapabilities.multiAngleID }
                shot.summary = entry.summary
                shot.prompt = entry.prompt
                shot.storyboardPrompt = entry.storyboardPrompt
                shot.durationSeconds = entry.durationSeconds
                shot.blocking = entry.blocking
                shot.characterIds = entry.characterNames.compactMap { characterIdByName[$0.uppercased()] }
                shot.locationIds = entry.locationSlug.flatMap { locationIdBySlug[$0] }.map { [$0] } ?? []
                shot.dialogue = entry.dialogue.map { line in
                    ShotDialogue(
                        characterId: characterIdByName[line.speaker.uppercased()],
                        speaker: line.speaker.isEmpty ? nil : line.speaker,
                        text: line.line
                    )
                }
                if let transition = entry.transition?.lowercased(),
                   let mapped = ShotTransition(rawValue: transition) {
                    shot.transition = mapped
                }
            }

            // Attach media (both fresh imports and refresh): panel + clip.
            if shot.storyboardAssetId == nil, let panel = entry.panelPath,
               let asset = importHarnessFile(panel, folderId: shotsFolderId, imported: &importedCount) {
                shot.storyboardAssetId = asset.id
                if shot.status == .planned { shot.status = .storyboarded }
            }
            if shot.videoAssetId == nil, let clip = entry.clipPath,
               let asset = importHarnessFile(clip, folderId: shotsFolderId, imported: &importedCount) {
                shot.videoAssetId = asset.id
                shot.status = .approved
                shot.takes.append(ShotTake(
                    videoAssetId: asset.id,
                    model: entry.renderModel,
                    note: "Imported from harness (\(entry.key))"
                ))
            }

            if let index = existingIndex {
                plan.shots[index] = shot
            } else {
                plan.shots.append(shot)
            }
        }

        // Final cut + music land in the library root folder.
        if let finalCut = scan.finalCutPath {
            _ = importHarnessFile(finalCut, folderId: rootFolderId, imported: &importedCount)
        }
        if let music = scan.musicPath {
            _ = importHarnessFile(music, folderId: rootFolderId, imported: &importedCount)
        }

        saveShotPlan(plan)
        editorToast = MediaPanelToast(
            message: refreshing
                ? "Refreshed from harness: \(importedCount) new file(s)."
                : "Imported \(scan.seriesName) episode \(scan.episode): \(scan.shots.count) shots, \(importedCount) file(s).",
            kind: .success
        )
    }

    // MARK: - Helpers

    private func findOrCreateFolder(named name: String, parent: String?) -> String {
        if let existing = mediaManifest.folders.first(where: { $0.name == name && $0.parentFolderId == parent }) {
            return existing.id
        }
        return createFolder(name: name, in: parent)
    }

    /// Copy one harness file into the package's media directory (skipping when
    /// an identical import already exists) and register it as a media asset.
    /// Returns the existing asset when the file was imported before, so refresh
    /// never duplicates media.
    private func importHarnessFile(_ sourcePath: String, folderId: String?, imported: inout Int) -> MediaAsset? {
        // Dedup key: the harness-absolute source path recorded at import time.
        if let existing = mediaAssets.first(where: { $0.importInput?.sourcePath == sourcePath }) {
            return existing
        }

        let sourceURL = URL(fileURLWithPath: sourcePath)
        guard let type = ClipType(fileExtension: sourceURL.pathExtension.lowercased()) else { return nil }

        // Copy into the package for document integrity; unsaved projects
        // reference the harness file in place until first save.
        var assetURL = sourceURL
        if let projectURL {
            let mediaDir = projectURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
            // Prefix with the harness shot key context to avoid collisions
            // (shot-001.png exists in every episode).
            let filename = "harness-\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).\(sourceURL.pathExtension)"
            let destination = mediaDir.appendingPathComponent(filename)
            do {
                try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destination)
                assetURL = destination
            } catch {
                Log.project.error("harness import copy failed: \(error.localizedDescription)")
                // Fall back to referencing the file where it lives.
                assetURL = sourceURL
            }
        }

        let name = sourceURL.deletingPathExtension().lastPathComponent
        let asset = MediaAsset(url: assetURL, type: type, name: name)
        asset.folderId = folderId
        asset.importInput = MediaImportInput(sourcePath: sourcePath, createdAt: Date())
        importMediaAsset(asset)
        Task { await finalizeImportedAsset(asset) }
        imported += 1
        return asset
    }
}
