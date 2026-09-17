import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Production operation lifecycle")
@MainActor
struct ProductionOperationTests {
    @MainActor
    private final class Driver {
        let h = ToolHarness()
        let model: VideoModelConfig
        var checkpoints: [MediaManifest] = []
        var requests: [(asset: MediaAsset, continuation: CheckedContinuation<MediaAsset?, Never>?)] = []
        var quotes = 0

        init() throws {
            model = try MiniMaxRequestTests.model("minimax-h3-max-text-to-video")
            h.editor.saveShotPlan(ShotPlan(resolution: "768P", defaultModel: model.id,
                                          shots: [Shot(id: "shot", prompt: "A car drives forward.")]))
            h.editor.persistProductionState = { [weak self] in
                guard let self else { return }
                self.checkpoints.append(try JSONDecoder().decode(MediaManifest.self, from: JSONEncoder().encode(self.h.editor.mediaManifest)))
            }
            h.editor.productionOrchestrator.availableModels = { [model] in [model] }
            h.editor.productionOrchestrator.quoteVideo = { [weak self] _, _, _, _ in self?.quotes += 1; return 0.15 }
            h.editor.productionOrchestrator.validateVideo = { _, _, _ in .pass }
            h.editor.productionOrchestrator.digestVideo = { $0.id }
            h.editor.productionOrchestrator.generateVideo = { [weak self] input in
                guard let self else { return nil }
                let asset = self.h.addAsset(duration: 5, hasAudio: true)
                asset.generationInput = input
                asset.generationInput?.backendJobId = "backend-\(self.requests.count)"
                asset.generationInput?.queueId = "queue-\(self.requests.count)"
                asset.generationStatus = .generating
                self.h.editor.recordProductionJobMetadata(asset)
                return await withCheckedContinuation { self.requests.append((asset, $0)) }
            }
        }

        func start(autoQA: Bool = false, retries: Int = 0) {
            #expect(h.editor.productionOrchestrator.produceShots(ids: ["shot"], options: .init(autoQA: autoQA, maxRetries: retries, retryBaseDelay: 0)))
        }

        func finish(_ index: Int, success: Bool = true) {
            guard requests.indices.contains(index), let continuation = requests[index].continuation else { return }
            requests[index].continuation = nil
            requests[index].asset.generationStatus = success ? .none : .failed("Fixture failure")
            h.editor.recordProductionJobMetadata(requests[index].asset)
            continuation.resume(returning: success ? requests[index].asset : nil)
        }

        func stop() {
            h.editor.productionOrchestrator.cancel()
            for index in requests.indices { finish(index, success: false) }
        }
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<10_000 {
            if predicate() { return }
            await Task.yield()
        }
        try #require(predicate(), "Operation did not reach the expected stage")
    }

    @Test func operationAndStableTakeIdExistBeforeProviderWait() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        let before = try #require(driver.checkpoints.last?.productionOperations.first)
        #expect(before.stage == .generating)
        #expect(before.attempts.count == 1)
        #expect(before.destinations.map(\.shotId) == ["shot"])
        let input = try #require(driver.requests[0].asset.generationInput)
        #expect(input.productionAttemptId == before.attempts[0].id)
        #expect(input.productionOperationId == before.id)
        driver.finish(0)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        let operation = try #require(driver.h.editor.productionOperation(id: before.id))
        #expect(operation.stage == .placed)
        #expect(operation.attempts[0].queueId == "queue-0")
        #expect(driver.h.editor.shot(id: "shot")?.takes.first?.id == before.attempts[0].takeIds["shot"])
        let json = try #require(try await driver.h.runOK("production_status") as? [String: Any])
        #expect(json["operationCount"] as? Int == 1)
        let summaries = try #require(json["operations"] as? [[String: Any]])
        #expect(summaries[0]["stage"] as? String == "placed")
        #expect(summaries[0]["queueId"] as? String == "queue-0")
        #expect(summaries[0]["recipe"] == nil)
    }

    @Test func oldCompletionAfterCancelAndRestartCannotPlaceOrChangeCounters() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        let oldId = try #require(driver.requests[0].asset.generationInput?.productionOperationId)
        driver.h.editor.productionOrchestrator.cancel()
        driver.start()
        try await waitFor { driver.requests.count == 2 }
        driver.finish(1)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        let timeline = driver.h.editor.timeline
        let shot = driver.h.editor.shot(id: "shot")
        driver.finish(0)
        for _ in 0..<100 { await Task.yield() }
        #expect(driver.h.editor.timeline == timeline)
        #expect(driver.h.editor.shot(id: "shot") == shot)
        #expect(driver.h.editor.productionOperation(id: oldId)?.stage == .cancelled)
        #expect(driver.h.editor.productionOrchestrator.completedCount == 1)
        #expect(driver.h.editor.productionOrchestrator.runningUSD == 0.15)
        #expect(shot?.takes.count == 1)
    }

    @Test func editedShotDuringCheckpointNeverReachesQuoteOrProvider() async throws {
        let driver = try Driver()
        var gate: CheckedContinuation<Void, Never>?
        driver.h.editor.persistProductionState = { await withCheckedContinuation { gate = $0 } }
        defer { gate?.resume(); driver.stop() }
        driver.start()
        try await waitFor { gate != nil }
        driver.h.editor.mutateShotPlan(actionName: "Manual edit") { $0.shots[0].prompt = "A cyclist turns left." }
        gate?.resume()
        gate = nil
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        #expect(driver.quotes == 0)
        #expect(driver.requests.isEmpty)
        #expect(driver.h.editor.mediaManifest.productionOperations.first?.stage == .failed)
        #expect(driver.h.editor.shot(id: "shot")?.prompt == "A cyclist turns left.")
    }

    @Test func lateValidationAfterRestartCannotRecordAnOldTake() async throws {
        let driver = try Driver()
        var gate: CheckedContinuation<OutputValidator.Result, Never>?
        var calls = 0
        driver.h.editor.productionOrchestrator.validateVideo = { _, _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { gate = $0 } }
            return .pass
        }
        defer { gate?.resume(returning: .pass); driver.stop() }
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        driver.finish(0)
        try await waitFor { gate != nil }
        driver.h.editor.productionOrchestrator.cancel()
        driver.start()
        try await waitFor { driver.requests.count == 2 }
        driver.finish(1)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        gate?.resume(returning: .pass)
        gate = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(driver.h.editor.shot(id: "shot")?.takes.map(\.videoAssetId) == [driver.requests[1].asset.id])
        #expect(driver.h.editor.shot(id: "shot")?.placement?.assetId == driver.requests[1].asset.id)
    }

    @Test func lateQAAfterRestartCannotOverwriteNewReview() async throws {
        let driver = try Driver()
        var gate: CheckedContinuation<VisionQA.Result?, Never>?
        var calls = 0
        driver.h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { gate = $0 } }
            return .init(score: 1, pass: true, issues: [], summary: "Current take")
        }
        defer { gate?.resume(returning: nil); driver.stop() }
        driver.start(autoQA: true)
        try await waitFor { driver.requests.count == 1 }
        driver.finish(0)
        try await waitFor { gate != nil }
        driver.h.editor.productionOrchestrator.cancel()
        driver.start(autoQA: true)
        try await waitFor { driver.requests.count == 2 }
        driver.finish(1)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        gate?.resume(returning: .init(score: 0, pass: false, issues: ["Old result"], summary: "Old take"))
        gate = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(driver.h.editor.shot(id: "shot")?.qaSummary == "Current take")
        #expect(driver.h.editor.shot(id: "shot")?.placement?.assetId == driver.requests[1].asset.id)
    }

    @Test(arguments: [false, true])
    func failedOrUnavailableQADoesNotPlaceAtRetryLimit(unavailable: Bool) async throws {
        let driver = try Driver()
        defer { driver.stop() }
        driver.h.editor.productionOrchestrator.evaluateVideoQA = { _, _, _, _ in
            unavailable ? nil : .init(score: 0, pass: false, issues: ["Wrong character"], summary: "Wrong character")
        }
        driver.start(autoQA: true)
        try await waitFor { driver.requests.count == 1 }
        driver.finish(0)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        #expect(driver.h.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(driver.h.editor.mediaManifest.productionOperations.first?.stage == .failed)
        #expect(driver.h.editor.shot(id: "shot")?.takes.count == 1)
        #expect(driver.requests.count == 1)
    }

    @Test func retriesHaveDistinctPersistedAttemptAndTakeIds() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        driver.start(retries: 1)
        try await waitFor { driver.requests.count == 1 }
        driver.finish(0, success: false)
        try await waitFor { driver.requests.count == 2 }
        let attempts = try #require(driver.h.editor.mediaManifest.productionOperations.first?.attempts)
        #expect(attempts.count == 2)
        #expect(attempts[0].id != attempts[1].id)
        #expect(attempts[0].takeIds["shot"] != attempts[1].takeIds["shot"])
        #expect(attempts[0].failureReason != nil)
        #expect(driver.checkpoints.last?.productionOperations.first?.attempts.count == 2)
        #expect(throws: ToolError.self) { try driver.h.editor.validateProductionAttempt(attempts[0].recipe) }
        driver.finish(1)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        #expect(driver.h.editor.shot(id: "shot")?.takes.first?.id == attempts[1].takeIds["shot"])
    }

    @Test func serviceCheckpointsPlaceholderBeforeReferencePreparation() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        let o = driver.h.editor.productionOrchestrator
        o.executeUnit = { _, _ in }
        driver.start()
        o.pause()
        let operationId = try driver.h.editor.beginProductionOperation(shotIds: ["shot"], runId: o.currentRunId, autoQA: false)
        let input = try driver.h.editor.beginProductionAttempt(operationId: operationId, recipe: .init(prompt: "A car drives.", model: driver.model.id, duration: 5, aspectRatio: "16:9", resolution: "768P"))
        var persisted: MediaManifest?
        driver.h.editor.persistProductionState = {
            persisted = driver.h.editor.mediaManifest
            throw ToolError("Fixture checkpoint failure")
        }
        let service = GenerationService()
        var failed = false
        let placeholderId = VideoGenerationSubmission.make(genInput: input, model: driver.model, placeholderDuration: 5, generateAudio: true)
            .submit(service: service, projectURL: nil, editor: driver.h.editor, onFailure: { failed = true })
        try await waitFor { failed }
        #expect(persisted?.productionOperations.last?.attempts.last?.placeholderId == placeholderId)
        #expect(persisted?.entries.contains { $0.id == placeholderId } == true)
        #expect(driver.h.editor.mediaAssets.first { $0.id == placeholderId }?.generationInput?.backendJobId == nil)
        #expect(driver.h.editor.productionOperation(id: operationId)?.attempts.last?.failureReason?.contains("checkpoint failure") == true)
        failed = false
        let replayId = VideoGenerationSubmission.make(genInput: input, model: driver.model, placeholderDuration: 5, generateAudio: true)
            .submit(service: service, projectURL: nil, editor: driver.h.editor, onFailure: { failed = true })
        try await waitFor { failed }
        #expect(replayId != placeholderId)
        #expect(driver.h.editor.productionOperation(id: operationId)?.attempts.last?.placeholderId == placeholderId)
        #expect(driver.h.editor.mediaAssets.first { $0.id == replayId }?.generationInput?.backendJobId == nil)
    }

    @Test func interruptedPackageRetainsOperationWithoutRebuyingOrAutoPlacing() async throws {
        let driver = try Driver()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("operation-\(UUID()).venice")
        defer { driver.stop(); try? FileManager.default.removeItem(at: url) }
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        driver.h.editor.productionOrchestrator.detachAll()
        let manifest = driver.h.editor.mediaManifest
        try VideoProject.writeProjectPackage(.init(timeline: JSONEncoder().encode(driver.h.editor.timeline), manifest: JSONEncoder().encode(manifest), generationLog: nil, thumbnail: nil, chatSessionFiles: []), to: url, sourceURL: nil)
        let package = try VideoProject.readProjectPackage(at: url)
        let reopened = ToolHarness(timeline: package.timeline)
        reopened.editor.mediaManifest = try #require(package.manifest)
        reopened.editor.productionOrchestrator.resume(editor: reopened.editor)
        #expect(reopened.editor.mediaManifest.productionOperations == manifest.productionOperations)
        #expect(reopened.editor.mediaManifest.productionOperations.first?.stage == .interrupted)
        #expect(reopened.editor.timeline.tracks.flatMap(\.clips).isEmpty)
        #expect(reopened.editor.shot(id: "shot")?.status == .failed)
        #expect(try JSONDecoder().decode(MediaManifest.self, from: Data("{}".utf8)).productionOperations.isEmpty)
    }

    @Test func checkpointFailureAfterCancellationDoesNotRewriteCancellation() async throws {
        let driver = try Driver()
        var gate: CheckedContinuation<Void, Error>?
        driver.h.editor.persistProductionState = { try await withCheckedThrowingContinuation { gate = $0 } }
        defer { gate?.resume(throwing: ToolError("Fixture closed")); driver.stop() }
        driver.start()
        try await waitFor { gate != nil }
        driver.h.editor.productionOrchestrator.cancel()
        gate?.resume(throwing: ToolError("Fixture checkpoint failure"))
        gate = nil
        for _ in 0..<100 { await Task.yield() }
        #expect(driver.h.editor.mediaManifest.productionOperations.first?.stage == .cancelled)
        #expect(driver.quotes == 0)
        #expect(driver.requests.isEmpty)
    }

    @Test func mediaLibraryUndoKeepsAttemptLedgerAndInvalidatesOldDestination() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        let snapshot = driver.h.editor.mediaLibraryUndoSnapshot()
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        let operations = driver.h.editor.mediaManifest.productionOperations
        let input = try #require(driver.requests[0].asset.generationInput)
        driver.h.editor.restoreMediaLibraryUndoSnapshot(snapshot, actionName: "Fixture undo")
        #expect(driver.h.editor.mediaManifest.productionOperations == operations)
        #expect(throws: ToolError.self) { try driver.h.editor.validateProductionAttempt(input) }
        driver.finish(0)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        #expect(driver.h.editor.timeline == snapshot.timeline)
        #expect(driver.h.editor.shotPlan == snapshot.mediaManifest.shotPlan)
    }

    @Test func liveFinalCheckpointFailureIsNotCountedAsSuccess() async throws {
        let driver = try Driver()
        defer { driver.stop() }
        var saves = 0
        driver.h.editor.persistProductionState = {
            saves += 1
            if saves == 4 { throw ToolError("Fixture final checkpoint failed") }
        }
        driver.start()
        try await waitFor { driver.requests.count == 1 }
        driver.finish(0)
        try await waitFor { !driver.h.editor.productionOrchestrator.isRunning }
        #expect(driver.h.editor.productionOrchestrator.completedCount == 0)
        #expect(driver.h.editor.productionOrchestrator.failedCount == 1)
        #expect(driver.h.editor.mediaManifest.productionOperations.first?.stage == .placed)
        #expect(driver.h.editor.mediaManifest.productionOperations.first?.failureReason == "Fixture final checkpoint failed")
    }
}
