import AppKit
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Production lane selection", .serialized)
@MainActor
struct ProductionRoutingTests {
    @Test func explicitI2VUsesPanelDespiteReferenceStack() throws {
        let h = ToolHarness()
        let frame = h.addAsset(type: .image)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"))
        #expect(NSImage(data: png) != nil)
        try png.write(to: frame.url)
        h.editor.mediaManifest.entries.append(MediaManifestEntry(
            id: frame.id, name: frame.name, type: .image,
            source: .external(absolutePath: frame.url.path), duration: 0
        ))
        defer { try? FileManager.default.removeItem(at: frame.url) }
        let i2v = try MiniMaxRequestTests.model("minimax-h3-max-turbo-image-to-video")
        let r2v = try MiniMaxRequestTests.model("minimax-h3-max-reference-to-video")
        let shot = Shot(modelOverride: i2v.id, storyboardAssetId: frame.id)
        let route = try h.editor.productionOrchestrator.route(shot, plan: ShotPlan(), editor: h.editor, availableModels: [r2v, i2v])
        #expect(route.model.id == i2v.id)
        #expect(route.inputAssets.frames.map(\.id) == [frame.id])
        #expect(route.inputAssets.imageRefs.isEmpty)
        #expect(i2v.validate(duration: 5, aspectRatio: "16:9", resolution: "768P") == nil)
        var automatic = shot
        automatic.modelOverride = nil
        let autoRoute = try h.editor.productionOrchestrator.route(automatic, plan: ShotPlan(), editor: h.editor, availableModels: [r2v, i2v])
        #expect(autoRoute.model.id == i2v.id)
        let t2v = try MiniMaxRequestTests.model("minimax-h3-max-text-to-video")
        automatic.modelOverride = t2v.id
        #expect(throws: ToolError.self) {
            try h.editor.productionOrchestrator.route(automatic, plan: ShotPlan(), editor: h.editor, availableModels: [t2v, i2v])
        }
    }

    @Test func missingOrIncompatibleExplicitModelNeverFallsBack() throws {
        let h = ToolHarness()
        let t2v = try MiniMaxRequestTests.model("minimax-h3-max-text-to-video")
        let i2v = try MiniMaxRequestTests.model("minimax-h3-max-image-to-video")
        for id in ["unknown", "minimax-h3-max-turbo-reference-to-video", i2v.id] {
            #expect(throws: ToolError.self) {
                try h.editor.productionOrchestrator.route(Shot(modelOverride: id), plan: ShotPlan(), editor: h.editor, availableModels: [t2v, i2v])
            }
        }
        #expect(throws: ToolError.self) {
            try h.editor.productionOrchestrator.route(Shot(), plan: ShotPlan(defaultModel: "disabled"), editor: h.editor, availableModels: [t2v])
        }
    }

    @Test func cameraToolEditRoundTripsAndUndoes() async throws {
        let h = ToolHarness()
        let shot = Shot(modelOverride: VideoModelCapabilities.multiAngleID)
        h.editor.upsertShot(shot)
        let undo = UndoManager()
        h.editor.undoManager = undo
        let frames: [[String: Any]] = [
            ["time": 0, "azimuth": 0, "elevation": 0, "distance": 1],
            ["time": 0.5, "azimuth": 30, "elevation": 5, "distance": 0.8],
            ["time": 1, "azimuth": 90, "elevation": 10, "distance": 1.2],
        ]
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": shot.id, "cameraTrajectory": frames]]])
        let move = try #require(h.editor.shotPlan?.shots[0].cameraTrajectory)
        #expect(move.keyframes.count == 3)
        #expect(ToolExecutor.videoPromptIssue(try #require(h.editor.shotPlan?.shots[0])) == nil)
        let encoded = try JSONEncoder().encode(try #require(h.editor.shotPlan))
        #expect(try JSONDecoder().decode(ShotPlan.self, from: encoded).shots[0].cameraTrajectory == move)
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": shot.id, "cameraTrajectory": NSNull()]]])
        #expect(h.editor.shotPlan?.shots[0].cameraTrajectory == nil)
        let result = await h.runRaw("undo")
        #expect(!result.isError)
        #expect(h.editor.shotPlan?.shots[0].cameraTrajectory == move)
    }

    @Test func cameraUndoRefusesInterveningManualPlanEdit() async throws {
        let h = ToolHarness()
        let shot = Shot(modelOverride: VideoModelCapabilities.multiAngleID, cameraTrajectory: .stationary)
        h.editor.upsertShot(shot)
        let undo = UndoManager()
        h.editor.undoManager = undo
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": shot.id, "cameraTrajectory": NSNull()]]])
        h.editor.mutateShotPlan(actionName: "Update Shots") { $0.shots[0].summary = "Manual correction" }
        #expect(await h.runRaw("undo").isError)
        #expect(h.editor.shotPlan?.shots[0].summary == "Manual correction")
        #expect(h.editor.shotPlan?.shots[0].cameraTrajectory == nil)
    }

    @Test func malformedCameraToolValuesLeavePlanIntact() async {
        let h = ToolHarness()
        let shot = Shot(modelOverride: VideoModelCapabilities.multiAngleID, cameraTrajectory: .stationary)
        h.editor.upsertShot(shot)
        let original = h.editor.shotPlan
        let values: [Any] = ["invalid", 42, ["keyframes": [Any]()], [Any]()]
        for value in values {
            let result = await h.runRaw("update_shots", args: ["operations": [["action": "update", "id": shot.id, "cameraTrajectory": value]]])
            #expect(result.isError)
            #expect(h.editor.shotPlan == original)
        }
    }
}
