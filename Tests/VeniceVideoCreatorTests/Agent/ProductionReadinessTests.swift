import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Production export readiness")
@MainActor
struct ProductionReadinessTests {
    private func movie(seconds: Int = 5, place: Bool = true) async throws -> (ToolHarness, MediaAsset, URL) {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: Double(seconds))], size: 64)
        let h = ToolHarness()
        let asset = h.addAsset(duration: Double(seconds))
        asset.url = url
        h.editor.mediaManifest.entries = [.init(id: asset.id, name: asset.name, type: .video, source: .external(absolutePath: url.path), duration: asset.duration)]
        if place { h.editor.timeline.tracks = [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: asset.id, start: 0, duration: seconds * 30)])] }
        return (h, asset, url)
    }

    private func reviewed(count: Int = 1, autoQA: Bool = true) async throws -> (ToolHarness, MediaAsset, URL) {
        let (h, asset, url) = try await movie(seconds: count * 5, place: false)
        h.editor.saveShotPlan(ShotPlan(resolution: "768P", shots: (0..<count).map { Shot(id: "shot-\($0)", prompt: "A car drives forward.") }))
        let o = h.editor.productionOrchestrator
        o.executeUnit = { _, _ in Issue.record("Paused fixture must not submit") }
        #expect(o.produceShots(ids: h.editor.shotPlan!.shots.map(\.id)))
        o.pause()
        let id = try h.editor.beginProductionOperation(shotIds: h.editor.shotPlan!.shots.map(\.id), runId: o.currentRunId, autoQA: autoQA)
        asset.generationInput = try h.editor.beginProductionAttempt(operationId: id, recipe: .init(prompt: "A car drives.", model: "minimax-h3-max-text-to-video", duration: count * 5, aspectRatio: "16:9", resolution: "768P"))
        h.editor.recordProductionJobMetadata(asset)
        o.cancel()
        h.editor.persistProductionState = {}
        o.validateVideo = { _, _, _ in .pass }
        o.evaluateVideoQA = { _, _, _, _ in .init(score: 1, pass: true, issues: [], summary: "Fixture range passed") }
        o.generateVideo = { _ in Issue.record("Readiness fixture submitted video"); return nil }
        try o.resumeProduction(operationId: id)
        for _ in 0..<20_000 {
            if !o.isRunning { break }
            await Task.yield()
        }
        try #require(h.editor.productionOperation(id: id)?.stage == .placed)
        return (h, asset, url)
    }

    @Test func dispatcherPreflightIsReadOnlyAndRevisionIsStable() async throws {
        let (h, _, url) = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        let before = h.editor.timeline
        let manifest = h.editor.mediaManifest
        let result = try await h.runOK("production_readiness") as? [String: Any]
        #expect(result?["canExport"] as? Bool == true)
        let report = await h.editor.productionReadiness()
        #expect(report.revision == result?["revision"] as? String)
        #expect(report.revision?.count == 64)
        #expect(h.editor.timeline == before && h.editor.mediaManifest == manifest)
    }

    @Test func exportSnapshotFreezesTimelineAndMediaResolution() async throws {
        let (h, asset, url) = try await movie()
        let other = try await FixtureVideo.write(scenes: [.init(rgb: (0, 0, 255), seconds: 5)], size: 64)
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: other) }
        let snapshot = try await h.editor.prepareVideoExport()
        h.editor.mediaManifest.entries[0].source = .external(absolutePath: other.path)
        h.editor.timeline.tracks[0].clips[0].startFrame = 30
        #expect(snapshot.timeline.tracks[0].clips[0].startFrame == 0)
        #expect(snapshot.resolver.resolveURL(for: asset.id) == url)
        #expect(h.editor.mediaResolver.resolveURL(for: asset.id) == other)
        try FileManager.default.removeItem(at: url)
        #expect(snapshot.resolver.resolveURL(for: asset.id) == nil)
        #expect(snapshot.resolver.isMissing(for: asset.id))
    }

    @Test func pendingAndMissingMediaPreventExport() async throws {
        let (h, asset, url) = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        asset.generationStatus = .generating
        let pending = await h.editor.productionReadiness()
        #expect(!pending.canExport)
        #expect(pending.issues.contains { $0.code == "pendingProduction" })
        asset.generationStatus = .none
        try FileManager.default.removeItem(at: url)
        let missing = await h.editor.productionReadiness()
        #expect(missing.issues.contains { $0.code == "missingMedia" })
        await #expect(throws: ToolError.self) { try await h.editor.prepareVideoExport() }
    }

    @Test func unplacedShotsAndMissingVoiceOverAreReported() async throws {
        let (h, asset, url) = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        h.editor.saveShotPlan(ShotPlan(shots: [Shot(id: "shot", prompt: "A car drives.")]))
        let unplaced = await h.editor.productionReadiness()
        #expect(unplaced.issues.contains { $0.code == "unplacedShot" })
        h.editor.mutateShotPlan(actionName: "Bind movie and narration") {
            $0.shots[0].videoAssetId = asset.id
            $0.shots[0].dialogue = [ShotDialogue(text: "The road opens ahead.", voiceOver: true)]
        }
        let missing = await h.editor.productionReadiness()
        #expect(missing.issues.contains { $0.code == "missingVoiceOver" })
        h.editor.mutateShotPlan(actionName: "Native speech") { $0.shots[0].dialogue[0].voiceOver = false }
        let native = await h.editor.productionReadiness()
        #expect(native.issues.contains { $0.code == "nativeSpeechUnverified" && $0.severity == .warning })
        #expect(native.issues.contains { $0.code == "missingNativeSpeech" })
    }

    @Test func reviewedRangesAndVideoBytesAreCheckedWithoutProviderCalls() async throws {
        let (h, _, url) = try await reviewed(count: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(await h.editor.productionReadiness().canExport)
        h.editor.timeline.tracks[0].clips[0].trimStartFrame = 15
        let range = await h.editor.productionReadiness()
        #expect(range.issues.contains { $0.code == "unreviewedRange" })
        h.editor.timeline.tracks[0].clips[0].trimStartFrame = 0
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let bytes = await h.editor.productionReadiness()
        #expect(!bytes.canExport)
        #expect(bytes.issues.contains { $0.code == "changedVideo" })
    }

    @Test func editedShotRevisionFailsAndDisabledQARemainsExplicit() async throws {
        let (h, _, url) = try await reviewed(autoQA: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let disabled = await h.editor.productionReadiness()
        #expect(disabled.canExport)
        #expect(disabled.issues.contains { $0.code == "qaDisabled" && $0.severity == .warning })
        h.editor.mutateShotPlan(actionName: "New choreography") { $0.shots[0].prompt = "A car turns around and drives away." }
        let stale = await h.editor.productionReadiness()
        #expect(!stale.canExport)
        #expect(stale.issues.contains { $0.code == "staleTake" })
    }

    @Test func editsDuringHashingCannotApproveAnotherRevision() async throws {
        let (h, _, url) = try await reviewed()
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try #require(h.editor.mediaManifest.productionOperations.last?.attempts.last?.finalization?.contentDigest)
        h.editor.productionOrchestrator.digestVideo = { _ in
            h.editor.timeline.tracks[0].clips[0].startFrame += 1
            return expected
        }
        let report = await h.editor.productionReadiness()
        #expect(!report.canExport)
        #expect(report.issues.contains { $0.code == "projectChanged" })
    }

    @Test func audioLayoutCheckDoesNotReflowUntilExplicitReconciliation() async throws {
        let f = ProductionAudioLayoutTests.Fixture()
        defer { f.cleanup() }
        try await f.finish()
        let picture = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 10)], size: 64)
        defer { try? FileManager.default.removeItem(at: picture) }
        f.h.editor.mediaAssets[0].url = picture
        f.h.editor.mediaManifest.entries = f.h.editor.mediaAssets.map {
            .init(id: $0.id, name: $0.name, type: $0.type, source: .external(absolutePath: $0.url.path), duration: $0.duration)
        }
        f.h.editor.timeline.tracks[0].clips[0].startFrame = 30
        let before = f.h.editor.timeline
        let manifest = f.h.editor.mediaManifest
        let report = await f.h.editor.productionReadiness()
        #expect(!report.canExport)
        #expect(report.issues.contains { $0.code == "audioReconciliation" })
        #expect(f.h.editor.timeline == before && f.h.editor.mediaManifest == manifest)
        let revision = try f.h.editor.videoExportRevision()
        f.h.editor.mediaManifest.productionAudioOperations[0].ownsTiming.toggle()
        #expect(try f.h.editor.videoExportRevision() != revision)
        f.h.editor.mediaManifest.productionAudioOperations[0].ownsTiming.toggle()
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(await f.h.editor.productionReadiness().canExport)
        let voice = try f.clip(0)
        f.h.editor.commitClipProperty(clipId: voice.id) { $0.volume = 0 }
        let muted = await f.h.editor.productionReadiness()
        #expect(muted.issues.contains { $0.code == "mutedVoiceOver" })
        f.h.editor.commitClipProperty(clipId: voice.id) {
            $0.volume = 1
            $0.volumeTrack = KeyframeTrack(keyframes: [Keyframe(frame: 0, value: VolumeScale.floorDb)])
        }
        let envelope = await f.h.editor.productionReadiness()
        #expect(envelope.issues.contains { $0.code == "mutedVoiceOver" })
    }

    @Test func failedPreflightDoesNotOverwriteExistingDestination() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "missing", start: 0, duration: 30)])]))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("readiness-destination-\(UUID()).mp4")
        let original = Data("Keep this existing destination".utf8)
        try original.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await h.runRaw("export_project", args: ["outputPath": url.path, "overwrite": true])
        #expect(result.isError)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func invalidTimingAndDuplicateIdentityProduceReadableReports() async throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(start: Int.max, duration: 1)])]))
        let timing = await h.editor.productionReadiness()
        #expect(!timing.canExport)
        #expect(timing.issues.contains { $0.code == "invalidTiming" })
        let (valid, _, url) = try await movie()
        defer { try? FileManager.default.removeItem(at: url) }
        valid.editor.mediaManifest.entries.append(valid.editor.mediaManifest.entries[0])
        let duplicate = await valid.editor.productionReadiness()
        #expect(duplicate.issues.contains { $0.code == "duplicateIdentity" })
    }
}
