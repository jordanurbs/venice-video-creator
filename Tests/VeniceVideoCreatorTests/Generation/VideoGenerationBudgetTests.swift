import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("1080P generation spending gate")
@MainActor
struct VideoGenerationBudgetTests {
    private let model = VideoModelCapabilities.multiAngleID
    private var params: VideoGenerationParams {
        .init(prompt: "", duration: 5, aspectRatio: "16:9", resolution: "1080P", startFrameURL: "fixture", cameraTrajectory: .stationary)
    }

    @Test func rejectsMissingBudgetWithoutQuote() async {
        await #expect(throws: ToolError.self) {
            try await VideoGenerationBudget.authorize(model: model, params: params, budget: nil) {
                Issue.record("Missing budget must fail before quoting")
                return 1
            }
        }
    }

    @Test func invalidAndUnavailableQuotesDoNotReserve() async throws {
        let budget = try VideoGenerationBudget(maximumUSD: 2)
        for quote in [nil, Double.nan, .infinity, -1, 0, 3] {
            await #expect(throws: ToolError.self) {
                try await VideoGenerationBudget.authorize(model: model, params: params, budget: budget) { quote }
            }
            #expect(budget.reservedUSD == 0)
        }
        for cap in [Double.nan, .infinity, -1, 0] {
            #expect(throws: ToolError.self) { try VideoGenerationBudget(maximumUSD: cap) }
        }
    }

    @Test func concurrentAttemptsAndRetriesShareCapAndRefreshEveryQuote() async throws {
        let budget = try VideoGenerationBudget(maximumUSD: 1)
        var calls = 0
        func attempt() async -> Bool {
            do {
                try await VideoGenerationBudget.authorize(model: model, params: params, budget: budget) {
                    calls += 1
                    await Task.yield()
                    return 0.75
                }
                return true
            } catch { return false }
        }
        let a = Task { await attempt() }
        let b = Task { await attempt() }
        let results = await [a.value, b.value]
        #expect(results.filter { $0 }.count == 1)
        #expect(calls == 2)
        #expect(budget.reservedUSD == 0.75)
        #expect(await attempt() == false)
        #expect(calls == 3)
    }

    @Test func cancellationAfterQuoteDoesNotReserve() async throws {
        let budget = try VideoGenerationBudget(maximumUSD: 2)
        let task = Task {
            await #expect(throws: CancellationError.self) {
                try await VideoGenerationBudget.authorize(model: model, params: params, budget: budget) {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return 1
                }
            }
        }
        _ = await task.value
        #expect(budget.reservedUSD == 0)
    }

    @Test func lowerResolutionDoesNotRequireOrSpend1080Budget() async throws {
        let lower = VideoGenerationParams(prompt: "", duration: 5, aspectRatio: "16:9", resolution: "768P", startFrameURL: "fixture", cameraTrajectory: .stationary)
        try await VideoGenerationBudget.authorize(model: model, params: lower, budget: nil) {
            Issue.record("Lower resolution must not use the 1080P gate")
            return nil
        }
    }

    @Test func productionRequiresSeparateBudgetAndRefusesMidRunReplacement() throws {
        let editor = EditorViewModel()
        editor.saveShotPlan(ShotPlan(resolution: "1080P", defaultModel: model, shots: [Shot(id: "a"), Shot(id: "b")]))
        let production = editor.productionOrchestrator
        production.executeUnit = { _, _ in Issue.record("Paused or blocked production must not execute") }
        #expect(!production.produceShots(ids: ["a"]))
        #expect(!production.isRunning)
        #expect(production.lastError?.contains("spending cap") == true)
        let budget = try VideoGenerationBudget(maximumUSD: 1)
        #expect(production.produceShots(ids: ["a"], options: .init(videoBudget: budget)))
        production.pause()
        defer { production.cancel() }
        #expect(!production.produceShots(ids: ["b"], options: .init(videoBudget: budget)))
        #expect(production.totalCount == 1)
        #expect(budget.reservedUSD == 0)
    }

    @Test func omittedResolutionNeverUsesProvider1080Default() throws {
        let config = try MiniMaxRequestTests.model(model)
        let input = VideoGenerationParams(prompt: "", duration: 5, aspectRatio: "16:9", resolution: nil, startFrameURL: "fixture", cameraTrajectory: .stationary)
        let body = try VeniceGenerationRunner.videoRequestBody(model: model, params: input, catalogModel: config)
        #expect(body["resolution"] as? String == "768P")
        let catalog = VeniceModelMapper.map([["id": model, "type": "video", "model_spec": ["constraints": ["resolutions": ["1080P"], "durations": ["5s"]]]]])
        let entry = try #require(catalog.entries.first)
        guard case .video(let caps) = entry.uiCapabilities else { Issue.record("Expected video"); return }
        let only1080 = VideoModelConfig(entry: entry, caps: caps)
        #expect(only1080.automaticResolution == nil)
        #expect(only1080.validate(duration: 5, aspectRatio: "16:9", resolution: nil) != nil)
        #expect(throws: ToolError.self) {
            try VeniceGenerationRunner.videoRequestBody(model: model, params: input, catalogModel: only1080)
        }
    }

    @Test func serviceRejectsUnbudgetedRerunBeforeReferencePreparation() async throws {
        let catalog = ModelCatalog(load: { VeniceModelMapper.map([["id": VideoModelCapabilities.multiAngleID, "type": "video", "model_spec": ["constraints": ["resolutions": ["768P", "1080P"], "durations": ["5s"]]]]]) })
        await catalog.reload().value
        let service = GenerationService(catalog: catalog)
        let editor = EditorViewModel()
        let frame = MediaAsset(url: URL(fileURLWithPath: "/missing-fixture.png"), type: .image, name: "Fixture")
        var completed = false
        let id = service.generate(
            genInput: .init(prompt: "", model: model, duration: 5, aspectRatio: "16:9", resolution: "1080P", cameraTrajectory: .stationary),
            assetType: .video, placeholderDuration: 5, references: [frame],
            buildParams: { _ in .video(params) },
            preprocessRef: { _, _ in Issue.record("Unbudgeted rerun must not prepare references"); return nil },
            fileExtension: "mp4", projectURL: nil, editor: editor,
            onFailure: { completed = true }
        )
        for _ in 0..<1000 where !completed { await Task.yield() }
        #expect(completed)
        let asset = try #require(editor.mediaAssets.first { $0.id == id })
        guard case .failed(let reason) = asset.generationStatus else { Issue.record("Expected blocked generation"); return }
        #expect(reason.contains("spending cap"))
        #expect(service.preSubmitGenerationCount == 0)
        #expect(asset.generationInput?.backendJobId == nil)
    }
}
