import AppKit
import AVFoundation
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Durable production audio")
@MainActor
struct ProductionAudioTests {
    func fixture(lines: Int = 2) -> ToolHarness {
        let h = ToolHarness()
        let picture = h.addAsset(id: "picture-asset", duration: 10)
        h.editor.timeline = Fixtures.timeline(tracks: [.init(type: .video, clips: [Fixtures.clip(id: "picture", mediaRef: picture.id, start: 0, duration: 300)])])
        var shot = Shot(id: "shot", prompt: "A car drives forward.")
        shot.videoAssetId = picture.id
        shot.dialogue = (0..<lines).map { ShotDialogue(id: "line-\($0)", text: "The road opens ahead \($0).", voiceOver: true) }
        h.editor.saveShotPlan(ShotPlan(shots: [shot]))
        h.editor.persistProductionState = {}
        h.editor.productionAudioCoordinator.measureAudio = { $0.duration }
        h.editor.productionAudioCoordinator.submitAudio = { [weak editor = h.editor] submission in
            guard let editor else { return "closed" }
            let id = UUID().uuidString
            let asset = MediaAsset(id: id, url: URL(fileURLWithPath: "/tmp/unused-\(id).wav"), type: .audio, name: "Fixture", duration: 1, generationInput: submission.genInput)
            asset.generationStatus = .preparing
            editor.mediaAssets.append(asset)
            #expect(editor.mediaManifest.productionAudioOperations.last?.id == submission.genInput.productionAudioOperationId)
            editor.recordProductionJobMetadata(asset)
            return id
        }
        return h
    }

    func request(_ h: ToolHarness, line index: Int = 0, role: ProductionAudioOperation.Role = .dialogue, prompt: String? = nil) throws -> ProductionAudioCoordinator.Request {
        let entry = try JSONDecoder().decode(CatalogEntry.self, from: Data(#"{"id":"fixture-audio","kind":"audio","displayName":"Fixture","allowedEndpoints":[],"responseShape":"audio","uiCapabilities":{"category":"tts","supportsLyrics":false,"supportsInstrumental":true,"supportsStyleInstructions":false,"minPromptLength":1}}"#.utf8))
        guard case .audio(let caps) = entry.uiCapabilities else { throw ToolError("Invalid fixture") }
        let model = AudioModelConfig(entry: entry, caps: caps)
        let line = role == .dialogue ? h.editor.shotPlan?.shots.first?.dialogue[index] : nil
        let text = prompt ?? line?.text ?? "A quiet instrumental bed"
        return .init(key: .init(role: role, shotId: line == nil ? nil : "shot", lineId: line?.id),
                     input: .init(prompt: text, model: model.id, duration: 0, aspectRatio: "", resolution: nil),
                     model: model, params: .init(prompt: text, voice: nil, lyrics: nil, styleInstructions: nil, instrumental: false, durationSeconds: nil),
                     name: "Fixture", estimatedFrames: role == .dialogue ? 30 : 300)
    }

    func asset(_ h: ToolHarness, _ id: String) throws -> MediaAsset {
        let assetId = try #require(h.editor.productionAudioCoordinator.operation(id)?.placeholderId)
        return try #require(h.editor.mediaAssets.first { $0.id == assetId })
    }

    func settled(_ h: ToolHarness) async throws {
        for _ in 0..<20_000 {
            if !h.editor.productionAudioCoordinator.isFinishing { return }
            await Task.yield()
        }
        try #require(!h.editor.productionAudioCoordinator.isFinishing)
    }

    func complete(_ h: ToolHarness, _ id: String, seconds: Double) async throws {
        let output = try asset(h, id)
        output.duration = seconds
        output.generationStatus = .none
        h.editor.recordProductionJobMetadata(output)
        try await settled(h)
    }

    @Test func reverseCompletionReflowsMeasuredLinesAndRerunsReuseAttempts() async throws {
        let h = fixture()
        let o = h.editor.productionAudioCoordinator
        let first = try o.submit(request(h))
        let second = try o.submit(request(h, line: 1))
        #expect(try o.submit(request(h)) == first)
        #expect(h.editor.mediaAssets.count == 3)
        try await complete(h, second, seconds: 2)
        try await complete(h, first, seconds: 2)
        let a = try #require(o.operation(first)?.placedClip)
        let b = try #require(o.operation(second)?.placedClip)
        #expect(a.startFrame == 0 && a.durationFrames == 60)
        #expect(b.startFrame == 63 && b.durationFrames == 60)
        #expect(try o.submit(request(h, line: 1)) == second)
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 3)
        #expect(h.editor.mediaManifest.productionAudioOperations.count == 2)
        #expect(h.editor.timeline.tracks.count == 2)
    }

    @Test func partialTextRegenerationReplacesOnlyTheBoundLine() async throws {
        let h = fixture()
        let o = h.editor.productionAudioCoordinator
        let first = try o.submit(request(h))
        let second = try o.submit(request(h, line: 1))
        try await complete(h, first, seconds: 1)
        try await complete(h, second, seconds: 1)
        let secondAsset = o.operation(second)?.placedClip?.mediaRef
        h.editor.mutateShotPlan(actionName: "Rewrite line") { $0.shots[0].dialogue[0].text = "The revised line." }
        let replacement = try o.submit(request(h))
        try await complete(h, replacement, seconds: 2)
        #expect(replacement != first)
        #expect(o.operation(replacement)?.clipId == o.operation(first)?.clipId)
        #expect(o.operation(replacement)?.stage == .placed)
        #expect(o.operation(second)?.placedClip?.mediaRef == secondAsset)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 3)
        let obsolete = h.editor.timeline.tracks.flatMap(\.clips).filter { $0.mediaRef == o.operation(first)?.placeholderId }
        #expect(obsolete.isEmpty)
    }

    @Test func overrunRetainsOutputAndCanFinishAfterPictureExtension() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        try await complete(h, id, seconds: 12)
        #expect(o.operation(id)?.stage == .blocked)
        #expect(o.operation(id)?.measuredSeconds == 12)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
        h.editor.timeline.tracks[0].clips[0].durationFrames = 390
        #expect(try o.submit(request(h)) == id)
        try await settled(h)
        #expect(o.operation(id)?.stage == .placed)
        #expect(o.operation(id)?.placedClip?.durationFrames == 360)
        #expect(h.editor.mediaManifest.productionAudioOperations.count == 1)
    }

    @Test func bedsKeepCutLengthAndDuckMeasuredSpeech() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let bed = try o.submit(request(h, role: .music))
        let ambient = try o.submit(request(h, role: .ambient))
        try await complete(h, bed, seconds: 20)
        try await complete(h, ambient, seconds: 20)
        let line = try o.submit(request(h))
        try await complete(h, line, seconds: 2)
        let bedClipId = try #require(o.operation(bed)?.clipId)
        let clip = try #require(h.editor.clipFor(id: bedClipId))
        #expect(clip.durationFrames == 300 && clip.trimEndFrame == 300)
        #expect(abs(clip.volumeAt(frame: 30) - 0.25) < 0.000001)
        #expect(abs(clip.volumeAt(frame: 150) - 1) < 0.000001)
        #expect(o.operation(bed)?.clipId != o.operation(ambient)?.clipId)
        #expect(h.editor.timeline.totalFrames == 300)
    }

    @Test func replacementPreservesManualTimingFadesAndMix() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        try await complete(h, id, seconds: 3)
        let clipId = try #require(o.operation(id)?.clipId)
        let location = try #require(h.editor.findClip(id: clipId))
        var manual = h.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        manual.startFrame = 30; manual.durationFrames = 30; manual.trimStartFrame = 15
        manual.fadeInFrames = 3; manual.fadeOutFrames = 5; manual.volume = 0.42
        h.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex] = manual
        let replacement = try o.submit(request(h), regenerate: true)
        try await complete(h, replacement, seconds: 4)
        var expected = manual
        expected.mediaRef = try #require(o.operation(replacement)?.placeholderId)
        #expect(h.editor.clipFor(id: manual.id) == expected)
    }

    @Test func voiceOrLineEditsDuringMeasurementBlockPlacement() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        o.measureAudio = { _ in
            h.editor.mutateShotPlan(actionName: "Edit speech") { $0.shots[0].dialogue[0].text = "Changed while measuring" }
            return 2
        }
        try await complete(h, id, seconds: 2)
        #expect(o.operation(id)?.stage == .blocked)
        #expect(o.operation(id)?.failureReason?.contains("changed") == true)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
    }

    @Test func finalSaveFailureRetriesWithoutDuplicatingAndUndoDoesNotRecreate() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let undo = UndoManager()
        undo.groupsByEvent = false
        h.editor.undoManager = undo
        let id = try o.submit(request(h))
        var saves = 0
        h.editor.persistProductionState = {
            saves += 1
            if saves == 2 { throw ToolError("Fixture final save failed") }
        }
        try await complete(h, id, seconds: 2)
        #expect(o.operation(id)?.stage == .placed)
        #expect(o.operation(id)?.failureReason == "Fixture final save failed")
        o.resume()
        try await settled(h)
        #expect(o.operation(id)?.failureReason == nil)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 2)
        undo.undo()
        o.resume()
        try await settled(h)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
        #expect(o.operation(id)?.failureReason?.contains("undone") == true)
    }

    @Test func placeholderReplayAndCancelledAttemptCannotSubmitAgain() throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        let output = try asset(h, id)
        let input = try #require(output.generationInput)
        try h.editor.validateProductionAttempt(input, placeholderId: output.id)
        #expect(throws: ToolError.self) { try h.editor.validateProductionAttempt(input, placeholderId: "different") }
        output.generationStatus = .cancelled
        h.editor.recordProductionJobMetadata(output)
        #expect(throws: ToolError.self) { try h.editor.validateProductionAttempt(input, placeholderId: output.id) }
        #expect(try o.submit(request(h)) == id)
        #expect(h.editor.mediaManifest.productionAudioOperations.count == 1)
    }

    @Test func realWaveAndPackageReopenUseMeasuredDurationWithoutSubmission() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        let output = try asset(h, id)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("production-audio-\(UUID()).venice")
        let wave = FileManager.default.temporaryDirectory.appendingPathComponent("production-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url); try? FileManager.default.removeItem(at: wave) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 30_000))
        buffer.frameLength = 30_000
        for i in 0..<30_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 24_000) * 0.1) }
        do { let file = try AVAudioFile(forWriting: wave, settings: format.settings); try file.write(from: buffer) }
        output.url = wave
        output.generationStatus = .none
        output.generationInput?.queueId = "retained-audio-queue"
        h.editor.mediaManifest.entries = [.init(id: output.id, name: output.name, type: .audio, source: .external(absolutePath: wave.path), duration: 99, generationInput: output.generationInput)]
        try VideoProject.writeProjectPackage(.init(timeline: JSONEncoder().encode(h.editor.timeline), manifest: JSONEncoder().encode(h.editor.mediaManifest), generationLog: nil, thumbnail: nil, chatSessionFiles: []), to: url, sourceURL: nil)
        let package = try VideoProject.readProjectPackage(at: url)
        let reopened = ToolHarness(timeline: package.timeline)
        reopened.editor.mediaManifest = try #require(package.manifest)
        reopened.editor.mediaAssets = h.editor.mediaAssets
        reopened.editor.persistProductionState = {}
        reopened.editor.productionAudioCoordinator.submitAudio = { _ in Issue.record("Recovery submitted audio"); return "unexpected" }
        reopened.editor.productionAudioCoordinator.resume()
        try await settled(reopened)
        #expect(reopened.editor.productionAudioCoordinator.operation(id)?.measuredSeconds == 1.25)
        #expect(reopened.editor.mediaManifest.entries.first?.duration == 1.25)
        #expect(output.duration == 1.25 && output.hasAudio)
        #expect(reopened.editor.productionAudioCoordinator.operation(id)?.placedClip?.durationFrames == 37)
        reopened.editor.productionAudioCoordinator.resume()
        try await settled(reopened)
        #expect(reopened.editor.timeline.tracks.flatMap(\.clips).count == 2)
    }

    @Test func invalidMeasuredFactsAndMissingAudioFail() async throws {
        let h = fixture(lines: 1)
        let id = try h.editor.productionAudioCoordinator.submit(request(h))
        try await complete(h, id, seconds: .infinity)
        #expect(h.editor.productionAudioCoordinator.operation(id)?.stage == .blocked)
        h.editor.productionAudioCoordinator.measureAudio = nil
        h.editor.productionAudioCoordinator.resume()
        try await settled(h)
        #expect(h.editor.productionAudioCoordinator.operation(id)?.stage == .blocked)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
    }

    @Test func toolResaveAndShortIDsKeepLineIdentity() async throws {
        let h = fixture(lines: 1)
        let original = try #require(h.editor.shotPlan?.shots[0].dialogue[0])
        _ = try await h.runOK("update_shots", args: ["operations": [["action": "update", "id": "shot", "dialogue": [["text": original.text, "voiceOver": true]]]]])
        #expect(h.editor.shotPlan?.shots[0].dialogue[0].id == original.id)
        _ = try await h.runOK("save_shot_plan", args: ["shots": [["id": "shot", "prompt": "A car drives.", "dialogue": [["text": original.text, "voiceOver": true]]]]])
        #expect(h.editor.shotPlan?.shots[0].dialogue[0].id == original.id)
        #expect(h.executor.currentIdUniverse(h.editor).contains(original.id))
        let duplicate = await h.runRaw("update_shots", args: ["operations": [["action": "update", "id": "shot", "dialogue": [["id": "same", "text": "One"], ["id": "same", "text": "Two"]]]]])
        #expect(duplicate.isError)
    }

    @Test func nativeSpeechIsReportedWithoutTTSAndStatusEncodesAudio() async throws {
        let h = fixture(lines: 1)
        let id = try h.editor.productionAudioCoordinator.submit(request(h))
        try await complete(h, id, seconds: 2)
        let status = try await h.runOK("production_status") as? [String: Any]
        #expect(status?["audioOperationCount"] as? Int == 1)
        #expect((status?["audioOperations"] as? [[String: Any]])?.first?["measuredSeconds"] as? Double == 2)
        let native = fixture(lines: 1)
        native.editor.mutateShotPlan(actionName: "Native speech") { $0.shots[0].dialogue[0].voiceOver = false }
        let result = try await native.runOK("produce_audio") as? [String: Any]
        #expect((result?["nativeSpeechLines"] as? [[String: String]])?.count == 1)
        #expect(native.editor.mediaManifest.productionAudioOperations.isEmpty)
    }

    @Test func servicePersistsLineAndPlaceholderBeforeProviderAccess() async throws {
        let h = fixture(lines: 1)
        var persisted: MediaManifest?
        h.editor.persistProductionState = {
            persisted = h.editor.mediaManifest
            throw ToolError("Fixture audio checkpoint failure")
        }
        h.editor.productionAudioCoordinator.submitAudio = { submission in
            submission.submit(service: h.editor.generationService, projectURL: nil, editor: h.editor)
        }
        let id = try h.editor.productionAudioCoordinator.submit(request(h))
        let output = try asset(h, id)
        for _ in 0..<20_000 where output.isGenerating { await Task.yield() }
        let saved = try #require(persisted?.productionAudioOperations.last)
        #expect(saved.id == id && saved.key.lineId == "line-0")
        #expect(saved.placeholderId == output.id)
        #expect(persisted?.entries.contains { $0.id == output.id } == true)
        #expect(output.generationInput?.backendJobId == nil)
        #expect(h.editor.productionAudioCoordinator.operation(id)?.failureReason == "Fixture audio checkpoint failure")
    }

    @Test func manualBedEnvelopeSurvivesReplacementAndLaterSpeech() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let bed = try o.submit(request(h, role: .music))
        try await complete(h, bed, seconds: 20)
        let clipId = try #require(o.operation(bed)?.clipId)
        let location = try #require(h.editor.findClip(id: clipId))
        var manual = h.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex]
        var envelope = KeyframeTrack<Double>()
        envelope.upsert(Keyframe(frame: 0, value: 0.4))
        envelope.upsert(Keyframe(frame: 80, value: 0.6))
        manual.volumeTrack = envelope
        manual.fadeOutFrames = 30
        h.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex] = manual
        let replacement = try o.submit(request(h, role: .music), regenerate: true)
        try await complete(h, replacement, seconds: 30)
        let line = try o.submit(request(h))
        try await complete(h, line, seconds: 2)
        #expect(h.editor.clipFor(id: clipId)?.volumeTrack == envelope)
        #expect(h.editor.clipFor(id: clipId)?.fadeOutFrames == 30)
    }

    @Test func detachDuringMeasurementCannotPlaceAndDuplicateCallbacksShareTask() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        var gate: CheckedContinuation<Double, Never>?
        var calls = 0
        o.measureAudio = { _ in calls += 1; return await withCheckedContinuation { gate = $0 } }
        let output = try asset(h, id)
        output.generationStatus = .none
        h.editor.recordProductionJobMetadata(output)
        for _ in 0..<20_000 where gate == nil { await Task.yield() }
        try #require(gate != nil)
        h.editor.recordProductionJobMetadata(output)
        o.resume()
        #expect(calls == 1)
        o.detachAll()
        gate?.resume(returning: 2)
        for _ in 0..<100 { await Task.yield() }
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 1)
    }

    @Test func removedLineCannotCreateOrphanSpeechOnRerunAndLegacyManifestDecodes() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let id = try o.submit(request(h))
        try await complete(h, id, seconds: 2)
        h.editor.mutateShotPlan(actionName: "New identity") { $0.shots[0].dialogue = [ShotDialogue(text: "A different line", voiceOver: true)] }
        #expect(throws: ToolError.self) { try o.submit(request(h)) }
        #expect(h.editor.mediaManifest.productionAudioOperations.count == 1)
        let old = try JSONDecoder().decode(MediaManifest.self, from: Data(#"{"version":3}"#.utf8))
        #expect(old.productionAudioOperations.isEmpty)
    }

    @Test func explicitRetryAcceptsCurrentManualEditWithoutBuyingAnotherTake() async throws {
        let h = fixture(lines: 1)
        let o = h.editor.productionAudioCoordinator
        let original = try o.submit(request(h))
        try await complete(h, original, seconds: 2)
        let replacement = try o.submit(request(h), regenerate: true)
        let clipId = try #require(o.operation(original)?.clipId)
        let location = try #require(h.editor.findClip(id: clipId))
        h.editor.timeline.tracks[location.trackIndex].clips[location.clipIndex].volume = 0.42
        try await complete(h, replacement, seconds: 2)
        #expect(o.operation(replacement)?.stage == .blocked)
        #expect(try o.submit(request(h)) == replacement)
        try await settled(h)
        #expect(o.operation(replacement)?.stage == .placed)
        #expect(h.editor.clipFor(id: clipId)?.volume == 0.42)
        #expect(h.editor.mediaManifest.productionAudioOperations.count == 2)
    }

    @Test func concurrentReplacementsRetainAutomaticallyReflowedDestinations() async throws {
        let h = fixture()
        let o = h.editor.productionAudioCoordinator
        let first = try o.submit(request(h))
        let second = try o.submit(request(h, line: 1))
        try await complete(h, first, seconds: 1)
        try await complete(h, second, seconds: 1)
        let a = try o.submit(request(h), regenerate: true)
        let b = try o.submit(request(h, line: 1), regenerate: true)
        try await complete(h, a, seconds: 2)
        try await complete(h, b, seconds: 2)
        #expect(o.operation(a)?.stage == .placed)
        #expect(o.operation(b)?.stage == .placed)
        #expect(o.operation(b)?.placedClip?.startFrame == 63)
        #expect(h.editor.timeline.tracks.flatMap(\.clips).count == 3)
    }

    @Test func legacyProductionAudioIsNotSilentlyDuplicated() throws {
        let h = fixture(lines: 1)
        let recipe = try request(h)
        let old = h.addAsset(type: .audio)
        old.name = "Dialogue · shot"
        old.generationInput = recipe.input
        h.editor.timeline.tracks.append(Fixtures.audioTrack(clips: [Fixtures.clip(mediaRef: old.id, mediaType: .audio, start: 0, duration: 30)]))
        #expect(throws: ToolError.self) { try h.editor.productionAudioCoordinator.submit(recipe) }
        #expect(h.editor.mediaManifest.productionAudioOperations.isEmpty)
    }
}
