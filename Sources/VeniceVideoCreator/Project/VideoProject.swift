import AppKit
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct ProjectPackageContents: Sendable {
    var timeline: Timeline
    var manifest: MediaManifest?
    var generationLog: GenerationLog?
    var manifestUnreadable: Bool = false
}

struct ProjectPackageSnapshot: Sendable {
    var timeline: Data
    var manifest: Data?
    var generationLog: Data?
    var thumbnail: Data?
    var chatSessionFiles: [(name: String, data: Data)]
}

private struct RestoredMediaCandidate: Sendable {
    let id: String
    let name: String
    let url: URL
}

final class VideoProject: NSDocument {

    static let typeIdentifier = Project.typeIdentifier

    let editorViewModel = EditorViewModel()

    /// Decoded off-main in read(), applied on main in makeWindowControllers.
    private nonisolated(unsafe) var loadedTimeline: Timeline?
    private nonisolated(unsafe) var loadedManifest: MediaManifest?
    private nonisolated(unsafe) var loadedGenerationLog: GenerationLog?

    /// Set when media.json existed but failed to decode, so saves preserve it instead of clobbering.
    private nonisolated(unsafe) var manifestLoadFailed = false

    /// Captured on main thread before writes may continue off-main.
    private nonisolated(unsafe) var snapshotTimeline: Data?
    private nonisolated(unsafe) var snapshotManifest: Data?
    private nonisolated(unsafe) var snapshotGenerationLog: Data?
    private nonisolated(unsafe) var snapshotThumbnail: Data?
    private nonisolated(unsafe) var snapshotChatSessionFiles: [(name: String, data: Data)] = []
    private nonisolated(unsafe) var snapshotSourceProjectURL: URL?
    private nonisolated(unsafe) var snapshotPreparedForWrite = false
    /// False until this document has read or written its package. A new document
    /// saved over an existing package must not inherit that package's media.
    private nonisolated(unsafe) var ownsPackageOnDisk = false
    private var projectCheckpointAutosaveScheduled = false
    // Old projects predate the persistent log; seed it only after async media restore
    // has populated mediaAssets, and only when no real log was loaded.
    private var needsGenerationLogSeed = false
    private var isClosed = false
    // One alert per failure streak; resets when a checkpoint succeeds.
    private var checkpointFailureAlerted = false

    // MARK: - Persistence

    override class var autosavesInPlace: Bool { true }

    @MainActor
    static func load(from url: URL) async throws -> VideoProject {
        let contents = try await Task.detached(priority: .userInitiated) {
            try readProjectPackage(at: url)
        }.value
        let doc = VideoProject()
        doc.fileURL = url
        doc.fileType = typeIdentifier
        doc.applyLoadedContents(contents)
        return doc
    }

    override func read(from url: URL, ofType typeName: String) throws {
        applyLoadedContents(try Self.readProjectPackage(at: url))
    }

    private nonisolated func applyLoadedContents(_ contents: ProjectPackageContents) {
        ownsPackageOnDisk = true
        loadedTimeline = contents.timeline
        loadedManifest = contents.manifest
        loadedGenerationLog = contents.generationLog
        manifestLoadFailed = contents.manifestUnreadable
        Log.project.notice(
            "read ok tracks=\(self.loadedTimeline?.tracks.count ?? 0)",
            telemetry: "Project read",
            data: [
                "tracks": loadedTimeline?.tracks.count ?? 0,
                "clips": loadedTimeline?.tracks.reduce(0) { $0 + $1.clips.count } ?? 0,
                "media": loadedManifest?.entries.count ?? 0,
                "hasGenerationLog": loadedGenerationLog != nil
            ]
        )
    }

    nonisolated static func readProjectPackage(at url: URL) throws -> ProjectPackageContents {
        let data = try requiredData(Project.timelineFilename, in: url)
        let timeline: Timeline
        do {
            timeline = try JSONDecoder().decode(Timeline.self, from: data)
        } catch {
            Log.project.error("read: timeline decode failed: \(String(describing: error))")
            throw error
        }

        let manifest: MediaManifest?
        let manifestUnreadable: Bool
        if let manifestData = try optionalData(Project.manifestFilename, in: url) {
            if let decoded = try? JSONDecoder().decode(MediaManifest.self, from: manifestData) {
                manifest = decoded
                manifestUnreadable = false
            } else {
                // A bad manifest must not lose the project; degrade to "media offline" and keep the file for recovery.
                Log.project.error("read manifest decode failed bytes=\(manifestData.count); opening with empty manifest")
                manifest = nil
                manifestUnreadable = true
            }
        } else {
            manifest = nil
            manifestUnreadable = false
        }

        let generationLog = try optionalData(Project.generationLogFilename, in: url)
            .flatMap { try? JSONDecoder().decode(GenerationLog.self, from: $0) }

        return ProjectPackageContents(
            timeline: timeline,
            manifest: manifest,
            generationLog: generationLog,
            manifestUnreadable: manifestUnreadable
        )
    }

    override func save(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType, completionHandler: @escaping (Error?) -> Void) {
        if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
            fileModificationDate = date
        }

        captureSaveSnapshot()
        snapshotSourceProjectURL = ownsPackageOnDisk ? fileURL : nil
        super.save(to: url, ofType: typeName, for: saveOperation, completionHandler: completionHandler)
    }

    override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        true
    }

    override func write(to url: URL, ofType typeName: String) throws {
        if !snapshotPreparedForWrite {
            guard Thread.isMainThread else {
                Log.project.error("save: snapshot not prepared for off-main write()")
                throw CocoaError(.fileWriteUnknown)
            }
            MainActor.assumeIsolated {
                captureSaveSnapshot()
                snapshotSourceProjectURL = ownsPackageOnDisk ? fileURL : nil
            }
        }
        defer {
            snapshotPreparedForWrite = false
            snapshotSourceProjectURL = nil
        }
        guard let data = snapshotTimeline else {
            Log.project.error("save: snapshotTimeline missing at write()")
            throw CocoaError(.fileWriteUnknown)
        }
        // Snapshot captured — the UI may resume while the package writes.
        unblockUserInteraction()

        try Self.writeProjectPackage(
            ProjectPackageSnapshot(
                timeline: data,
                manifest: snapshotManifest,
                generationLog: snapshotGenerationLog,
                thumbnail: snapshotThumbnail,
                chatSessionFiles: snapshotChatSessionFiles
            ),
            to: url,
            sourceURL: snapshotSourceProjectURL
        )
        // A real manifest was just written, so the unreadable original is gone; stop preserving it.
        if snapshotManifest != nil { manifestLoadFailed = false }
        ownsPackageOnDisk = true
    }

    private func captureSaveSnapshot() {
        snapshotTimeline = try? JSONEncoder().encode(editorViewModel.timeline)
        snapshotManifest = Self.manifestSnapshotData(manifest: editorViewModel.mediaManifest, loadFailed: manifestLoadFailed)
        snapshotGenerationLog = try? JSONEncoder().encode(editorViewModel.generationLog)
        snapshotThumbnail = captureThumbnail()
        snapshotChatSessionFiles = editorViewModel.agentService.sessions
            .filter { !$0.messages.isEmpty }
            .compactMap { session in
                ChatSessionStore.encodeSession(session).map { (name: "\(session.id.uuidString).json", data: $0) }
            }
        snapshotPreparedForWrite = true
    }

    nonisolated static func manifestSnapshotData(manifest: MediaManifest, loadFailed: Bool) -> Data? {
        // If the manifest failed to load, don't overwrite the (recoverable) original with an empty one.
        if loadFailed && manifest.entries.isEmpty && manifest.folders.isEmpty { return nil }
        return try? JSONEncoder().encode(manifest)
    }

    private nonisolated static func requiredData(_ name: String, in packageURL: URL) throws -> Data {
        do {
            return try Data(contentsOf: packageURL.appendingPathComponent(name, isDirectory: false), options: [.mappedIfSafe])
        } catch {
            Log.project.error("read: missing \(name) in package")
            throw CocoaError(.fileReadCorruptFile)
        }
    }

    private nonisolated static func optionalData(_ name: String, in packageURL: URL) throws -> Data? {
        let url = packageURL.appendingPathComponent(name, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    nonisolated static func writeProjectPackage(_ snapshot: ProjectPackageSnapshot, to packageURL: URL, sourceURL: URL?) throws {
        let fm = FileManager.default
        try createPackageDirectory(at: packageURL, fm: fm)
        try snapshot.timeline.write(to: packageURL.appendingPathComponent(Project.timelineFilename), options: .atomic)
        if let manifest = snapshot.manifest {
            try manifest.write(to: packageURL.appendingPathComponent(Project.manifestFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.manifestFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        if let log = snapshot.generationLog {
            try log.write(to: packageURL.appendingPathComponent(Project.generationLogFilename), options: .atomic)
        }
        if let thumbnail = snapshot.thumbnail {
            try thumbnail.write(to: packageURL.appendingPathComponent(Project.thumbnailFilename), options: .atomic)
        } else {
            try copyPreservedFile(Project.thumbnailFilename, from: sourceURL, to: packageURL, fm: fm)
        }
        try writeChatDirectory(snapshot.chatSessionFiles, to: packageURL, fm: fm)
        try copyMediaDirectoryIfNeeded(from: sourceURL, to: packageURL, fm: fm)
    }

    private nonisolated static func createPackageDirectory(at url: URL, fm: FileManager) throws {
        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue { return }
            try fm.removeItem(at: url)
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private nonisolated static func writeChatDirectory(_ files: [(name: String, data: Data)], to packageURL: URL, fm: FileManager) throws {
        let chatURL = packageURL.appendingPathComponent(ChatSessionStore.dirName, isDirectory: true)
        if fm.fileExists(atPath: chatURL.path) {
            try fm.removeItem(at: chatURL)
        }
        try fm.createDirectory(at: chatURL, withIntermediateDirectories: true)
        for file in files {
            try file.data.write(to: chatURL.appendingPathComponent(file.name, isDirectory: false), options: .atomic)
        }
    }

    private nonisolated static func copyPreservedFile(_ name: String, from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(name, isDirectory: false)
        guard fm.fileExists(atPath: source.path) else { return }
        let destination = packageURL.appendingPathComponent(name, isDirectory: false)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func copyMediaDirectoryIfNeeded(from sourceURL: URL?, to packageURL: URL, fm: FileManager) throws {
        guard let sourceURL, !sameFile(sourceURL, packageURL) else { return }
        let source = sourceURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        let destination = packageURL.appendingPathComponent(Project.mediaDirectoryName, isDirectory: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        guard fm.fileExists(atPath: source.path) else { return }
        try fm.copyItem(at: source, to: destination)
    }

    private nonisolated static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        editorViewModel.isDocumentEdited = isDocumentEdited
    }

    override func updateChangeCount(withToken changeCountToken: Any, for saveOperation: NSDocument.SaveOperationType) {
        super.updateChangeCount(withToken: changeCountToken, for: saveOperation)
        editorViewModel.isDocumentEdited = isDocumentEdited
    }

    private func scheduleProjectCheckpointAutosave() {
        guard fileURL != nil, !isClosed, !projectCheckpointAutosaveScheduled else { return }
        projectCheckpointAutosaveScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.projectCheckpointAutosaveScheduled = false
            guard self.fileURL != nil, !self.isClosed else { return }
            self.autosave(withImplicitCancellability: false) { error in
                guard let error else {
                    self.checkpointFailureAlerted = false
                    return
                }
                Log.project.error("project checkpoint autosave failed: \(error.localizedDescription)")
                guard !self.checkpointFailureAlerted, !self.isClosed else { return }
                self.checkpointFailureAlerted = true
                let alert = NSAlert()
                alert.messageText = "Autosave failed."
                alert.informativeText = "\(error.localizedDescription)\n\nChanges since the last successful save are at risk. Check disk space and permissions."
                alert.addButton(withTitle: "OK")
                if let window = self.windowControllers.first?.window, window.isVisible {
                    alert.beginSheetModal(for: window)
                } else {
                    alert.runModal()
                }
            }
        }
    }

    override var displayName: String! {
        get { fileURL?.deletingPathExtension().lastPathComponent ?? Project.defaultProjectName }
        set { super.displayName = newValue }
    }

    override var fileURL: URL? {
        get { super.fileURL }
        set {
            let oldURL = super.fileURL
            super.fileURL = newValue
            if let oldURL, let newURL = newValue,
               oldURL.standardizedFileURL != newURL.standardizedFileURL {
                MainActor.assumeIsolated {
                    ProjectRegistry.shared.updateURL(from: oldURL, to: newURL)
                    // Save As must rebind the editor or generations keep
                    // writing into the old package.
                    editorViewModel.projectURL = newURL
                }
            }
        }
    }

    // MARK: - Close

    override func close() {
        super.close()
        // A generation finishing after close must not autosave this zombie document
        // over a reopened copy. Jobs keep running server-side; reopen resumes them.
        isClosed = true
        editorViewModel.generationService.detachAll()
        editorViewModel.onProjectCheckpointRequired = nil
        editorViewModel.onProjectContentChanged = nil
        editorViewModel.agentService.onSessionsChanged = nil
        let searchIndex = editorViewModel.searchIndex
        Task { await searchIndex.cancelIndexing() }
        DispatchQueue.main.async {
            if AppState.shared.activeProject === self {
                AppState.shared.showHome()
            }
        }
    }

    // MARK: - Window setup

    override func makeWindowControllers() {
        if let loaded = loadedTimeline {
            editorViewModel.timeline = loaded
            loadedTimeline = nil
        }
        editorViewModel.undoManager = undoManager
        editorViewModel.projectURL = fileURL
        editorViewModel.agentService.loadSessions(from: fileURL)
        editorViewModel.agentService.onSessionsChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }
        editorViewModel.onProjectContentChanged = { [weak self] in
            self?.updateChangeCount(.changeDone)
        }
        editorViewModel.onProjectCheckpointRequired = { [weak self] in
            self?.scheduleProjectCheckpointAutosave()
        }

        if let manifest = loadedManifest {
            editorViewModel.mediaManifest = manifest
            loadedManifest = nil
            restoreAssetsFromManifest()
        }

        let editorView = EditorView()
            .environment(editorViewModel)
            .focusEffectDisabled()
            .sheet(isPresented: Bindable(editorViewModel).showExportDialog) { [editorViewModel] in
                ExportView()
                    .environment(editorViewModel)
            }
            .sheet(item: Bindable(editorViewModel).pendingSettingsMismatch, onDismiss: { [editorViewModel] in
                // Esc-dismissal must drop the pending operation, not leak it.
                editorViewModel.pendingSettingsContinuation = nil
            }) { [editorViewModel] mismatch in
                ProjectSettingsMismatchView(mismatch: mismatch)
                    .environment(editorViewModel)
            }
            .overlay(alignment: .bottom) {
                EditorToastOverlay()
                    .environment(editorViewModel)
            }
            .overlay {
                TourOverlay()
                    .environment(editorViewModel)
            }
        let hostingController = NSHostingController(rootView: editorView.tint(AppTheme.Accent.primary))
        hostingController.sizingOptions = .minSize

        let window = NSWindow(contentViewController: hostingController)
        window.minSize = AppTheme.Window.projectMin
        window.appearance = NSAppearance(named: .darkAqua)
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(AppTheme.Background.surfaceColor)
        window.fillVisibleScreen()

        window.addTitlebarSwiftUI(TitleBarLeadingView().environment(editorViewModel), side: .leading, width: AppTheme.IconSize.lg + AppTheme.Spacing.sm)
        window.addTitlebarSwiftUI(TitleBarTrailingView().environment(editorViewModel), side: .trailing, width: AppTheme.Window.projectTitlebarTrailingWidth)

        let controller = EditorWindowController(editorViewModel: editorViewModel, window: window)
        controller.installKeyMonitor()
        addWindowController(controller)

        window.standardWindowButton(.documentIconButton)?.isHidden = true

        AppState.shared.showEditor(for: self)

        if manifestLoadFailed {
            let alert = NSAlert()
            alert.messageText = "The media list couldn't be read."
            alert.informativeText = "The project opened without its media library. The original \(Project.manifestFilename) is preserved inside the package for recovery — saving won't overwrite it."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
        }

        if let log = loadedGenerationLog {
            editorViewModel.generationLog = log
            loadedGenerationLog = nil
        } else {
            needsGenerationLogSeed = true
        }
        editorViewModel.searchIndex.projectOpened()
        editorViewModel.updateTelemetryContext()
        Telemetry.breadcrumb(
            "Project opened",
            category: "project",
            data: editorViewModel.telemetrySnapshot()
        )
    }

    /// Presenting the editor must activate the app and make the window key.
    /// Otherwise SwiftUI's AppKit-backed selectable text (`.textSelection`) in the
    /// agent panel renders blank until the first click makes the window key.
    override func showWindows() {
        super.showWindows()
        NSApp.activate(ignoringOtherApps: true)
        windowControllers.first?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Thumbnail

    private var cachedThumbnail: Data?
    private var thumbnailInFlight = false
    private nonisolated static let thumbnailMaxPixelSize = 640

    private func captureThumbnail() -> Data? {
        if let cached = cachedThumbnail { return cached }
        guard !thumbnailInFlight else { return nil }
        thumbnailInFlight = true
        Task { [weak self] in
            await self?.generateThumbnail()
        }
        return nil
    }

    /// Picks the first usable video-track clip and generates a jpeg
    private func generateThumbnail() async {
        defer { thumbnailInFlight = false }

        struct Candidate { let url: URL; let isVideo: Bool; let trimStartFrame: Int }
        var candidates: [Candidate] = []
        for track in editorViewModel.timeline.tracks where track.type == .video {
            for clip in track.clips {
                guard clip.mediaType == .image || clip.mediaType == .video,
                      let url = editorViewModel.mediaResolver.expectedURL(for: clip.mediaRef) else { continue }
                candidates.append(Candidate(
                    url: url,
                    isVideo: clip.mediaType == .video,
                    trimStartFrame: clip.trimStartFrame
                ))
            }
        }
        let fps = editorViewModel.timeline.fps
        guard !candidates.isEmpty else { return }

        let maxPixelSize = Self.thumbnailMaxPixelSize
        let data: Data? = await Task.detached(priority: .utility) {
            for candidate in candidates {
                if candidate.isVideo {
                    // Async `loadTracks` / `image(at:)` — no blocking semaphore wait.
                    let asset = AVURLAsset(url: candidate.url)
                    guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { continue }
                    let generator = AVAssetImageGenerator(asset: asset)
                    // Aspect-preserving box; frame is ~640px on the long edge.
                    generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
                    generator.appliesPreferredTrackTransform = true
                    let time = CMTime(value: CMTimeValue(candidate.trimStartFrame), timescale: CMTimeScale(max(fps, 1)))
                    guard let cgImage = try? await generator.image(at: time).image else { continue }
                    return NSBitmapImageRep(cgImage: cgImage).representation(using: .jpeg, properties: [.compressionFactor: 0.7])
                } else if let image = ImageEncoder.thumbnail(url: candidate.url, maxPixelSize: maxPixelSize),
                          let data = ImageEncoder.encodeJPEG(image, quality: 0.7) {
                    return data
                }
            }
            return nil
        }.value

        guard let data else { return }
        cachedThumbnail = data
        guard let packageURL = fileURL else { return }
        let thumbURL = packageURL.appendingPathComponent(Project.thumbnailFilename, isDirectory: false)
        try? await Task.detached(priority: .utility) {
            try data.write(to: thumbURL, options: .atomic)
        }.value
    }

    // MARK: - Media restore

    private func restoreAssetsFromManifest() {
        let projectURL = editorViewModel.projectURL
        let entries = editorViewModel.mediaManifest.entries
        Task { @MainActor [weak self] in
            // Per-entry disk checks; large projects stat hundreds of files — off main.
            let pairs: [(String, URL?)] = await Task.detached(priority: .userInitiated) {
                entries.map { entry in
                    (entry.id,
                     MediaResolver.existingURL(for: entry, projectURL: projectURL)
                        ?? MediaResolver.expectedURL(for: entry, projectURL: projectURL))
                }
            }.value
            self?.applyManifestRestore(resolvedByEntryId: Dictionary(pairs, uniquingKeysWith: { first, _ in first }))
        }
    }

    private func applyManifestRestore(resolvedByEntryId: [String: URL?]) {
        let projectURL = editorViewModel.projectURL
        var missing = 0
        var missingRefs: Set<String> = []
        var candidates: [RestoredMediaCandidate] = []
        var healed = false
        for (index, entry) in editorViewModel.mediaManifest.entries.enumerated() {
            // Entries imported after open began are already live; only restore
            // what existed when the resolution snapshot was taken.
            guard let resolution = resolvedByEntryId[entry.id] else { continue }
            guard let url = resolution else {
                Log.project.warning("restore: could not resolve URL for entry id=\(entry.id) name=\(entry.name)")
                missing += 1
                missingRefs.insert(entry.id)
                continue
            }
            let asset = MediaAsset(entry: entry, resolvedURL: url)
            editorViewModel.mediaAssets.append(asset)
            candidates.append(RestoredMediaCandidate(id: entry.id, name: entry.name, url: url))
            // Persist the repaired path so the fix survives without manual relink.
            let repairedSource = MediaSource.make(for: url, projectURL: projectURL)
            if repairedSource != entry.source {
                editorViewModel.mediaManifest.entries[index].source = repairedSource
                healed = true
            }
        }
        editorViewModel.missingMediaRefs = missingRefs
        if healed {
            Log.project.notice("restore: healed stale media paths; marking project for autosave")
            updateChangeCount(.changeDone)
        }
        if needsGenerationLogSeed {
            needsGenerationLogSeed = false
            editorViewModel.seedGenerationLogFromAssets()
        }

        let restoreCandidates = candidates
        let initialMissingRefs = missingRefs
        let initialMissingCount = missing
        let manifestEntries = editorViewModel.mediaManifest.entries.count
        Task { [weak self] in
            let existingRefs = await Task.detached(priority: .utility) {
                Self.existingMediaRefs(restoreCandidates)
            }.value
            self?.finishRestoredMediaScan(
                candidates: restoreCandidates,
                existingRefs: existingRefs,
                initialMissingRefs: initialMissingRefs,
                initialMissingCount: initialMissingCount,
                manifestEntries: manifestEntries
            )
        }
    }

    private nonisolated static func existingMediaRefs(_ candidates: [RestoredMediaCandidate]) -> Set<String> {
        Set(candidates.compactMap { candidate in
            FileManager.default.fileExists(atPath: candidate.url.path) ? candidate.id : nil
        })
    }

    private func finishRestoredMediaScan(
        candidates: [RestoredMediaCandidate],
        existingRefs: Set<String>,
        initialMissingRefs: Set<String>,
        initialMissingCount: Int,
        manifestEntries: Int
    ) {
        let cache = editorViewModel.mediaVisualCache
        var assetsByID: [String: MediaAsset] = [:]
        for asset in editorViewModel.mediaAssets {
            assetsByID[asset.id] = asset
        }
        var restored = 0
        var missing = initialMissingCount
        var missingRefs = initialMissingRefs

        for candidate in candidates {
            guard let asset = assetsByID[candidate.id] else { continue }
            guard existingRefs.contains(candidate.id) else {
                if asset.importInput != nil {
                    switch asset.generationStatus {
                    case .failed:
                        break
                    default:
                        asset.generationStatus = .failed("Import interrupted")
                        editorViewModel.updateManifestMetadata(for: asset)
                    }
                    continue
                }
                if asset.isRecoveringGeneration {
                    asset.generationStatus = .generating
                    editorViewModel.updateManifestMetadata(for: asset)
                    continue
                }
                if asset.isGenerated {
                    if case .failed = asset.generationStatus { continue }
                    if asset.generationStatus == .cancelled { continue }
                    if asset.isGenerating {
                        asset.generationStatus = .failed("Generation interrupted. Rerun to generate again.")
                        editorViewModel.updateManifestMetadata(for: asset)
                        continue
                    }
                }
                Log.project.warning("restore: media file missing id=\(candidate.id) name=\(candidate.name) path=\(candidate.url.path)")
                missing += 1
                missingRefs.insert(candidate.id)
                continue
            }
            if asset.importInput != nil {
                if case .failed = asset.generationStatus {
                    continue
                }
                asset.importInput = nil
                asset.generationStatus = .none
                editorViewModel.updateManifestMetadata(for: asset)
            }
            if asset.generationStatus != .none, !asset.canResumeGeneration {
                asset.generationStatus = .none
                editorViewModel.updateManifestMetadata(for: asset)
            }
            restored += 1
            if asset.type == .audio || asset.type == .video {
                cache.generateWaveform(for: asset)
            }
            if asset.type == .video {
                cache.generateVideoThumbnails(for: asset)
            }
            if asset.type == .image {
                cache.generateImageThumbnail(for: asset)
            }
            Task { await asset.loadMetadata() }
        }

        editorViewModel.missingMediaRefs = missingRefs
        editorViewModel.generationService.resumePendingGenerations(editor: editorViewModel)
        Log.project.notice(
            "restore ok restored=\(restored) missing=\(missing)",
            telemetry: "Media restored",
            data: ["restored": restored, "missing": missing, "manifestEntries": manifestEntries]
        )
    }
}

// MARK: - NSWindow helper

extension NSWindow {
    func fillVisibleScreen(using screen: NSScreen? = nil) {
        let target = screen ?? self.screen ?? NSScreen.main
        guard let frame = target?.visibleFrame else { return }
        setFrame(frame, display: true)
    }

    func addTitlebarSwiftUI<V: View>(_ view: V, side: NSLayoutConstraint.Attribute, width: CGFloat) {
        let host = NSHostingController(rootView: view.tint(AppTheme.Accent.primary))
        host.view.translatesAutoresizingMaskIntoConstraints = false

        let wrapper = CornerAdaptiveView()
        wrapper.frame = NSRect(x: 0, y: 0, width: width, height: 28)
        wrapper.addSubview(host.view)

        let safeArea = wrapper.layoutGuide(for: .safeArea(cornerAdaptation: .horizontal))
        var constraints = [
            host.view.topAnchor.constraint(equalTo: wrapper.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
        ]
        if side == .leading {
            constraints.append(contentsOf: [
                host.view.leadingAnchor.constraint(equalTo: safeArea.leadingAnchor),
                host.view.trailingAnchor.constraint(lessThanOrEqualTo: wrapper.trailingAnchor),
            ])
        } else {
            constraints.append(contentsOf: [
                host.view.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: safeArea.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate(constraints)

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = wrapper
        accessory.layoutAttribute = side
        addTitlebarAccessoryViewController(accessory)
    }
}

private class CornerAdaptiveView: NSView {
    override class var requiresConstraintBasedLayout: Bool { true }
}
