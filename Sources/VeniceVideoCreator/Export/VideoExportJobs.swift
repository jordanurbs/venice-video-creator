import Foundation

@MainActor
final class VideoExportJobs {
    weak var editor: EditorViewModel?
    var renderVideo: (@MainActor (Timeline, MediaResolver, ExportFormat, ExportResolution, URL) async throws -> Void)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var services: [String: ExportService] = [:]
    private var detached = false

    func record(_ id: String) throws -> VideoExportJob {
        guard var job = editor?.mediaManifest.videoExportJobs.first(where: { $0.id == id }) else { throw ToolError("Export job not found: \(id).") }
        if job.status == .completed, tasks[id] != nil { job.status = .publishing }
        return job
    }

    func summary(_ id: String) throws -> VideoExportJob.Summary {
        let job = try record(id)
        return .init(job, progress: job.status == .completed ? 1 : min(services[id]?.progress ?? 0, 0.99))
    }

    func start(snapshot: VideoExportSnapshot, format: ExportFormat, resolution: ExportResolution, outputURL: URL,
               overwrite: Bool, service: ExportService = ExportService(), notify: Bool = false) throws -> VideoExportJob {
        guard let editor, !detached else { throw ToolError("The project is closed.") }
        guard format != .xml, format != .fcpxml else { throw ExportError.invalidFormat }
        let urls = snapshot.sourceURLs
        guard !urls.values.contains(where: { ExportFiles.sameFile($0, outputURL) }) else {
            throw ToolError("Choose an export destination that is not a source media file.")
        }
        guard overwrite || !FileManager.default.fileExists(atPath: outputURL.path) else { throw ToolError("The export destination already exists.") }
        let job = VideoExportJob(revision: snapshot.revision, path: outputURL.path, codec: format.displayName,
            resolution: resolution.rawValue, timeline: snapshot.timeline, sourceDigests: snapshot.sourceDigests,
            warnings: snapshot.readiness.issues.filter { $0.severity == .warning }.map(\.message))
        editor.mediaManifest.videoExportJobs.append(job)
        editor.onProjectContentChanged?()
        services[job.id] = service
        service.isExporting = true
        service.error = nil
        service.progress = 0
        tasks[job.id] = Task { await self.run(job, snapshot: snapshot, format: format, resolution: resolution,
                                             outputURL: outputURL, overwrite: overwrite, service: service, notify: notify) }
        return job
    }

    func wait(_ id: String, timeout: Duration? = nil) async throws -> VideoExportJob {
        let deadline = timeout.map { ContinuousClock.now.advanced(by: $0) }
        while true {
            try Task.checkCancellation()
            let job = try record(id)
            if job.status.isTerminal || deadline.map({ ContinuousClock.now >= $0 }) == true { return job }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func cancel(_ id: String) throws {
        guard !(try record(id).status.isTerminal) else { return }
        tasks[id]?.cancel()
        services[id]?.cancel()
    }

    func detachAll() {
        detached = true
        for task in tasks.values { task.cancel() }
        for service in services.values { service.cancel() }
    }

    func restore() {
        detached = false
        for job in editor?.mediaManifest.videoExportJobs ?? [] where !job.status.isTerminal && tasks[job.id] == nil {
            update(job.id, status: .interrupted, error: "Export was interrupted. Start a new export after checking readiness.")
        }
    }

    private func update(_ id: String, status: VideoExportJob.Status, artifact: VideoExportJob.Artifact? = nil, error: String? = nil) {
        guard let editor, let index = editor.mediaManifest.videoExportJobs.firstIndex(where: { $0.id == id }) else { return }
        editor.mediaManifest.videoExportJobs[index].status = status
        editor.mediaManifest.videoExportJobs[index].updatedAt = Date()
        editor.mediaManifest.videoExportJobs[index].error = error
        if let artifact { editor.mediaManifest.videoExportJobs[index].artifact = artifact }
        if !detached { editor.onProjectContentChanged?() }
    }

    private func checkpoint() async throws {
        guard let editor, !detached else { throw CancellationError() }
        if editor.projectURL != nil { try await editor.checkpointProductionState() }
    }

    private func run(_ job: VideoExportJob, snapshot: VideoExportSnapshot, format: ExportFormat, resolution: ExportResolution,
                     outputURL: URL, overwrite: Bool, service: ExportService, notify: Bool) async {
        let directory = outputURL.deletingLastPathComponent().appendingPathComponent(".venice-export-\(job.id)", isDirectory: true)
        let staging = directory.appendingPathComponent("output").appendingPathExtension(format.fileExtension)
        var ownsDirectory = false
        var ownsSlot = false
        var published = false
        var lutPaths: [String] = []
        defer {
            LUTLoader.removeCached(paths: lutPaths)
            if ownsDirectory { try? FileManager.default.removeItem(at: directory) }
            if ownsSlot { ExportCoordinator.endExport() }
            service.isExporting = false
            services[job.id] = nil
            tasks[job.id] = nil
        }
        do {
            try Task.checkCancellation()
            try await checkpoint()
            service.isWaitingForSlot = ExportCoordinator.isExportActive
            defer { service.isWaitingForSlot = false }
            try await ExportCoordinator.acquireExport()
            ownsSlot = true
            service.isWaitingForSlot = false
            try Task.checkCancellation()
            update(job.id, status: .preparing)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            ownsDirectory = true
            let copies = try await ExportFiles.copySources(snapshot.sourceURLs, digests: snapshot.sourceDigests, into: directory)
            lutPaths = copies.filter { $0.key.hasPrefix("lut:") }.map { $0.value.path }
            let renderTimeline = try ExportFiles.bindingCopiedLUTs(in: snapshot.timeline, copies: copies)
            let resolver = MediaResolver(manifest: { snapshot.manifest }, projectURL: { nil }, frozenURLs: copies)
            try Task.checkCancellation()
            update(job.id, status: .rendering)
            try await checkpoint()
            if let renderVideo {
                try await renderVideo(renderTimeline, resolver, format, resolution, staging)
            } else {
                await service.export(timeline: renderTimeline, resolver: resolver, format: format,
                                     resolution: resolution, outputURL: staging, acquireSlot: false)
                if let error = service.error { throw ExportError.verification(error) }
            }
            service.isExporting = true
            try Task.checkCancellation()
            update(job.id, status: .verifying)
            let size = resolution.renderSize(for: CGSize(width: snapshot.timeline.width, height: snapshot.timeline.height))
            let artifact = try await ExportArtifactVerifier.verify(staging, timeline: snapshot.timeline, size: size, format: format)
            guard try await ExportFiles.digests(snapshot.sourceURLs) == snapshot.sourceDigests else {
                throw ExportError.verification("Source media changed during export. Check readiness and export again.")
            }
            update(job.id, status: .publishing, artifact: artifact)
            try await checkpoint()
            try Task.checkCancellation()
            try ExportFiles.publish(staging, to: outputURL, overwrite: overwrite)
            published = true
            update(job.id, status: .completed)
            try await checkpoint()
            service.progress = 1
            if notify { AppNotifications.exportComplete(name: outputURL.lastPathComponent, outputURL: outputURL, size: size, warningCount: job.warnings.count) }
        } catch {
            let cancelled = !published && (Task.isCancelled || error is CancellationError)
            let message = published ? "Output was published, but the completion record could not be saved: \(error.localizedDescription)"
                : cancelled ? "Export cancelled" : error.localizedDescription
            update(job.id, status: cancelled ? .cancelled : .failed, error: message)
            service.error = message
            try? await checkpoint()
            if notify && !cancelled { AppNotifications.exportFailed(name: outputURL.lastPathComponent, reason: message) }
        }
    }
}
