import AppKit
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Native production audio mix")
@MainActor
struct NativeAudioMixTests {
    private func fixture() throws -> (ToolHarness, [ShotPlacement]) {
        let h = ToolHarness()
        let asset = h.addAsset(duration: 10, hasAudio: true)
        h.editor.saveShotPlan(ShotPlan(shots: [Shot(id: "first"), Shot(id: "second")]))
        let first = try h.editor.placeProductionShot(asset: asset, shotId: "first", sourceSegment: 0...5)
        let second = try h.editor.placeProductionShot(asset: asset, shotId: "second", sourceSegment: 5...10)
        return (h, [first, second])
    }

    private func policy(_ h: ToolHarness, _ value: ShotNativeAudio, shotId: String = "second") throws {
        try h.editor.mutateShotPlanThrowing(actionName: "Change Native Mix") { plan in
            guard let index = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[index].nativeAudio = value
        }
    }

    @Test func muteDuckKeepAffectExactPairAndPreserveAuthoredMix() throws {
        let (h, bindings) = try fixture()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        h.editor.commitClipProperty(clipId: audioId) { clip in
            clip.volume = 0.42
            clip.fadeInFrames = 7
            clip.fadeOutFrames = 11
            var envelope = KeyframeTrack<Double>()
            envelope.upsert(Keyframe(frame: 0, value: -6))
            envelope.upsert(Keyframe(frame: 149, value: -12))
            clip.volumeTrack = envelope
        }
        let manual = try #require(h.editor.clipFor(id: audioId))
        let neighbor = try #require(h.editor.clipFor(id: bindings[0].linkedAudioClipIds[0]))
        try policy(h, .mute)
        #expect(h.editor.clipFor(id: audioId)?.volumeAt(frame: 180) == 0)
        try policy(h, .duck)
        #expect(abs((h.editor.clipFor(id: audioId)?.volumeAt(frame: 180) ?? 0) - manual.volumeAt(frame: 180) * 0.3) < 0.000001)
        try policy(h, .keep)
        #expect(h.editor.clipFor(id: audioId) == manual)
        #expect(h.editor.clipFor(id: neighbor.id) == neighbor)
    }

    @Test func agentPolicyEditIsOneUndoStepWithExactManualVolumes() async throws {
        let (h, bindings) = try fixture()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        h.editor.commitClipProperty(clipId: audioId) { $0.volume = 0.42 }
        let before = h.editor.timeline
        let beforePlan = h.editor.shotPlan
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": "second", "nativeAudio": "mute"]]])
        let muted = h.editor.timeline
        let mutedPlan = h.editor.shotPlan
        #expect(h.editor.clipFor(id: audioId)?.volume == 0)
        undo.undo()
        #expect(h.editor.timeline == before)
        #expect(h.editor.shotPlan == beforePlan)
        undo.redo()
        #expect(h.editor.timeline == muted)
        #expect(h.editor.shotPlan == mutedPlan)
    }

    @Test func manualVolumeWhileDuckedBecomesTheRestoredMix() throws {
        let (h, bindings) = try fixture()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        try policy(h, .duck)
        h.editor.commitClipProperty(clipId: audioId) { $0.volume = 0.2 }
        try policy(h, .mute)
        try policy(h, .keep)
        #expect(h.editor.clipFor(id: audioId)?.volume == 0.2)
    }

    @Test func missingOrDetachedAudioFailsToolAndNativeMutationAtomically() async throws {
        let (h, bindings) = try fixture()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        h.editor.commitClipProperty(clipId: audioId) { $0.linkGroupId = nil }
        let before = h.editor.timeline
        let plan = h.editor.shotPlan
        let result = await h.runRaw("update_shots", args: ["operations": [["action": "update", "id": "second", "nativeAudio": "mute"]]])
        #expect(result.isError)
        #expect(h.editor.timeline == before && h.editor.shotPlan == plan)
        h.editor.mutateShotPlan(actionName: "Native Mix") { $0.shots[1].nativeAudio = .mute }
        #expect(h.editor.timeline == before && h.editor.shotPlan == plan)
        #expect(h.editor.editorToast != nil)
    }

    @Test func keepRestoresLegacyMissingAudioAtTheAssignedSourceRange() throws {
        let (h, bindings) = try fixture()
        h.editor.removeClips(ids: Set(bindings[1].linkedAudioClipIds), prune: false)
        let vi = try #require(h.editor.findClip(id: bindings[1].videoClipId))
        h.editor.timeline.tracks[vi.trackIndex].clips[vi.clipIndex].volume = 0
        h.editor.timeline.tracks[vi.trackIndex].clips[vi.clipIndex].linkGroupId = nil
        h.editor.mediaManifest.shotPlan?.shots[1].nativeAudio = .mute
        h.editor.mediaManifest.shotPlan?.shots[1].placement?.linkedAudioClipIds = []
        h.editor.mediaManifest.shotPlan?.shots[1].placement?.nativeAudioMix = nil
        try policy(h, .keep)
        let placement = try #require(h.editor.shot(id: "second")?.placement)
        let audioId = try #require(placement.linkedAudioClipIds.first)
        let audio = try #require(h.editor.clipFor(id: audioId))
        #expect(audio.startFrame == 150 && audio.durationFrames == 150)
        #expect(audio.trimStartFrame == 150 && audio.volume == 1)
        #expect(audio.linkGroupId == h.editor.clipFor(id: placement.videoClipId)?.linkGroupId)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 4)
    }

    @Test func retakeWhileMutedAndManifestReopenRetainRestoreVolume() throws {
        let (h, bindings) = try fixture()
        let audioId = try #require(bindings[1].linkedAudioClipIds.first)
        h.editor.commitClipProperty(clipId: audioId) { $0.volume = 0.42 }
        try policy(h, .mute)
        let replacement = h.addAsset(duration: 5, hasAudio: true)
        try h.editor.placeProductionShot(asset: replacement, shotId: "second")
        #expect(h.editor.clipFor(id: audioId)?.volume == 0)
        let reopened = ToolHarness(timeline: h.editor.timeline)
        reopened.editor.mediaManifest = try JSONDecoder().decode(MediaManifest.self, from: JSONEncoder().encode(h.editor.mediaManifest))
        reopened.editor.mediaAssets = h.editor.mediaAssets
        try policy(reopened, .keep)
        #expect(reopened.editor.clipFor(id: audioId)?.volume == 0.42)
        #expect(reopened.editor.clipFor(id: audioId)?.mediaRef == replacement.id)
    }

    @Test func nativeMixDoesNotChangeStoryboardOrVideoDestinationIdentity() throws {
        let (h, bindings) = try fixture()
        let before = try #require(h.editor.shotPlan)
        let digest = try StoryboardReviewGate.settingsDigest(shot: before.shots[1], plan: before)
        try policy(h, .mute)
        let after = try #require(h.editor.shotPlan)
        #expect(try StoryboardReviewGate.settingsDigest(shot: after.shots[1], plan: after) == digest)
        #expect(after.shots[1].placement?.destinationBinding == bindings[1].destinationBinding)
    }

    @Test func bedDuckingUsesDecibelsWithoutApplyingStaticGainTwice() throws {
        let h = ToolHarness(timeline: Fixtures.timeline(tracks: [Fixtures.audioTrack(clips: [Fixtures.clip(id: "bed", mediaType: .audio, start: 0, duration: 300, volume: 0.4)])]))
        h.editor.duckBedUnderDialogue(bedClipId: "bed", windows: [60...120])
        let clip = try #require(h.editor.clipFor(id: "bed"))
        #expect(abs(clip.volumeAt(frame: 90) - 0.1) < 0.000001)
        #expect(abs(clip.volumeAt(frame: 180) - 0.4) < 0.000001)
    }
}
