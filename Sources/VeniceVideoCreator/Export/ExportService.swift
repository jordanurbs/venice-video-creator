import AVFoundation
import AppKit
import CoreImage

enum ExportError: LocalizedError {
    case unsupportedPreset
    case invalidFormat
    case xmlEncodingFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPreset: "Export preset not supported on this system"
        case .invalidFormat: "Invalid export format"
        case .xmlEncodingFailed: "Couldn't encode the timeline as XML"
        }
    }
}

struct ExportRunReport {
    let outputSize: CGSize
    let offlineMediaRefs: Set<String>
    let unprocessableMediaRefs: Set<String>
}

@Observable
@MainActor
final class ExportService {
    var progress: Double = 0
    var isExporting = false
    var isWaitingForSlot = false
    var error: String?
    var lastReport: ExportRunReport?

    private var cancelCurrent: (() -> Void)?
    private var activeExportSession: AVAssetExportSession?

    func cancel() {
        // Task cancellation alone doesn't interrupt AVAssetExportSession's async
        // render, so abort the session explicitly too; both paths trip the
        // cancellation cleanup that discards the partial output file.
        activeExportSession?.cancelExport()
        cancelCurrent?()
    }

    /// Waits for the coordinator slot, surfacing the wait instead of a fake 0% bar.
    /// Returns false when cancelled while waiting (no slot acquired). Cancellation is
    /// driven by the enclosing export task, so the slot wait interrupts cleanly.
    private func waitForExportSlot() async -> Bool {
        if ExportCoordinator.isExportActive { isWaitingForSlot = true }
        defer { isWaitingForSlot = false }
        do {
            try await ExportCoordinator.acquireExport()
            return true
        } catch {
            self.error = "Export cancelled"
            return false
        }
    }

    func export(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        fcpxmlVersion: FCPXMLVersion = .default,
        fcpxmlTarget: FCPXMLTarget = .default,
        missingMediaRefs: Set<String> = [],
        outputURL: URL,
        acquireSlot: Bool = true
    ) async {
        // One task drives every phase — slot wait, composition build, render — so Cancel
        // works throughout, not only during the render (build is the visibly slow part).
        let task = Task {
            await self.performExport(
                timeline: timeline, resolver: resolver, format: format, resolution: resolution,
                fcpxmlVersion: fcpxmlVersion, fcpxmlTarget: fcpxmlTarget,
                missingMediaRefs: missingMediaRefs, outputURL: outputURL, acquireSlot: acquireSlot
            )
        }
        cancelCurrent = { task.cancel() }
        defer { cancelCurrent = nil }
        await task.value
    }

    private func performExport(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        fcpxmlVersion: FCPXMLVersion,
        fcpxmlTarget: FCPXMLTarget,
        missingMediaRefs: Set<String>,
        outputURL: URL,
        acquireSlot: Bool
    ) async {
        error = nil
        lastReport = nil
        isExporting = true
        progress = 0
        defer { isExporting = false }

        if format == .xml || format == .fcpxml {
            let name = format.fileExtension
            Log.export.notice(
                "export requested format=\(name)",
                telemetry: "Export started",
                data: ["format": name, "tracks": timeline.tracks.count, "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count }]
            )
            do {
                if format == .xml {
                    try await XMLExporter.export(timeline: timeline, resolver: resolver, outputURL: outputURL)
                } else {
                    try await FCPXMLExporter.export(timeline: timeline, resolver: resolver, version: fcpxmlVersion,
                                                    target: fcpxmlTarget, outputURL: outputURL)
                }
                progress = 1.0
                Log.export.notice("export ok format=\(name)", telemetry: "Export finished", data: ["format": name])
            } catch is CancellationError {
                self.error = "Export cancelled"
                Log.export.notice("export cancelled format=\(name)", telemetry: "Export cancelled", data: ["format": name])
            } catch {
                self.error = error.localizedDescription
                Log.export.error(
                    "export failed format=\(name): \(Log.detail(error))",
                    telemetry: "Export failed",
                    data: ["format": name, "error": Log.detail(error)]
                )
            }
            return
        }
        if acquireSlot, !(await waitForExportSlot()) { return }
        defer { if acquireSlot { ExportCoordinator.endExport() } }

        if format.isHDR {
            await exportHDR(timeline: timeline, resolver: resolver, resolution: resolution,
                            missingMediaRefs: missingMediaRefs, outputURL: outputURL)
            return
        }

        Log.export.notice(
            "export requested format=\(String(describing: format)) resolution=\(resolution.rawValue)",
            telemetry: "Export started",
            data: [
                "format": String(describing: format),
                "resolution": resolution.rawValue,
                "tracks": timeline.tracks.count,
                "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                "totalFrames": timeline.totalFrames,
                "fps": timeline.fps
            ]
        )

        do {
            let prepared = try await makeExportSession(
                timeline: timeline, resolver: resolver,
                format: format, resolution: resolution,
                missingMediaRefs: missingMediaRefs
            )
            let session = prepared.session
            guard let fileType = format.utType else { throw ExportError.invalidFormat }

            // AVAssetExportSession fails if the file already exists
            try? FileManager.default.removeItem(at: outputURL)

            activeExportSession = session
            defer { activeExportSession = nil }

            nonisolated(unsafe) let unsafeSession = session
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    let p = Double(unsafeSession.progress)
                    if p != self.progress { self.progress = p }
                }
            }
            defer { progressTask.cancel() }

            do {
                try await unsafeSession.export(to: outputURL, as: fileType)
                let outputSize = await Self.encodedVideoSize(of: outputURL) ?? prepared.renderSize
                lastReport = ExportRunReport(
                    outputSize: outputSize,
                    offlineMediaRefs: prepared.result.offlineMediaRefs,
                    unprocessableMediaRefs: prepared.result.unprocessableMediaRefs
                )
                progress = 1.0
                Log.export.notice(
                    "export ok",
                    telemetry: "Export finished",
                    data: ["format": String(describing: format), "resolution": resolution.rawValue]
                )
            } catch {
                if Task.isCancelled || error is CancellationError
                    || ((error as NSError).domain == NSCocoaErrorDomain && (error as NSError).code == NSUserCancelledError) {
                    try? FileManager.default.removeItem(at: outputURL)
                    self.error = "Export cancelled"
                    Log.export.notice(
                        "export cancelled",
                        telemetry: "Export cancelled",
                        data: ["format": String(describing: format), "resolution": resolution.rawValue]
                    )
                } else {
                    self.error = error.localizedDescription
                    Log.export.error(
                        "export failed: \(Log.detail(error))",
                        telemetry: "Export failed",
                        data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
                    )
                }
            }
        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            self.error = "Export cancelled"
            Log.export.notice(
                "export cancelled during setup",
                telemetry: "Export cancelled",
                data: ["format": String(describing: format), "resolution": resolution.rawValue]
            )
        } catch {
            self.error = error.localizedDescription
            Log.export.error(
                "export setup failed: \(Log.detail(error))",
                telemetry: "Export setup failed",
                data: ["format": String(describing: format), "resolution": resolution.rawValue, "error": Log.detail(error)]
            )
        }

    }

    /// Writes a self-contained `.palmier` bundle (all media collected internally).
    @discardableResult
    func exportVeniceProject(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        acquireSlot: Bool = true
    ) async -> VeniceProjectExporter.Report? {
        let task = Task {
            await self.performVeniceProjectExport(
                timeline: timeline, manifest: manifest, generationLog: generationLog,
                sourceProjectURL: sourceProjectURL, outputURL: outputURL, acquireSlot: acquireSlot
            )
        }
        cancelCurrent = { task.cancel() }
        defer { cancelCurrent = nil }
        return await task.value
    }

    private func performVeniceProjectExport(
        timeline: Timeline,
        manifest: MediaManifest,
        generationLog: GenerationLog,
        sourceProjectURL: URL?,
        outputURL: URL,
        acquireSlot: Bool
    ) async -> VeniceProjectExporter.Report? {
        isExporting = true
        progress = 0
        error = nil
        lastReport = nil
        defer { isExporting = false }

        if acquireSlot, !(await waitForExportSlot()) { return nil }
        defer { if acquireSlot { ExportCoordinator.endExport() } }

        do {
            Log.export.notice(
                "venice export start url=\(outputURL.lastPathComponent)",
                telemetry: "Venice project export started",
                data: [
                    "tracks": timeline.tracks.count,
                    "clips": timeline.tracks.reduce(0) { $0 + $1.clips.count },
                    "media": manifest.entries.count,
                    "generationLogEntries": generationLog.entries.count
                ]
            )
            let collectTask = Task.detached(priority: .userInitiated) {
                try VeniceProjectExporter.export(
                    timeline: timeline, manifest: manifest, generationLog: generationLog,
                    sourceProjectURL: sourceProjectURL, to: outputURL,
                    progress: { p in Task { @MainActor in self.progress = p } }
                )
            }
            // Detached work won't inherit cancellation; forward it from the export task.
            let report = try await withTaskCancellationHandler {
                try await collectTask.value
            } onCancel: {
                collectTask.cancel()
            }
            progress = 1.0
            Log.export.notice(
                "venice export ok collected=\(report.collected.count) missing=\(report.missing.count)",
                telemetry: "Venice project export finished",
                data: ["collected": report.collected.count, "missing": report.missing.count]
            )
            return report
        } catch is CancellationError {
            self.error = "Export cancelled"
            Log.export.notice("venice export cancelled", telemetry: "Venice project export cancelled")
            return nil
        } catch {
            self.error = error.localizedDescription
            Log.export.error(
                "venice export failed: \(Log.detail(error))",
                telemetry: "Venice project export failed",
                data: ["error": Log.detail(error)]
            )
            return nil
        }
    }

    /// Encode HEVC Main10 HDR; `HDRVideoExporter` converts the composition's SDR 709 frames to HLG.
    private func exportHDR(
        timeline: Timeline,
        resolver: MediaResolver,
        resolution: ExportResolution,
        missingMediaRefs: Set<String>,
        outputURL: URL
    ) async {
        isExporting = true
        progress = 0
        error = nil
        defer { isExporting = false }
        do {
            let renderSize = resolution.renderSize(for: CGSize(width: timeline.width, height: timeline.height))
            let result = try await CompositionBuilder.build(
                timeline: timeline,
                resolveURL: { resolver.resolveURL(for: $0) },
                missingMediaRefs: missingMediaRefs,
                renderSize: renderSize
            )
            try? FileManager.default.removeItem(at: outputURL)
            Log.export.notice("hdr export start size=\(Int(renderSize.width))x\(Int(renderSize.height)) url=\(outputURL.lastPathComponent)")
            let inputs = HDRVideoExporter.Inputs(
                composition: result.composition,
                videoComposition: result.videoComposition,
                audioMix: result.audioMix
            )
            try await HDRVideoExporter.export(
                inputs, renderSize: renderSize, transfer: .hlg, to: outputURL,
                onProgress: { [weak self] p in Task { @MainActor in self?.progress = p } }
            )
            let outputSize = await Self.encodedVideoSize(of: outputURL) ?? renderSize
            lastReport = ExportRunReport(
                outputSize: outputSize,
                offlineMediaRefs: result.offlineMediaRefs,
                unprocessableMediaRefs: result.unprocessableMediaRefs
            )
            progress = 1.0
            Log.export.notice("hdr export ok")
        } catch {
            self.error = Log.detail(error)
            Log.export.error("hdr export failed: \(Log.detail(error))")
        }
    }

    /// Encoded dimensions of the written file (natural size with preferred
    /// transform applied), the source of truth when a preset clamped the size.
    private static func encodedVideoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let size = naturalSize.applying(transform)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }

    private func makeExportSession(
        timeline: Timeline,
        resolver: MediaResolver,
        format: ExportFormat,
        resolution: ExportResolution,
        missingMediaRefs: Set<String>
    ) async throws -> (session: AVAssetExportSession, result: CompositionResult, renderSize: CGSize) {
        let timelineCanvas = CGSize(width: timeline.width, height: timeline.height)
        let renderSize = resolution.renderSize(for: timelineCanvas)
        let mediaURLs = resolver.expectedURLMap()

        let result = try await CompositionBuilder.build(
            timeline: timeline,
            resolveURL: { mediaURLs[$0] },
            missingMediaRefs: missingMediaRefs,
            renderSize: renderSize
        )

        let presetName = exportPresetName(format: format, resolution: resolution)
        guard let session = AVAssetExportSession(asset: result.composition, presetName: presetName) else {
            throw ExportError.unsupportedPreset
        }
        session.audioMix = result.audioMix
        session.videoComposition = result.videoComposition
        return (session, result, renderSize)
    }

    // MARK: - Export preset mapping

    private func exportPresetName(format: ExportFormat, resolution: ExportResolution) -> String {
        switch format {
        case .h264:
            switch resolution {
            case .r720p: AVAssetExportPreset1280x720
            case .r1080p: AVAssetExportPreset1920x1080
            case .r4k: AVAssetExportPreset3840x2160
            // Size-named presets clamp dimensions; HighestQuality honours the
            // composition's renderSize, so 2K / Match Timeline export at their true size.
            case .r1440p, .matchTimeline: AVAssetExportPresetHighestQuality
            }
        case .h265:
            switch resolution {
            case .r720p: AVAssetExportPresetHEVCHighestQuality
            case .r1080p: AVAssetExportPresetHEVC1920x1080
            case .r4k: AVAssetExportPresetHEVC3840x2160
            case .r1440p, .matchTimeline: AVAssetExportPresetHEVCHighestQuality
            }
        case .prores:
            AVAssetExportPresetAppleProRes422LPCM
        case .xml, .fcpxml, .hevcHDR:
            AVAssetExportPresetPassthrough // unreachable — timeline formats and HDR return early
        }
    }
}
