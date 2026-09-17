import AVFoundation
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Retained verified video exports", .serialized)
@MainActor
struct VideoExportJobTests {
    @MainActor
    final class Fixture {
        let h = ToolHarness()
        let directory: URL
        let source: URL
        let output: URL
        let original = Data("Existing destination must survive".utf8)

        init(audio: Bool = false) async throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("verified-export-\(UUID())")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            source = directory.appendingPathComponent("source.mp4")
            output = directory.appendingPathComponent("delivery.mp4")
            let movie = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 1)], fps: 30, size: 64)
            try FileManager.default.moveItem(at: movie, to: source)
            let asset = h.addAsset(duration: 1)
            asset.url = source
            h.editor.mediaManifest.entries = [.init(id: asset.id, name: "Picture", type: .video, source: .external(absolutePath: source.path), duration: 1)]
            h.editor.timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(id: "picture", mediaRef: asset.id, start: 0, duration: 30)])])
            h.editor.timeline.width = 64
            h.editor.timeline.height = 64
            if audio {
                let url = directory.appendingPathComponent("speech.wav")
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<24_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 24_000) * 0.1) }
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
                h.editor.mediaManifest.entries.append(.init(id: "speech", name: "Speech", type: .audio, source: .external(absolutePath: url.path), duration: 1))
                h.editor.timeline.tracks.append(Fixtures.audioTrack(clips: [Fixtures.clip(id: "voice", mediaRef: "speech", mediaType: .audio, start: 0, duration: 30)]))
            }
        }

        func start(overwrite: Bool = true) async throws -> VideoExportJob {
            let snapshot = try await h.editor.prepareVideoExport()
            return try h.editor.videoExportJobs.start(snapshot: snapshot, format: .h264, resolution: .matchTimeline,
                                                       outputURL: output, overwrite: overwrite)
        }

        func finish(_ job: VideoExportJob) async throws -> VideoExportJob {
            let result = try await h.editor.videoExportJobs.wait(job.id, timeout: .seconds(20))
            try #require(result.status.isTerminal)
            return result
        }

        func protectDestination() throws { try original.write(to: output) }
        func copyRender() {
            h.editor.videoExportJobs.renderVideo = { timeline, resolver, _, _, output in
                let ref = timeline.tracks[0].clips[0].mediaRef
                try FileManager.default.copyItem(at: #require(resolver.resolveURL(for: ref)), to: output)
            }
        }
        func cleanup() { h.editor.videoExportJobs.detachAll(); try? FileManager.default.removeItem(at: directory) }
    }

    @Test func agentWaitReturnsVerifiedPictureAndAudioWithoutStartingAnotherJob() async throws {
        let f = try await Fixture(audio: true)
        defer { f.cleanup() }
        try await ExportCoordinator.waitWhileExportActive()
        let started = try await f.h.runOK("export_project", args: ["outputPath": f.output.path]) as? [String: Any]
        let id = try #require(started?["jobId"] as? String)
        let revision = try #require(started?["revision"] as? String)
        let result = try await f.h.runOK("wait_for_export", args: ["jobId": id, "timeoutSeconds": 20]) as? [String: Any]
        #expect(result?["status"] as? String == "completed", "\(result ?? [:])")
        #expect(result?["revision"] as? String == revision)
        let artifact = try #require(result?["artifact"] as? [String: Any])
        #expect(artifact["videoFrames"] as? Int == 30)
        #expect(artifact["width"] as? Int == 64 && artifact["height"] as? Int == 64)
        #expect(artifact["audioTracks"] as? Int == 1)
        #expect((artifact["decodedAudioSamples"] as? Int ?? 0) > 0)
        #expect(try await ExportFiles.digests(["output": f.output])["output"] == artifact["sha256"] as? String)
        let again = try await f.h.runOK("wait_for_export", args: ["jobId": id, "timeoutSeconds": 0]) as? [String: Any]
        #expect(again?["status"] as? String == "completed")
        let listed = try await f.h.runOK("export_status") as? [[String: Any]]
        #expect(listed?.count == 1)
        #expect(f.h.editor.mediaManifest.videoExportJobs.count == 1)
    }

    @Test func privateSourcesAndTimelineStayBoundWhileEditorChanges() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let snapshot = try await f.h.editor.prepareVideoExport()
        f.h.editor.videoExportJobs.renderVideo = { timeline, resolver, _, _, output in
            #expect(timeline.totalFrames == 30)
            let copy = try #require(resolver.resolveURL(for: timeline.tracks[0].clips[0].mediaRef))
            #expect(copy != f.source)
            f.h.editor.timeline.tracks[0].clips[0].durationFrames = 60
            f.h.editor.mediaManifest.entries[0].source = .external(absolutePath: "/missing/retarget.mp4")
            try FileManager.default.copyItem(at: copy, to: output)
        }
        let job = try f.h.editor.videoExportJobs.start(snapshot: snapshot, format: .h264, resolution: .matchTimeline, outputURL: f.output, overwrite: false)
        let result = try await f.finish(job)
        #expect(result.status == .completed, "\(result.error ?? "")")
        #expect(result.revision == snapshot.revision && result.timeline.totalFrames == 30)
        #expect(f.h.editor.timeline.totalFrames == 60)
        #expect(!FileManager.default.fileExists(atPath: f.directory.appendingPathComponent(".venice-export-\(job.id)").path))
    }

    @Test(arguments: [false, true]) func sourceChangesNeverReplaceDestination(duringRender: Bool) async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.protectDestination()
        let snapshot = try await f.h.editor.prepareVideoExport()
        func changeSource() throws {
            let handle = try FileHandle(forWritingTo: f.source)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data([0]))
        }
        if !duringRender { try changeSource() }
        f.h.editor.videoExportJobs.renderVideo = { timeline, resolver, _, _, output in
            #expect(duringRender)
            try FileManager.default.copyItem(at: #require(resolver.resolveURL(for: timeline.tracks[0].clips[0].mediaRef)), to: output)
            try changeSource()
        }
        let job = try f.h.editor.videoExportJobs.start(snapshot: snapshot, format: .h264, resolution: .matchTimeline, outputURL: f.output, overwrite: true)
        let result = try await f.finish(job)
        #expect(result.status == .failed && result.error?.contains("changed") == true)
        #expect(try Data(contentsOf: f.output) == f.original)
    }

    @Test(arguments: ["empty", "short", "size", "fps", "codec", "audio"]) func rejectsInvalidArtifacts(kind: String) async throws {
        let f = try await Fixture(audio: kind == "audio")
        defer { f.cleanup() }
        let timeline = f.h.editor.timeline
        let url: URL
        if kind == "empty" {
            url = f.directory.appendingPathComponent("invalid.mp4")
            try Data("Not a movie".utf8).write(to: url)
        } else if kind == "short" || kind == "size" || kind == "fps" {
            url = try await FixtureVideo.write(scenes: [.init(rgb: (0, 0, 255), seconds: kind == "short" ? 0.5 : 1)], fps: kind == "fps" ? 15 : 30, size: kind == "size" ? 32 : 64)
        } else { url = f.source }
        defer { if url != f.source { try? FileManager.default.removeItem(at: url) } }
        await #expect(throws: (any Error).self) {
            try await ExportArtifactVerifier.verify(url, timeline: timeline, size: CGSize(width: 64, height: 64), format: kind == "codec" ? .h265 : .h264)
        }
    }

    @Test(arguments: [ExportFormat.h264, .h265, .prores, .hevcHDR]) func realCodecsRespectTheCapturedFrameRate(format: ExportFormat) async throws {
        let f = try await Fixture(audio: true)
        defer { f.cleanup() }
        f.h.editor.timeline.fps = 24
        for index in f.h.editor.timeline.tracks.indices { f.h.editor.timeline.tracks[index].clips[0].durationFrames = 24 }
        let snapshot = try await f.h.editor.prepareVideoExport()
        let output = f.output.deletingPathExtension().appendingPathExtension(format.fileExtension)
        let job = try f.h.editor.videoExportJobs.start(snapshot: snapshot, format: format, resolution: .matchTimeline, outputURL: output, overwrite: false)
        let result = try await f.finish(job)
        #expect(result.status == .completed, "\(result.error ?? "")")
        #expect(result.artifact?.videoFrames == 24)
        #expect(result.artifact?.decodedAudioSamples ?? 0 > 0)
    }

    @Test func portraitPresetPublishesRequestedDimensions() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        f.h.editor.timeline.height = 96
        let snapshot = try await f.h.editor.prepareVideoExport()
        let size = ExportResolution.r720p.renderSize(for: CGSize(width: 64, height: 96))
        let job = try f.h.editor.videoExportJobs.start(snapshot: snapshot, format: .h264, resolution: .r720p, outputURL: f.output, overwrite: false)
        let result = try await f.finish(job)
        #expect(result.status == .completed, "\(result.error ?? "")")
        #expect(result.artifact?.width == Int(size.width) && result.artifact?.height == Int(size.height))
    }

    @Test func lutBytesBelongToTheExportRevisionAndCannotChangeDuringRender() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.protectDestination()
        let lut = f.directory.appendingPathComponent("look.cube")
        let cube = "LUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        try cube.write(to: lut, atomically: true, encoding: .utf8)
        f.h.editor.timeline.tracks[0].clips[0].effects = [Effect(type: "color.lut", params: ["path": .init(string: lut.path)])]
        let first = try await f.h.editor.prepareVideoExport()
        let changed = cube.replacingOccurrences(of: "0 0 0", with: "1 0 0")
        try changed.write(to: lut, atomically: true, encoding: .utf8)
        let second = try await f.h.editor.prepareVideoExport()
        #expect(first.readiness.revision == second.readiness.revision)
        #expect(first.revision != second.revision)
        f.h.editor.videoExportJobs.renderVideo = { timeline, resolver, _, _, output in
            let path = try #require(timeline.tracks[0].clips[0].effects?.first?.params["path"]?.string)
            #expect(path != lut.path)
            #expect(try String(contentsOfFile: path, encoding: .utf8) == changed)
            try FileManager.default.copyItem(at: #require(resolver.resolveURL(for: timeline.tracks[0].clips[0].mediaRef)), to: output)
            try cube.write(to: lut, atomically: true, encoding: .utf8)
        }
        let job = try f.h.editor.videoExportJobs.start(snapshot: second, format: .h264, resolution: .matchTimeline, outputURL: f.output, overwrite: true)
        #expect(try await f.finish(job).status == .failed)
        #expect(try Data(contentsOf: f.output) == f.original)
    }

    @Test(arguments: [false, true]) func stoppingWaitIsIndependentOfCancellingOrClosingExport(close: Bool) async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.protectDestination()
        f.h.editor.videoExportJobs.renderVideo = { _, _, _, _, _ in try await Task.sleep(for: .seconds(30)) }
        let job = try await f.start()
        for _ in 0..<1_000 {
            if try f.h.editor.videoExportJobs.record(job.id).status == .rendering { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiter = Task { try await f.h.editor.videoExportJobs.wait(job.id) }
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        #expect(try f.h.editor.videoExportJobs.record(job.id).status == .rendering)
        if close { f.h.editor.videoExportJobs.detachAll() }
        else { _ = try await f.h.runOK("cancel_export", args: ["jobId": job.id]) }
        #expect(try await f.finish(job).status == .cancelled)
        #expect(try Data(contentsOf: f.output) == f.original)
    }

    @Test func queuedCancellationDoesNotReleaseAnotherExportSlot() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try await ExportCoordinator.acquireExport()
        defer { ExportCoordinator.endExport() }
        f.h.editor.videoExportJobs.renderVideo = { _, _, _, _, _ in Issue.record("Cancelled queue must not render") }
        let job = try await f.start()
        let status = try await f.h.runOK("wait_for_export", args: ["jobId": job.id, "timeoutSeconds": 0]) as? [String: Any]
        #expect(status?["status"] as? String == "queued")
        try f.h.editor.videoExportJobs.cancel(job.id)
        #expect(try await f.finish(job).status == .cancelled)
        #expect(ExportCoordinator.isExportActive)
        #expect(!FileManager.default.fileExists(atPath: f.output.path))
    }

    @Test(arguments: [VideoExportJob.Status.queued, .publishing, .completed]) func saveFailuresCannotReportCompleted(stage: VideoExportJob.Status) async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.protectDestination()
        f.copyRender()
        f.h.editor.projectURL = f.directory.appendingPathComponent("test.venice")
        f.h.editor.persistProductionState = {
            if f.h.editor.mediaManifest.videoExportJobs.last?.status == stage {
                if stage == .completed {
                    let id = try #require(f.h.editor.mediaManifest.videoExportJobs.last?.id)
                    #expect(try f.h.editor.videoExportJobs.record(id).status == .publishing)
                    try await Task.sleep(for: .milliseconds(150))
                }
                throw ToolError("Injected save failure")
            }
        }
        let result = try await f.finish(f.start())
        #expect(result.status == .failed)
        #expect(result.error?.contains("save failure") == true)
        if stage != .completed { #expect(try Data(contentsOf: f.output) == f.original) }
        else { #expect(result.error?.contains("published") == true) }
    }

    @Test func savedHistorySurvivesUndoAndReopenAndInterruptedJobsNeverRestart() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let before = f.h.editor.mediaLibraryUndoSnapshot()
        let package = f.directory.appendingPathComponent("saved.venice")
        f.h.editor.projectURL = package
        f.h.editor.persistProductionState = {
            try VideoProject.writeProjectPackage(.init(timeline: JSONEncoder().encode(f.h.editor.timeline),
                manifest: JSONEncoder().encode(f.h.editor.mediaManifest), generationLog: nil, thumbnail: nil, chatSessionFiles: []), to: package, sourceURL: nil)
        }
        f.copyRender()
        let result = try await f.finish(f.start())
        #expect(result.status == .completed)
        f.h.editor.restoreMediaLibraryUndoSnapshot(before, actionName: "Undo library edit")
        #expect(f.h.editor.mediaManifest.videoExportJobs.first?.id == result.id)
        let saved = try VideoProject.readProjectPackage(at: package)
        let reopened = ToolHarness(timeline: saved.timeline)
        reopened.editor.mediaManifest = try #require(saved.manifest)
        var interrupted = result
        interrupted.id = UUID().uuidString
        interrupted.status = .rendering
        interrupted.artifact = nil
        reopened.editor.mediaManifest.videoExportJobs.append(interrupted)
        reopened.editor.videoExportJobs.renderVideo = { _, _, _, _, _ in Issue.record("Reopen must not render") }
        reopened.editor.videoExportJobs.restore()
        #expect(try reopened.editor.videoExportJobs.record(result.id).status == .completed)
        #expect(try reopened.editor.videoExportJobs.record(interrupted.id).status == .interrupted)
        #expect(try JSONDecoder().decode(MediaManifest.self, from: Data("{}".utf8)).videoExportJobs.isEmpty)
    }

    @Test func sourceDestinationsAndLateOverwriteRacesAreRejected() async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        let snapshot = try await f.h.editor.prepareVideoExport()
        #expect(throws: ToolError.self) {
            try f.h.editor.videoExportJobs.start(snapshot: snapshot, format: .h264, resolution: .matchTimeline, outputURL: f.source, overwrite: true)
        }
        f.h.editor.videoExportJobs.renderVideo = { timeline, resolver, _, _, output in
            try FileManager.default.copyItem(at: #require(resolver.resolveURL(for: timeline.tracks[0].clips[0].mediaRef)), to: output)
            try f.protectDestination()
        }
        let result = try await f.finish(f.start(overwrite: false))
        #expect(result.status == .failed)
        #expect(try Data(contentsOf: f.output) == f.original)
    }

    @Test(arguments: ["corrupt", "overlap", "short-source"]) func incompleteCompositionsFailBeforePublication(kind: String) async throws {
        let f = try await Fixture()
        defer { f.cleanup() }
        try f.protectDestination()
        if kind == "corrupt" { try Data("Invalid media".utf8).write(to: f.source) }
        if kind == "overlap" {
            var other = f.h.editor.timeline.tracks[0].clips[0]
            other.id = "overlap"
            other.startFrame = 10
            f.h.editor.timeline.tracks[0].clips.append(other)
        }
        if kind == "short-source" {
            f.h.editor.timeline.tracks[0].clips[0].durationFrames = 60
            f.h.editor.mediaManifest.entries[0].duration = 2
            f.h.editor.mediaAssets[0].duration = 2
        }
        let result = try await f.finish(f.start())
        #expect(result.status == .failed, "\(result.error ?? "")")
        #expect(try Data(contentsOf: f.output) == f.original)
    }
}
