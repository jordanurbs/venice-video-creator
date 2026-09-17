import AppKit
import AVFoundation
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Retained audio layout")
@MainActor
struct ProductionAudioLayoutTests {
    @MainActor
    private final class Fixture {
        let driver = ProductionAudioTests()
        let h: ToolHarness
        var ids: [String] = []
        var files: [URL] = []

        init() { h = driver.fixture() }

        func finish() async throws {
            let o = h.editor.productionAudioCoordinator
            ids = [try o.submit(driver.request(h)), try o.submit(driver.request(h, line: 1)), try o.submit(driver.request(h, role: .music))]
            for (index, id) in ids.enumerated() {
                let seconds = index == 2 ? 20.0 : 2.0
                let asset = try driver.asset(h, id)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-layout-\(UUID()).wav")
                files.append(url)
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
                let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 8_000)))
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 8_000) * 0.1) }
                do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
                asset.url = url
                try await driver.complete(h, id, seconds: seconds)
                #expect(o.operation(id)?.stage == .placed)
            }
        }

        func clip(_ index: Int) throws -> Clip {
            let id = try #require(h.editor.productionAudioCoordinator.operation(ids[index])?.clipId)
            return try #require(h.editor.clipFor(id: id))
        }

        func cleanup() { for file in files { try? FileManager.default.removeItem(at: file) } }
    }

    @Test func pictureMoveRefitsSpeechAndBedThroughDispatcherWithoutGeneration() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        f.h.editor.timeline.tracks[0].clips[0].startFrame = 60
        let result = try await f.h.runOK("reconcile_audio") as? [String: Any]
        #expect(result?["changedClipCount"] as? Int == 3)
        #expect(try f.clip(0).startFrame == 60)
        #expect(try f.clip(1).startFrame == 123)
        let bed = try f.clip(2)
        #expect(bed.durationFrames == 360)
        #expect(abs(bed.volumeAt(frame: 90) - 0.25) < 0.000001)
        #expect(abs(bed.volumeAt(frame: 30) - 1) < 0.000001)
        #expect(f.h.editor.mediaManifest.productionAudioOperations.count == 3)
        #expect(try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio() == 0)
    }

    @Test func manualDialogueTrimReflowsFollowersAndPreservesCustomBedEnvelope() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        let first = try f.clip(0)
        let bed = try f.clip(2)
        f.h.editor.commitClipProperty(clipId: first.id) { $0.durationFrames = 30; $0.trimStartFrame = 15; $0.fadeOutFrames = 5 }
        var curve = KeyframeTrack<Double>()
        curve.upsert(Keyframe(frame: 0, value: -9))
        f.h.editor.commitClipProperty(clipId: bed.id) { $0.volumeTrack = curve; $0.volume = 0.4 }
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(try f.clip(0).durationFrames == 30)
        #expect(try f.clip(0).trimStartFrame == 15)
        #expect(try f.clip(1).startFrame == 33)
        #expect(try f.clip(2).volumeTrack == curve)
        #expect(try f.clip(2).volume == 0.4)
        let record = try #require(f.h.editor.productionAudioCoordinator.operation(f.ids[0]))
        #expect(!record.ownsTiming)
    }

    @Test func undoRedoRestoresAutomaticBaselinesForTheNextMove() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        f.h.editor.timeline.tracks[0].clips[0].startFrame = 60
        let before = f.h.editor.timeline
        let records = f.h.editor.mediaManifest.productionAudioOperations
        let undo = UndoManager()
        undo.groupsByEvent = false
        f.h.editor.undoManager = undo
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        let after = f.h.editor.timeline
        undo.undo()
        #expect(f.h.editor.timeline == before)
        #expect(f.h.editor.mediaManifest.productionAudioOperations == records)
        undo.redo()
        #expect(f.h.editor.timeline == after)
        f.h.editor.timeline.tracks[0].clips[0].startFrame = 90
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(try f.clip(0).startFrame == 90)
    }

    @Test func fpsChangeRebasesBindingsAndRepeatResumeDoesNotFailOrBuy() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        f.h.editor.applyTimelineSettings(fps: 24, width: f.h.editor.timeline.width, height: f.h.editor.timeline.height)
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(try f.clip(0).durationFrames == 48)
        #expect(try f.clip(1).startFrame == 50)
        #expect(try f.clip(2).durationFrames == 240)
        #expect(f.h.editor.mediaManifest.productionAudioOperations.allSatisfy { $0.placementFPS == 24 })
        f.h.editor.productionAudioCoordinator.resume()
        try await f.driver.settled(f.h)
        #expect(f.h.editor.mediaManifest.productionAudioOperations.allSatisfy { $0.failureReason == nil })
    }

    @Test func pictureShorteningAndSourceOverrunFailBeforeMutation() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        f.h.editor.timeline.tracks[0].clips[0].durationFrames = 90
        let before = f.h.editor.timeline
        let records = f.h.editor.mediaManifest.productionAudioOperations
        #expect(throws: ToolError.self) { try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio() }
        #expect(f.h.editor.timeline == before)
        #expect(f.h.editor.mediaManifest.productionAudioOperations == records)
        f.h.editor.timeline.tracks[0].clips[0].durationFrames = 900
        let longer = f.h.editor.timeline
        #expect(throws: ToolError.self) { try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio() }
        #expect(f.h.editor.timeline == longer)
    }

    @Test func nativeSpeechMixChangesUpdateOwnedDuckingWindows() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        f.h.editor.mutateShotPlan(actionName: "Add native line") { $0.shots[0].dialogue.append(ShotDialogue(text: "On-screen speech", voiceOver: false)) }
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(abs(try f.clip(2).volumeAt(frame: 240) - 0.25) < 0.000001)
        f.h.editor.mutateShotPlan(actionName: "Mute native sound") { $0.shots[0].nativeAudio = .mute }
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(abs(try f.clip(2).volumeAt(frame: 240) - 1) < 0.000001)
    }

    @Test func missingFileOrStaleLineIsNotDeclaredReconciled() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        let asset = try f.driver.asset(f.h, f.ids[0])
        let real = asset.url
        asset.url = real.appendingPathExtension("missing")
        #expect(throws: ToolError.self) { try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio() }
        asset.url = real
        f.h.editor.mutateShotPlan(actionName: "Edit narration") { $0.shots[0].dialogue[0].text = "Different words" }
        #expect(throws: ToolError.self) { try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio() }
    }

    @Test func intentionalManualBedSpanAndFadesSurviveCutExtension() async throws {
        let f = Fixture()
        defer { f.cleanup() }
        try await f.finish()
        let bed = try f.clip(2)
        f.h.editor.commitClipProperty(clipId: bed.id) { $0.startFrame = 30; $0.durationFrames = 180; $0.fadeOutFrames = 30 }
        f.h.editor.timeline.tracks[0].clips[0].durationFrames = 450
        try f.h.editor.productionAudioCoordinator.reconcilePlacedAudio()
        #expect(try f.clip(2).startFrame == 30)
        #expect(try f.clip(2).durationFrames == 180)
        #expect(try f.clip(2).fadeOutFrames == 30)
    }
}
