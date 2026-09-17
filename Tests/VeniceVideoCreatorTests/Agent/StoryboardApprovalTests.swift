import AppKit
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Revision-bound storyboard approval")
@MainActor
struct StoryboardApprovalTests {
    private func harness() throws -> ToolHarness {
        let h = ToolHarness()
        let panel = h.addAsset(type: .image)
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4//8/AAX+Av4N70a4AAAAAElFTkSuQmCC"))
        try png.write(to: panel.url)
        h.editor.mediaManifest.entries.append(MediaManifestEntry(id: panel.id, name: panel.name, type: .image, source: .external(absolutePath: panel.url.path), duration: 0))
        h.editor.upsertShot(Shot(id: "shot", modelOverride: VideoModelCapabilities.multiAngleID, cameraTrajectory: .stationary, storyboardAssetId: panel.id))
        return h
    }

    private func clean(_ h: ToolHarness) {
        for asset in h.editor.mediaAssets { try? FileManager.default.removeItem(at: asset.url) }
    }

    private func approval(_ h: ToolHarness) throws -> StoryboardRevision? {
        let plan = try #require(h.editor.shotPlan)
        return try h.editor.requireApprovedStoryboard(for: plan.shots[0], plan: plan)
    }

    @Test func legacyStatusAndReadyBytesDoNotApprovePanel() throws {
        let h = try harness()
        defer { clean(h) }
        h.editor.setShotStatus(id: "shot", .approved)
        #expect(throws: ToolError.self) { try approval(h) }
        h.editor.productionOrchestrator.executeUnit = { _, _ in Issue.record("Unapproved storyboard must block production") }
        #expect(!h.editor.productionOrchestrator.produceShots(ids: ["shot"]))
        let model = try MiniMaxRequestTests.model(VideoModelCapabilities.multiAngleID)
        #expect(throws: ToolError.self) {
            try h.editor.productionOrchestrator.route(h.editor.shotPlan!.shots[0], plan: h.editor.shotPlan!, editor: h.editor, availableModels: [model])
        }
    }

    @Test func cameraEditInvalidatesApprovalAndUndoRestoresIt() async throws {
        let h = try harness()
        defer { clean(h) }
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": "shot", "approveStoryboard": true, "approvalReason": "Composition reviewed"]]])
        let revision = try #require(try approval(h))
        let undo = UndoManager()
        h.editor.undoManager = undo
        h.editor.mutateShotPlan(actionName: "Edit Camera Move") { $0.shots[0].cameraTrajectory?.keyframes[1].azimuth = 90 }
        #expect(h.editor.shotPlan?.shots[0].panelReview == nil)
        #expect(throws: ToolError.self) { try approval(h) }
        #expect(throws: ToolError.self) { try h.editor.validateStoryboardSubmission(.init(shotID: "shot", revision: revision)) }
        undo.undo()
        #expect(try approval(h) == revision)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: JSONEncoder().encode(h.editor.shotPlan!))
        #expect(decoded.shots[0].panelReview?.revision == revision)
        #expect(decoded.shots[0].cameraTrajectory == .stationary)
    }

    @Test func canonicalChangeInvalidatesOnlyDependentShot() throws {
        let h = try harness()
        defer { clean(h) }
        h.editor.mutateShotPlan(actionName: "Set Cast") { plan in
            plan.characters = [CharacterSpec(id: "a", name: "A"), CharacterSpec(id: "b", name: "B")]
            plan.shots[0].characterIds = ["a"]
            var second = Shot(id: "other", storyboardAssetId: plan.shots[0].storyboardAssetId)
            second.characterIds = ["b"]
            plan.shots.append(second)
        }
        try h.editor.approveStoryboard(shotID: "shot", reason: "A reviewed")
        try h.editor.approveStoryboard(shotID: "other", reason: "B reviewed")
        let otherReview = h.editor.shotPlan?.shots[1].panelReview
        h.editor.mutateShotPlan(actionName: "Change Canonical Reference") { $0.characters[0].lockedReferenceAssetId = "new-canonical" }
        #expect(h.editor.shotPlan?.shots[0].panelReview == nil)
        #expect(h.editor.shotPlan?.shots[1].panelReview == otherReview)
    }

    @Test func failedQARequiresExplicitReasonedOverride() async throws {
        let h = try harness()
        defer { clean(h) }
        h.executor.evaluateStoryboardQA = { images, _ in
            #expect(!images.isEmpty)
            return .init(score: 0.1, pass: false, issues: ["Wrong framing"], summary: "Failed")
        }
        let result = await h.runRaw("qa_shot", args: ["shotId": "shot", "artifact": "storyboard", "autoApprove": true])
        #expect(!result.isError)
        #expect(h.editor.shotPlan?.shots[0].panelReview?.verdict == .failed)
        #expect(throws: ToolError.self) { try approval(h) }
        #expect(throws: ToolError.self) { try h.editor.approveStoryboard(shotID: "shot", reason: " ") }
        try h.editor.approveStoryboard(shotID: "shot", reason: "Keep this framing for the comparison cut")
        #expect(try approval(h) != nil)
        #expect(h.editor.shotPlan?.shots[0].panelReview?.verdict == .failed)
    }

    @Test func QAOutageClearsAutomaticApprovalWithoutBuyingVideo() async throws {
        let h = try harness()
        defer { clean(h) }
        h.executor.evaluateStoryboardQA = { _, _ in .init(score: 1, pass: true, issues: [], summary: "Passed") }
        #expect(!(await h.runRaw("qa_shot", args: ["shotId": "shot", "artifact": "storyboard", "autoApprove": true])).isError)
        #expect(try approval(h) != nil)
        h.executor.evaluateStoryboardQA = { _, _ in throw ToolError("Fixture outage") }
        #expect((await h.runRaw("qa_shot", args: ["shotId": "shot", "artifact": "storyboard", "autoApprove": true])).isError)
        #expect(h.editor.shotPlan?.shots[0].panelReview?.verdict == .error)
        #expect(throws: ToolError.self) { try approval(h) }
        #expect(h.editor.mediaAssets.count == 1)
    }

    @Test func staleQAResponseCannotApproveNewPrompt() async throws {
        let h = try harness()
        defer { clean(h) }
        h.executor.evaluateStoryboardQA = { _, _ in
            h.editor.mutateShotPlan(actionName: "Manual Correction") { $0.shots[0].prompt = "New composition" }
            return .init(score: 1, pass: true, issues: [], summary: "Old panel passed")
        }
        let result = await h.runRaw("qa_shot", args: ["shotId": "shot", "artifact": "storyboard", "autoApprove": true])
        #expect(result.isError)
        #expect(ToolHarness.textOf(result).contains("changed during QA"))
        #expect(h.editor.shotPlan?.shots[0].panelReview == nil)
        #expect(throws: ToolError.self) { try approval(h) }
    }

    @Test func changedPanelBytesInvalidateSameAssetID() throws {
        let h = try harness()
        defer { clean(h) }
        try h.editor.approveStoryboard(shotID: "shot", reason: "Image reviewed")
        let panel = try #require(h.editor.mediaAssets.first)
        var data = try Data(contentsOf: panel.url)
        data.append(Data("revision".utf8))
        try data.write(to: panel.url)
        #expect(NSImage(data: data) != nil)
        #expect(throws: ToolError.self) { try approval(h) }
    }

    @Test func panelReplacementClearsReviewAndUndoRestoresRevision() throws {
        let h = try harness()
        defer { clean(h) }
        try h.editor.approveStoryboard(shotID: "shot", reason: "Original panel reviewed")
        let original = try approval(h)
        let undo = UndoManager()
        h.editor.undoManager = undo
        h.editor.mutateShotPlan(actionName: "Fix Panel") { $0.shots[0].storyboardAssetId = "pending-replacement" }
        #expect(h.editor.shotPlan?.shots[0].panelReview == nil)
        #expect(h.editor.shotPlan?.shots[0].qaSummary == nil)
        #expect(h.editor.shotPlan?.shots[0].status == .storyboarded)
        #expect(throws: ToolError.self) { try approval(h) }
        undo.undo()
        #expect(try approval(h) == original)
    }

    @Test func finalRunnerHonorsSubmissionGuardBeforeProviderAccess() async {
        let params = VideoGenerationParams(prompt: "", duration: 5, aspectRatio: "16:9", resolution: "768P", startFrameURL: "fixture", cameraTrajectory: .stationary)
        var checked = false
        await #expect(throws: ToolError.self) {
            try await VeniceGenerationRunner.run(model: VideoModelCapabilities.multiAngleID, params: .video(params), api: VeniceAPI(apiKey: "unused-fixture"), validateSubmission: {
                checked = true
                throw ToolError("Stale fixture revision")
            })
        }
        #expect(checked)
    }
}
