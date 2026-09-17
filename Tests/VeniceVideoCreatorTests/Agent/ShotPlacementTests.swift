import AppKit
import AVFoundation
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Durable shot placements")
@MainActor
struct ShotPlacementTests {
    private func grouped(order: [Int] = [0, 1, 2]) throws -> (ToolHarness, MediaAsset, [ShotPlacement]) {
        let h = ToolHarness()
        let asset = h.addAsset(duration: 15, hasAudio: true)
        var shots: [Shot] = []
        for i in 0..<3 {
            var take = ShotTake(id: "take-\(i)", videoAssetId: asset.id)
            take.productionUnitId = "unit-1"
            take.sourceRange = .init(startSeconds: Double(i * 5), endSeconds: Double((i + 1) * 5))
            shots.append(Shot(id: "shot-\(i)", takes: [take]))
        }
        h.editor.saveShotPlan(ShotPlan(shots: shots))
        for i in order {
            try h.editor.placeProductionShot(asset: asset, shotId: shots[i].id,
                                             sourceSegment: Double(i * 5)...Double((i + 1) * 5))
        }
        return (h, asset, try h.editor.shotPlan!.shots.map { try #require($0.placement) })
    }

    @Test func sharedAssetMiddleResetRemovesOnlyItsPairAndUndoes() async throws {
        let (h, _, bindings) = try grouped()
        let before = h.editor.timeline
        let plan = h.editor.shotPlan
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        _ = try await h.runOK("reset_shots", args: ["shotIds": ["shot-1"]])
        let removed = Set([bindings[1].videoClipId] + bindings[1].linkedAudioClipIds)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).allSatisfy { !removed.contains($0.id) })
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 4)
        #expect(h.editor.shot(id: "shot-1")?.placement == nil)
        for i in [0, 2] {
            #expect(h.editor.clipFor(id: bindings[i].videoClipId) == before.tracks.flatMap(\.clips).first { $0.id == bindings[i].videoClipId })
        }
        undo.undo()
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == plan)
        undo.redo()
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 4)
        #expect(h.editor.shot(id: "shot-1")?.placement == nil)
    }

    @Test func middleRetakePreservesManualEditsAndNeighborSources() throws {
        let (h, asset, bindings) = try grouped()
        let middle = bindings[1]
        let ids = [middle.videoClipId] + middle.linkedAudioClipIds
        for id in ids {
            h.editor.commitClipProperty(clipId: id) {
                $0.trimStartFrame += 15
                $0.durationFrames -= 15
                $0.volume = 0.42
                $0.fadeInFrames = 8
            }
        }
        let replacement = h.addAsset(duration: 5, hasAudio: true)
        h.editor.mutateShotPlan(actionName: "Fixture take") {
            $0.shots[1].takes.append(ShotTake(id: "retake", videoAssetId: replacement.id))
        }
        let before = h.editor.timeline
        let beforePlan = h.editor.shotPlan
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        let placed = try h.editor.placeProductionShot(asset: replacement, shotId: "shot-1")
        #expect(placed.videoClipId == middle.videoClipId)
        #expect(placed.linkedAudioClipIds == middle.linkedAudioClipIds)
        #expect(placed.takeId == "retake")
        #expect(placed.productionUnitId == nil)
        for id in ids {
            let clip = try #require(h.editor.clipFor(id: id))
            #expect(clip.mediaRef == replacement.id)
            #expect(clip.startFrame == 150)
            #expect(clip.trimStartFrame == 15)
            #expect(clip.durationFrames == 135)
            #expect(clip.volume == 0.42)
            #expect(clip.fadeInFrames == 8)
        }
        for i in [0, 2] { #expect(h.editor.clipFor(id: bindings[i].videoClipId)?.mediaRef == asset.id) }
        let after = h.editor.timeline
        undo.undo()
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == beforePlan)
        undo.redo()
        #expect(h.editor.timeline == after)
        #expect(h.editor.shot(id: "shot-1")?.placement == placed)
    }

    @Test func reversedCompletionReordersExactBeatsWithTheirAudio() throws {
        let (h, _, bindings) = try grouped(order: [2, 0, 1])
        let before = h.editor.timeline
        let undo = UndoManager()
        h.editor.undoManager = undo
        h.editor.reorderProductionClipsToPlanOrder()
        for i in 0..<3 {
            for id in [bindings[i].videoClipId] + bindings[i].linkedAudioClipIds {
                #expect(h.editor.clipFor(id: id)?.startFrame == i * 150)
                #expect(h.editor.clipFor(id: id)?.trimStartFrame == i * 150)
            }
            let shot = try #require(h.editor.shot(id: "shot-\(i)"))
            #expect(try h.executor.shotStartFrame(shot, editor: h.editor) == i * 150)
        }
        undo.undo()
        #expect(h.editor.timeline == before)
    }

    @Test func ambiguousLegacyBindingsFailAtomicallyAndCanBeExplicitlyRepaired() async throws {
        let (h, _, bindings) = try grouped()
        h.editor.mutateShotPlan(actionName: "Legacy fixture") { plan in
            for i in plan.shots.indices { plan.shots[i].placement = nil }
        }
        let before = h.editor.timeline
        let plan = h.editor.shotPlan
        #expect(await h.runRaw("reset_shots").isError)
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == plan)
        #expect(throws: ToolError.self) { try h.executor.shotStartFrame(plan!.shots[1], editor: h.editor) }
        h.editor.reconcileLegacyProductionPlacements()
        #expect(h.editor.shotPlan == plan)
        let shortId = try #require(ToolExecutor.shortIdMap(h.executor.currentIdUniverse(h.editor))[bindings[1].videoClipId])
        _ = try await h.runOK("update_shots", args: ["operations": [
            ["action": "update", "id": "shot-1", "placedClipId": shortId]
        ]])
        #expect(try h.executor.shotStartFrame(h.editor.shot(id: "shot-1")!, editor: h.editor) == 150)
        let duplicate = await h.runRaw("update_shots", args: ["operations": [
            ["action": "update", "id": "shot-0", "placedClipId": bindings[1].videoClipId]
        ]])
        #expect(duplicate.isError)
        _ = try await h.runOK("reset_shots", args: ["shotIds": ["shot-1"]])
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 4)
        #expect(h.editor.clipFor(id: bindings[0].videoClipId) != nil)
        #expect(h.editor.clipFor(id: bindings[2].videoClipId) != nil)
    }

    @Test func automaticReorderDoesNotOverlapAnExistingAudioEdit() throws {
        let (h, _, bindings) = try grouped(order: [2, 0, 1])
        let audioId = try #require(bindings[0].linkedAudioClipIds.first)
        let audio = try #require(h.editor.clipFor(id: audioId))
        h.editor.removeClips(ids: [audioId], prune: false)
        h.editor.timeline.tracks.append(Fixtures.audioTrack(clips: [
            Fixtures.clip(id: "manual", mediaType: .audio, start: 0, duration: 150), audio
        ]))
        let before = h.editor.timeline
        h.editor.reorderProductionClipsToPlanOrder()
        #expect(h.editor.timeline == before)
        #expect(h.editor.editorToast != nil)
    }

    @Test func deletedBindingDoesNotAdoptAnotherUseOfTheSameAsset() throws {
        let (h, asset, bindings) = try grouped()
        let middleIds = Set([bindings[1].videoClipId] + bindings[1].linkedAudioClipIds)
        h.editor.removeClips(ids: middleIds)
        let before = h.editor.timeline
        #expect(throws: ToolError.self) { try h.editor.placeProductionShot(asset: asset, shotId: "shot-1") }
        #expect(h.editor.timeline == before)
        try h.editor.resetProductionShots(ids: ["shot-1"])
        #expect(h.editor.timeline == before)
        #expect(h.editor.shot(id: "shot-1")?.placement == nil)
    }

    @Test func tooShortRetakeLeavesTheWholePairAndBindingUntouched() throws {
        let (h, _, _) = try grouped()
        let short = h.addAsset(duration: 2, hasAudio: true)
        let before = h.editor.timeline
        let plan = h.editor.shotPlan
        #expect(throws: ToolError.self) { try h.editor.placeProductionShot(asset: short, shotId: "shot-1") }
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == plan)
    }

    @Test func resetPreservesManuallyDetachedAudio() throws {
        let (h, _, bindings) = try grouped()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        h.editor.unlinkClips(ids: [audioId])
        let detached = h.editor.clipFor(id: audioId)
        try h.editor.resetProductionShots(ids: ["shot-1"])
        #expect(h.editor.clipFor(id: bindings[1].videoClipId) == nil)
        #expect(h.editor.clipFor(id: audioId) == detached)
    }

    @Test func groupedReplacementIsAtomicAndOneUndoOperation() throws {
        let (h, _, _) = try grouped()
        let replacement = h.addAsset(duration: 15, hasAudio: true)
        let before = h.editor.timeline
        let beforePlan = h.editor.shotPlan
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        let segments: [(shotId: String, sourceRange: ShotSourceRange)] = (0..<3).map { i in
            let start = Double(i) * 5
            return (shotId: "shot-\(i)", sourceRange: ShotSourceRange(startSeconds: start, endSeconds: start + 5))
        }
        var invalid = segments
        invalid[2].sourceRange.endSeconds = 12
        #expect(throws: ToolError.self) { try h.editor.placeProductionUnit(asset: replacement, segments: invalid) }
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == beforePlan)
        #expect(!undo.canUndo)
        try h.editor.placeProductionUnit(asset: replacement, segments: segments)
        let after = h.editor.timeline
        #expect(after.tracks.flatMap(\.clips).allSatisfy { $0.mediaRef == replacement.id })
        undo.undo()
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == beforePlan)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(h.editor.timeline == after)
        #expect(h.editor.shotPlan?.shots.allSatisfy { $0.placement?.assetId == replacement.id } == true)
    }

    @Test func singleLegacyClipReconcilesAndOldJSONStillDecodes() throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [.init(type: .video, clips: [Fixtures.clip(id: "clip", mediaRef: "asset", start: 60, duration: 150)])]))
        let old = try JSONDecoder().decode(Shot.self, from: Data(#"{"id":"legacy","videoAssetId":"asset","takes":[{"id":"old-take","videoAssetId":"asset"}]}"#.utf8))
        #expect(old.placement == nil)
        #expect(old.takes[0].sourceRange == nil)
        h.editor.upsertShot(old)
        h.editor.reconcileLegacyProductionPlacements()
        let placement = try #require(h.editor.shot(id: "legacy")?.placement)
        #expect(placement.videoClipId == "clip")
        #expect(placement.takeId == "old-take")
        #expect(try h.executor.shotStartFrame(h.editor.shot(id: "legacy")!, editor: h.editor) == 60)
    }

    @Test func planResavePreservesPlacementAndDoesNotInvalidatePanelSettings() async throws {
        let (h, _, _) = try grouped()
        let plan = h.editor.shotPlan!
        var withoutPlacement = plan.shots[1]
        withoutPlacement.placement = nil
        #expect(try StoryboardReviewGate.settingsDigest(shot: withoutPlacement, plan: plan) == StoryboardReviewGate.settingsDigest(shot: plan.shots[1], plan: plan))
        _ = try await h.runOK("save_shot_plan", args: ["title": "Updated plan", "shots": [["id": "shot-1", "summary": "Updated"]]])
        #expect(h.editor.shot(id: "shot-1")?.placement == plan.shots[1].placement)
    }

    @Test func actualPackageReopenRetainsSharedSourceRangesAndClipIdentity() async throws {
        let url = try await FixtureVideo.write(scenes: [.init(rgb: (255, 0, 0), seconds: 2), .init(rgb: (0, 0, 255), seconds: 2)])
        let packageURL = FileManager.default.temporaryDirectory.appendingPathComponent("placement-\(UUID()).venice")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: packageURL) }
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        let h = ToolHarness()
        let asset = MediaAsset(id: "shared", url: url, type: .video, name: "Shared fixture", duration: duration)
        asset.hasAudio = !(try await AVURLAsset(url: url).loadTracks(withMediaType: .audio)).isEmpty
        h.editor.mediaAssets = [asset]
        h.editor.saveShotPlan(ShotPlan(shots: [Shot(id: "a"), Shot(id: "b")]))
        try h.editor.placeProductionShot(asset: asset, shotId: "a", sourceSegment: 0...2)
        try h.editor.placeProductionShot(asset: asset, shotId: "b", sourceSegment: 2...duration)
        h.editor.mediaManifest.entries = [.init(id: asset.id, name: asset.name, type: .video, source: .external(absolutePath: url.path), duration: duration)]
        try VideoProject.writeProjectPackage(.init(timeline: JSONEncoder().encode(h.editor.timeline), manifest: JSONEncoder().encode(h.editor.mediaManifest), generationLog: nil, thumbnail: nil, chatSessionFiles: []), to: packageURL, sourceURL: nil)
        let package = try VideoProject.readProjectPackage(at: packageURL)
        let reopened = ToolHarness(timeline: package.timeline)
        reopened.editor.mediaManifest = try #require(package.manifest)
        reopened.editor.mediaAssets = [asset]
        let second = try #require(reopened.editor.shot(id: "b"))
        #expect(second.placement == h.editor.shot(id: "b")?.placement)
        #expect(second.placement?.sourceRange.startSeconds == 2)
        #expect(try reopened.executor.shotStartFrame(second, editor: reopened.editor) == 60)
        reopened.editor.setShotStatus(id: "a", .generating)
        reopened.editor.setShotStatus(id: "b", .generating)
        let beforeRecovery = reopened.editor.timeline
        reopened.editor.productionOrchestrator.resume(editor: reopened.editor)
        reopened.editor.productionOrchestrator.resume(editor: reopened.editor)
        #expect(reopened.editor.timeline == beforeRecovery)
        #expect(reopened.editor.shotPlan?.shots.allSatisfy { $0.status == .placed } == true)
        try reopened.editor.resetProductionShots(ids: ["b"])
        #expect(reopened.editor.timeline.tracks.flatMap(\.clips).count == 1)
        #expect(reopened.editor.timeline.tracks.flatMap(\.clips).first?.id == h.editor.shot(id: "a")?.placement?.videoClipId)
    }
}
