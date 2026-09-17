import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Catalog refresh and video selection")
@MainActor
struct ModelCatalogRaceTests {
    @MainActor private final class Loader {
        var waits: [CheckedContinuation<VeniceCatalog?, Error>] = []

        func load() async throws -> VeniceCatalog? {
            try await withCheckedThrowingContinuation { waits.append($0) }
        }
    }

    @Test func supersededFailureCannotOverwriteSuccessfulReload() async throws {
        let loader = Loader()
        let catalog = ModelCatalog(load: { try await loader.load() })
        let first = catalog.reload()
        for _ in 0..<1000 where loader.waits.count < 1 { await Task.yield() }
        try #require(loader.waits.count == 1)
        let second = catalog.reload()
        for _ in 0..<1000 where loader.waits.count < 2 { await Task.yield() }
        try #require(loader.waits.count == 2)
        let latest = VeniceModelMapper.map([["id": VideoModelCapabilities.multiAngleID, "type": "video"]])
        loader.waits[1].resume(returning: latest)
        await second.value
        loader.waits[0].resume(throwing: ToolError("Old key failed"))
        await first.value
        #expect(catalog.isLoaded)
        #expect(catalog.lastError == nil)
        #expect(catalog.video.map(\.id) == [VideoModelCapabilities.multiAngleID])
    }

    @Test func supersededSuccessCannotRestoreRemovedModels() async throws {
        let loader = Loader()
        let catalog = ModelCatalog(load: { try await loader.load() })
        let first = catalog.reload()
        for _ in 0..<1000 where loader.waits.count < 1 { await Task.yield() }
        try #require(loader.waits.count == 1)
        let second = catalog.reload()
        for _ in 0..<1000 where loader.waits.count < 2 { await Task.yield() }
        try #require(loader.waits.count == 2)
        loader.waits[1].resume(returning: nil)
        await second.value
        loader.waits[0].resume(returning: VeniceModelMapper.map([["id": "old-model", "type": "video"]]))
        await first.value
        #expect(!catalog.isLoaded)
        #expect(catalog.video.isEmpty)
        #expect(catalog.byId.isEmpty)
    }

    @Test func removingKeyClearsPreviouslyLoadedCatalog() async {
        var response: VeniceCatalog? = VeniceModelMapper.map([["id": "fixture-video", "type": "video"]])
        let catalog = ModelCatalog(load: { response })
        await catalog.reload().value
        #expect(catalog.isLoaded)
        response = nil
        let task = catalog.reload()
        #expect(!catalog.isLoaded)
        await task.value
        #expect(catalog.video.isEmpty)
        #expect(catalog.byId.isEmpty)
    }

    @Test func modelSelectionSurvivesReorderAndRefusesMissingSelection() throws {
        let multi = try MiniMaxRequestTests.model(VideoModelCapabilities.multiAngleID)
        let turbo = try MiniMaxRequestTests.model("minimax-h3-max-turbo-image-to-video")
        let selection = VideoModelSelection(selected: multi)
        #expect(selection.resolve(in: [turbo, multi])?.id == multi.id)
        #expect(selection.resolve(in: [turbo])?.id == multi.id)
        #expect(selection.validationError(in: [turbo], isLoaded: true) != nil)
        #expect(selection.validationError(in: [multi], isLoaded: false) != nil)
        #expect(selection.resolve(in: [])?.id == multi.id)
        #expect(selection.resolve(in: [multi, turbo])?.automaticResolution == "768P")
        #expect(VideoModelCapabilities.automaticResolution(id: multi.id, allowed: ["1080P", "480P"]) == "480P")
        #expect(VideoModelCapabilities.automaticResolution(id: multi.id, allowed: ["1080P"]) == nil)
    }
}
