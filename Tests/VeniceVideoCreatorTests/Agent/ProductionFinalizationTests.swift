import AppKit
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Retained take finalization")
@MainActor
struct ProductionFinalizationTests {
    private func retained(count: Int = 3, autoQA: Bool = true) throws -> (ToolHarness, String, MediaAsset) {
        let h = ToolHarness()
        let shots = (0..<count).map { Shot(id: "s\($0)", prompt: "A car drives forward.") }
        h.editor.saveShotPlan(ShotPlan(resolution: "768P", shots: shots))
        let o = h.editor.productionOrchestrator
        o.executeUnit = { _, _ in Issue.record("Paused fixture must not submit") }
        #expect(o.produceShots(ids: shots.map(\.id)))
        o.pause()
        let id = try h.editor.beginProductionOperation(shotIds: shots.map(\.id), runId: o.currentRunId, autoQA: autoQA)
        let input = try h.editor.beginProductionAttempt(operationId: id, recipe: .init(prompt: "A car drives.", model: "minimax-h3-max-text-to-video", duration: count * 5, aspectRatio: "16:9", resolution: "768P"))
        let asset = h.addAsset(duration: Double(count * 5), hasAudio: true)
        asset.generationInput = input
        asset.generationInput?.backendJobId = "existing-backend"
        asset.generationInput?.queueId = "existing-queue"
        h.editor.recordProductionJobMetadata(asset)
        o.cancel()
        h.editor.persistProductionState = {}
        o.digestVideo = { $0.id }
        o.validateVideo = { _, _, _ in .pass }
        o.quoteVideo = { _, _, _, _ in Issue.record("Finalization must not quote generation"); return nil }
        o.generateVideo = { _ in Issue.record("Finalization must not buy another video"); return nil }
        return (h, id, asset)
    }

    private func settled(_ h: ToolHarness) async throws {
        for _ in 0..<10_000 {
            if !h.editor.productionOrchestrator.isRunning { return }
            await Task.yield()
        }
        try #require(!h.editor.productionOrchestrator.isRunning)
    }

    @Test func everyGroupedRangeIsReviewedAndRepeatRequestDoesNotDuplicate() async throws {
        let (h, id, _) = try retained()
        defer { h.editor.productionOrchestrator.cancel() }
        var ranges: [ShotSourceRange] = []
        h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, range in
            ranges.append(range)
            return .init(score: 1, pass: true, issues: [], summary: "Passed range")
        }
        let shortId = try #require(ToolExecutor.shortIdMap(h.executor.currentIdUniverse(h.editor))[id])
        _ = try await h.runOK("resume_production", args: ["operationId": shortId])
        try await settled(h)
        #expect(ranges == [.init(startSeconds: 0, endSeconds: 5), .init(startSeconds: 5, endSeconds: 10), .init(startSeconds: 10, endSeconds: 15)])
        let operation = try #require(h.editor.productionOperation(id: id))
        let evidence = try #require(operation.attempts.last?.finalization)
        #expect(operation.stage == .placed)
        #expect(evidence.reviews.count == 3)
        #expect(evidence.placements.count == 3)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 6)
        let timeline = h.editor.timeline
        _ = try await h.runOK("resume_production", args: ["operationId": shortId])
        #expect(h.editor.timeline == timeline)
        #expect(ranges.count == 3)
        #expect(h.editor.shotPlan?.shots.allSatisfy { $0.takes.count == 1 } == true)
    }

    @Test func retryQAUsesSameTakeAndReusesPassedRanges() async throws {
        let (h, id, _) = try retained()
        defer { h.editor.productionOrchestrator.cancel() }
        var reviewed: [String] = []
        var rejectMiddle = true
        var unavailable = false
        h.editor.productionOrchestrator.evaluateVideoQA = { shotId, _, _, _ in
            reviewed.append(shotId)
            if shotId == "s1" && unavailable { return nil }
            let pass = shotId != "s1" || !rejectMiddle
            return .init(score: pass ? 1 : 0, pass: pass, issues: [], summary: pass ? "Passed" : "Wrong subject")
        }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(reviewed == ["s0", "s1"])
        unavailable = true
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        let unchecked = try #require(h.editor.productionOperation(id: id)?.attempts.last?.finalization?.reviews.first { $0.shotId == "s1" })
        #expect(unchecked.summary == "QA unavailable")
        #expect(unchecked.qaPassed == nil)
        unavailable = false
        rejectMiddle = false
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(reviewed == ["s0", "s1", "s1", "s1", "s2"])
        #expect(h.editor.productionOperation(id: id)?.attempts.count == 1)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 6)
    }

    @Test func reasonedOverrideRetainsFailedVerdictWithoutAnotherQACall() async throws {
        let (h, id, _) = try retained(count: 1)
        defer { h.editor.productionOrchestrator.cancel() }
        var calls = 0
        h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in
            calls += 1
            return .init(score: 0, pass: false, issues: ["Wrong subject"], summary: "Wrong subject")
        }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        _ = try await h.runOK("resume_production", args: ["operationId": id, "approvalReason": "Reviewed the range; this alternate subject is intentional."])
        try await settled(h)
        let review = try #require(h.editor.productionOperation(id: id)?.attempts.last?.finalization?.reviews.first)
        #expect(review.passed)
        #expect(review.qaPassed == false)
        #expect(review.summary == "Wrong subject")
        #expect(review.reviewer == "user")
        #expect(review.approvalReason?.isEmpty == false)
        #expect(calls == 1)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func changedVideoBytesCannotReusePriorReviewOrPlaceDuringReview() async throws {
        let (h, id, _) = try retained(count: 1)
        defer { h.editor.productionOrchestrator.cancel() }
        var digest = "first revision"
        var calls = 0
        h.editor.productionOrchestrator.digestVideo = { _ in digest }
        h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in
            calls += 1
            digest = "second revision"
            return .init(score: 1, pass: true, issues: [], summary: "Passed")
        }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(h.editor.productionOperation(id: id)?.failureReason?.contains("Video changed") == true)
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(calls == 2)
        #expect(h.editor.productionOperation(id: id)?.attempts.last?.finalization?.contentDigest == "second revision")
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func changedSeedOrDestinationBlocksRecovery() throws {
        let (h, id, _) = try retained(count: 1)
        h.editor.mutateShotPlan(actionName: "New seed") { $0.seed = 42 }
        #expect(throws: ToolError.self) { try h.editor.productionOrchestrator.resumeProduction(operationId: id) }
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
    }

    @Test func checkpointFailureAfterPlacementCanRetrySaveWithoutDuplicating() async throws {
        let (h, id, _) = try retained(count: 1, autoQA: false)
        defer { h.editor.productionOrchestrator.cancel() }
        var saves = 0
        h.editor.persistProductionState = {
            saves += 1
            if saves == 2 { throw ToolError("Fixture final save failure") }
        }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.productionOperation(id: id)?.stage == .placed)
        #expect(h.editor.productionOperation(id: id)?.failureReason == "Fixture final save failure")
        #expect(h.editor.productionOrchestrator.completedCount == 0)
        let timeline = h.editor.timeline
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline == timeline)
        #expect(h.editor.productionOperation(id: id)?.failureReason == nil)
        #expect(h.editor.productionOrchestrator.completedCount == 1)
    }

    @Test func undonePlacementIsNotSilentlyRecreatedByResume() async throws {
        let (h, id, _) = try retained(count: 1, autoQA: false)
        defer { h.editor.productionOrchestrator.cancel() }
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        undo.undo()
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(throws: ToolError.self) { try h.editor.productionOrchestrator.resumeProduction(operationId: id) }
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
    }

    @Test func projectRoundTripRetainsReviewAndFinalizesOnceAfterReopen() async throws {
        let (h, id, asset) = try retained(count: 1)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("finalization-\(UUID()).venice")
        defer { h.editor.productionOrchestrator.cancel(); try? FileManager.default.removeItem(at: url) }
        h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in nil }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        try VideoProject.writeProjectPackage(.init(timeline: JSONEncoder().encode(h.editor.timeline), manifest: JSONEncoder().encode(h.editor.mediaManifest), generationLog: nil, thumbnail: nil, chatSessionFiles: []), to: url, sourceURL: nil)
        let package = try VideoProject.readProjectPackage(at: url)
        let reopened = ToolHarness(timeline: package.timeline)
        reopened.editor.mediaManifest = try #require(package.manifest)
        reopened.editor.mediaAssets = [asset]
        reopened.editor.persistProductionState = {}
        reopened.editor.productionOrchestrator.digestVideo = { $0.id }
        reopened.editor.productionOrchestrator.validateVideo = { _, _, _ in .pass }
        reopened.editor.productionOrchestrator.generateVideo = { _ in Issue.record("Recovery submitted a generation"); return nil }
        reopened.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in .init(score: 1, pass: true, issues: [], summary: "Reviewed on reopen") }
        defer { reopened.editor.productionOrchestrator.cancel() }
        _ = try await reopened.runOK("resume_production", args: ["operationId": id])
        try await settled(reopened)
        #expect(reopened.editor.shot(id: "s0")?.takes.count == 1)
        #expect(reopened.editor.timeline.tracks.flatMap(\.clips).count == 2)
        #expect(reopened.editor.productionOperation(id: id)?.attempts.last?.finalization?.reviews.first?.summary == "Reviewed on reopen")
    }

    @Test func frameSamplingStaysInsideTheRequestedBeat() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 2), .init(rgb: (0, 0, 255), seconds: 2)], size: 64)
        defer { try? FileManager.default.removeItem(at: url) }
        let frames = await VisionQA.videoFrames(url: url, count: 2, sourceRange: .init(startSeconds: 2, endSeconds: 3.5))
        #expect(frames.count == 2)
        for data in frames {
            let bitmap = try #require(NSBitmapImageRep(data: data))
            let color = try #require(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB))
            #expect(color.blueComponent > color.redComponent + 0.5)
        }
        #expect(await VisionQA.videoFrames(url: url, sourceRange: .init(startSeconds: 3, endSeconds: 5)).isEmpty)
        let h = ToolHarness()
        let asset = MediaAsset(id: "digest-video", url: url, type: .video, name: "Digest fixture", duration: 4)
        h.editor.mediaAssets = [asset]
        h.editor.mediaManifest.entries = [.init(id: asset.id, name: asset.name, type: .video, source: .external(absolutePath: url.path), duration: 4)]
        let before = try await h.editor.productionOrchestrator.outputDigest(asset)
        var bytes = try Data(contentsOf: url)
        bytes.append(0)
        try bytes.write(to: url)
        let after = try await h.editor.productionOrchestrator.outputDigest(asset)
        #expect(before.count == 64)
        #expect(after != before)
    }

    @Test func concurrentAndCancelledFinalizersCannotPlaceTwice() async throws {
        let (h, id, _) = try retained(count: 1, autoQA: false)
        var gate: CheckedContinuation<OutputValidator.Result, Never>?
        h.editor.productionOrchestrator.validateVideo = { _, _, _ in await withCheckedContinuation { gate = $0 } }
        defer { gate?.resume(returning: .pass); h.editor.productionOrchestrator.cancel() }
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        for _ in 0..<10_000 where gate == nil { await Task.yield() }
        try #require(gate != nil)
        #expect(throws: ToolError.self) { try h.editor.productionOrchestrator.resumeProduction(operationId: id) }
        h.editor.productionOrchestrator.cancel()
        #expect(throws: ToolError.self) { try h.editor.productionOrchestrator.resumeProduction(operationId: id) }
        h.editor.productionOrchestrator.validateVideo = { _, _, _ in .pass }
        gate?.resume(returning: .pass)
        gate = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func inheritedAspectUsesDecodedFirstFrame() throws {
        let h = ToolHarness()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("first-frame-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 20, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        h.editor.mediaManifest.entries = [.init(id: "frame", name: "Frame", type: .image, source: .external(absolutePath: url.path), duration: 0)]
        var recipe = GenerationInput(prompt: "", model: VideoModelCapabilities.multiAngleID, duration: 5, aspectRatio: "16:9", resolution: "768P")
        recipe.imageURLAssetIds = ["frame"]
        #expect(try h.editor.productionOrchestrator.expectedOutputAspect(for: recipe) == "20:40")
        recipe.imageURLAssetIds = ["missing"]
        #expect(throws: ToolError.self) { try h.editor.productionOrchestrator.expectedOutputAspect(for: recipe) }
    }

    @Test func invalidDecodedFactsCannotPassValidation() {
        for duration in [Double.nan, .infinity, 0, -1] {
            #expect(!OutputValidator.validate(displayWidth: 1920, displayHeight: 1080, durationSeconds: duration,
                requestedDurationSeconds: 5, fileSizeBytes: 100_000, targetAspectRatio: "16:9").ok)
        }
        #expect(!OutputValidator.validate(displayWidth: .infinity, displayHeight: 1080, durationSeconds: 5,
            requestedDurationSeconds: 5, fileSizeBytes: 100_000, targetAspectRatio: "16:9").ok)
    }

    @Test func groupedCoverageCannotShortenTheLastBeat() async throws {
        let (h, id, asset) = try retained(autoQA: false)
        defer { h.editor.productionOrchestrator.cancel() }
        asset.duration = 14
        try h.editor.productionOrchestrator.resumeProduction(operationId: id)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(h.editor.productionOperation(id: id)?.attempts.last?.finalization?.validationFailure?.contains("planned beat durations") == true)
    }
}
