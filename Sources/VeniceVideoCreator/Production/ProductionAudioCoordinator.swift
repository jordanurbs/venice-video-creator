import AVFoundation
import Foundation

@MainActor
final class ProductionAudioCoordinator {
    struct Request {
        var key: ProductionAudioOperation.Key
        var input: GenerationInput
        var model: AudioModelConfig
        var params: AudioGenerationParams
        var name: String
        var estimatedFrames: Int
    }

    weak var editor: EditorViewModel?
    var submitAudio: ((AudioGenerationSubmission) -> String)?
    var measureAudio: ((MediaAsset) async throws -> Double)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var detached = false
    var isFinishing: Bool { !tasks.isEmpty }

    func latest(for key: ProductionAudioOperation.Key) -> ProductionAudioOperation? {
        editor?.mediaManifest.productionAudioOperations.last { $0.key == key }
    }

    func operation(_ id: String) -> ProductionAudioOperation? {
        editor?.mediaManifest.productionAudioOperations.first { $0.id == id }
    }

    @discardableResult
    func submit(_ request: Request, regenerate: Bool = false) throws -> String {
        guard let editor, !detached else { throw ToolError("The project is closed.") }
        guard editor.persistProductionState != nil else { throw ToolError("Save the project before producing audio.") }
        try requireLineBindings()
        let previous = latest(for: request.key)
        let shot = request.key.shotId.flatMap { editor.shotPlan?.shot(id: $0) }
        let line = shot?.dialogue.first { $0.id == request.key.lineId }
        let character = line?.characterId.flatMap { editor.shotPlan?.character(id: $0) }
        let picture = try shot.flatMap { try editor.productionClip(for: $0) }
        if request.key.role == .dialogue {
            guard let line, line.voiceOver, picture != nil else { throw ToolError("Place the shot and mark off-screen speech as voiceOver before producing TTS.") }
            guard shot?.dialogue.filter({ $0.id == line.id }).count == 1 else { throw ToolError("Dialogue requires unique line IDs.") }
        }
        if let previous, !regenerate, Self.recipe(previous.recipe) == Self.recipe(request.input),
           previous.line == line, previous.lockedVoiceId == character?.lockedVoiceId,
           previous.voiceModel == character?.voiceModel,
           previous.key.role == .dialogue || ((previous.pictureEndFrame ?? previous.requestedFrames) == request.estimatedFrames && (previous.placementFPS ?? previous.fps) == editor.timeline.fps) {
            if let placed = previous.placedClip {
                guard editor.clipFor(id: placed.id)?.mediaRef == placed.mediaRef else {
                    throw ToolError("Audio placement was removed or replaced. Reconcile the clip before producing again.")
                }
            }
            if previous.stage == .blocked, let destination = previous.destination,
               let current = editor.clipFor(id: previous.clipId), current.mediaRef == destination.mediaRef {
                mutate(previous.id) {
                    $0.destination = current
                    $0.ownsTiming = $0.ownsTiming && Self.sameTiming(destination, current)
                    $0.ownsDucking = $0.ownsDucking && destination.volumeTrack == current.volumeTrack
                }
            }
            finishWhenReady(previous.id)
            return previous.id
        }
        if let previous, tasks[previous.id] != nil || previous.placeholderId.flatMap({ id in editor.mediaAssets.first { $0.id == id } })?.isGenerating == true {
            throw ToolError("Wait for the current audio attempt to settle before replacing this line or bed.")
        }
        let destination = previous.flatMap { editor.clipFor(id: $0.clipId) }
        if let previous, previous.placedClip != nil || previous.destination != nil {
            guard let destination, destination.mediaRef == (previous.placedClip ?? previous.destination)?.mediaRef else {
                throw ToolError("Audio placement was removed or replaced. Reconcile the clip before regenerating.")
            }
        }
        if submitAudio == nil {
            guard AccountService.shared.hasVeniceKey else { throw ToolError("Add a Venice API key in Settings before generating audio.") }
            guard ModelPreferences.shared.isEnabled(request.model.id) else { throw ToolError("Enable the selected audio model in Settings.") }
        }
        if let error = request.model.validate(params: request.params) { throw ToolError(error) }
        let id = UUID().uuidString
        var input = request.input
        input.productionAudioOperationId = id
        input.createdAt = Date()
        let ownsTiming = destination == nil || (previous?.ownsTiming == true && previous?.placedClip.map { Self.sameTiming($0, destination!) } == true)
        let ownsDucking = destination == nil || (previous?.ownsDucking == true && previous?.placedClip?.volumeTrack == destination?.volumeTrack)
        let record = ProductionAudioOperation(
            id: id, key: request.key, clipId: previous?.clipId ?? UUID().uuidString, recipe: input,
            line: line, lockedVoiceId: character?.lockedVoiceId, voiceModel: character?.voiceModel,
            pictureClipId: picture?.id, requestedFrames: request.estimatedFrames, fps: editor.timeline.fps,
            destination: destination, ownsTiming: ownsTiming, ownsDucking: ownsDucking, createdAt: Date()
        )
        editor.mediaManifest.productionAudioOperations.append(record)
        editor.onProjectContentChanged?()
        let submission = AudioGenerationSubmission.make(genInput: input, model: request.model, params: request.params, name: request.name)
        let placeholderId = submitAudio?(submission) ?? submission.submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
        mutate(id) { if $0.placeholderId == nil { $0.placeholderId = placeholderId } }
        return id
    }

    func validate(_ input: GenerationInput, placeholderId: String? = nil) throws {
        guard let id = input.productionAudioOperationId else { return }
        let record = try requireCurrent(id)
        guard record.stage == .preparing || record.stage == .generating,
              placeholderId == nil || record.placeholderId == placeholderId else {
            throw ToolError("Audio attempt was cancelled or belongs to another placeholder.")
        }
    }

    func record(_ asset: MediaAsset) {
        guard let id = asset.generationInput?.productionAudioOperationId, let existing = operation(id),
              existing.placeholderId == nil || existing.placeholderId == asset.id else { return }
        mutate(id) { record in
            record.placeholderId = asset.id
            record.backendJobId = asset.generationInput?.backendJobId
            record.queueId = asset.generationInput?.queueId
            record.generationStatus = asset.generationStatus.serialized
            guard record.placedClip == nil else { return }
            switch asset.generationStatus {
            case .none: record.stage = .ready
            case .failed(let reason): record.stage = .failed; record.failureReason = reason
            case .cancelled: record.stage = .cancelled
            default: record.stage = .generating
            }
        }
        if asset.generationStatus == .none { finishWhenReady(id) }
    }

    func resume() {
        guard let editor, !detached else { return }
        for record in editor.mediaManifest.productionAudioOperations where latest(for: record.key)?.id == record.id {
            finishWhenReady(record.id)
        }
    }

    func detachAll() {
        detached = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func finishWhenReady(_ id: String) {
        guard !detached, tasks[id] == nil, let editor, let record = operation(id),
              latest(for: record.key)?.id == id, let assetId = record.placeholderId,
              let asset = editor.mediaAssets.first(where: { $0.id == assetId }), asset.generationStatus == .none else { return }
        tasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.tasks[id] = nil }
            do { try await self.finish(id, asset: asset) }
            catch {
                guard !self.detached else { return }
                self.mutate(id) { record in
                    if record.placedClip == nil { record.stage = .blocked }
                    record.failureReason = error.localizedDescription
                }
            }
        }
    }

    private func requireCurrent(_ id: String) throws -> ProductionAudioOperation {
        try Task.checkCancellation()
        guard !detached, let editor, let record = operation(id), latest(for: record.key)?.id == id else {
            throw ToolError("Audio attempt was superseded or the project closed.")
        }
        guard editor.timeline.fps == (record.placementFPS ?? record.fps) else { throw ToolError("Timeline frame rate changed. Reconcile audio timing before finishing.") }
        try requireCurrentLine(record)
        if record.key.role != .dialogue {
            guard pictureEnd == (record.pictureEndFrame ?? record.requestedFrames) else { throw ToolError("Picture duration changed. Reconcile the bed with the current cut.") }
        }
        return record
    }

    func requireCurrentLine(_ record: ProductionAudioOperation) throws {
        guard let editor, !detached else { throw ToolError("The project is closed.") }
        if record.key.role == .dialogue {
            guard let shotId = record.key.shotId, let shot = editor.shotPlan?.shot(id: shotId),
                  let line = shot.dialogue.first(where: { $0.id == record.key.lineId }), line == record.line,
                  try editor.productionClip(for: shot)?.id == record.pictureClipId else {
                throw ToolError("Dialogue or its picture destination changed. Produce the current line revision.")
            }
            let character = line.characterId.flatMap { editor.shotPlan?.character(id: $0) }
            guard character?.lockedVoiceId == record.lockedVoiceId, character?.voiceModel == record.voiceModel else {
                throw ToolError("The locked voice changed. Produce the current line revision.")
            }
        }
    }

    func requireLineBindings() throws {
        guard let editor else { return }
        for asset in editor.mediaAssets where asset.type == .audio && asset.generationInput != nil && asset.generationInput?.productionAudioOperationId == nil {
            let legacy = asset.name.hasPrefix("Dialogue ·") || asset.name == "Add Music" || asset.name == "Add Ambient"
            if legacy, editor.timeline.tracks.flatMap(\.clips).contains(where: { $0.mediaRef == asset.id }) {
                throw ToolError("Existing production audio has no line/role binding. Keep editing those clips manually, or remove them from the timeline before producing replacements.")
            }
        }
        for record in editor.mediaManifest.productionAudioOperations where record.key.role == .dialogue && latest(for: record.key)?.id == record.id {
            guard editor.clipFor(id: record.clipId) != nil else { continue }
            let line = record.key.shotId.flatMap { editor.shotPlan?.shot(id: $0) }?.dialogue.first { $0.id == record.key.lineId }
            guard line?.voiceOver == true else {
                throw ToolError("A placed voice-over line was removed or changed to native speech. Remove its bound audio clip or restore its line ID before producing audio.")
            }
        }
    }

    var pictureEnd: Int {
        editor?.timeline.tracks.filter { $0.type == .video }.flatMap(\.clips).map(\.endFrame).max() ?? 0
    }

    private func finish(_ id: String, asset: MediaAsset) async throws {
        guard let editor else { return }
        let initial = try requireCurrent(id)
        if let placed = initial.placedClip {
            guard editor.clipFor(id: placed.id)?.mediaRef == placed.mediaRef else { throw ToolError("Audio placement was undone or replaced; it will not be recreated.") }
            try await editor.checkpointProductionState()
            _ = try requireCurrent(id)
            mutate(id) { $0.failureReason = nil }
            return
        }
        let seconds: Double
        if let measureAudio { seconds = try await measureAudio(asset) }
        else {
            let source = AVURLAsset(url: asset.url)
            guard try await !source.loadTracks(withMediaType: .audio).isEmpty else { throw ToolError("Generated media has no decodable audio track.") }
            seconds = try await source.load(.duration).seconds
        }
        guard seconds.isFinite, seconds > 0, seconds * Double(editor.timeline.fps) < Double(Int.max) else {
            throw ToolError("Generated audio has an invalid duration.")
        }
        _ = try requireCurrent(id)
        asset.duration = seconds
        asset.hasAudio = true
        editor.updateManifestMetadata(for: asset)
        mutate(id) { $0.measuredSeconds = seconds; $0.stage = .ready; $0.failureReason = nil }
        try await editor.checkpointProductionState()
        let record = try requireCurrent(id)
        guard editor.clipFor(id: record.clipId) == record.destination else {
            throw ToolError("Audio clip changed during generation. Reconcile the edit before finishing.")
        }
        let before = editor.timeline
        var after = before
        let frames = secondsToFrame(seconds: seconds, fps: after.fps)
        guard frames > 0 else { throw ToolError("Generated audio is shorter than one timeline frame.") }
        var clip = record.destination ?? Clip(mediaRef: asset.id, startFrame: 0, durationFrames: frames)
        clip.id = record.clipId
        clip.mediaRef = asset.id
        clip.mediaType = .audio
        clip.sourceClipType = .audio
        if record.ownsTiming {
            clip.durationFrames = record.key.role == .dialogue ? frames : record.requestedFrames
            clip.trimStartFrame = 0
            clip.trimEndFrame = max(0, frames - clip.durationFrames)
        }
        guard clip.speed.isFinite, clip.speed > 0,
              Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed <= Double(frames) + 1 else {
            throw ToolError("Generated audio is too short to cover the intended edit. Keep the existing clip or generate a longer take.")
        }
        if let location = editor.findClip(id: record.clipId) {
            after.tracks[location.trackIndex].clips[location.clipIndex] = clip
        } else {
            after.tracks.append(Track(type: .audio, clips: [clip]))
        }
        guard clip.fadeInFrames + clip.fadeOutFrames <= clip.durationFrames else {
            throw ToolError("Existing fades exceed the new audio duration. Adjust the fades before finishing.")
        }
        try requireLineBindings()
        try reconcile(&after, candidate: record)
        if record.destination == nil, let placed = after.tracks.last?.clips.first,
           let target = after.tracks.indices.dropLast().first(where: { index in
               after.tracks[index].type == .audio && !after.tracks[index].clips.contains {
                   $0.startFrame < placed.endFrame && placed.startFrame < $0.endFrame
               }
           }) {
            after.tracks.removeLast()
            after.tracks[target].clips.append(placed)
            after.tracks[target].clips.sort { $0.startFrame < $1.startFrame }
        }
        for track in after.tracks where track.type == .audio {
            for clip in track.clips where before.tracks.flatMap(\.clips).first(where: { $0.id == clip.id }) != clip {
                guard !track.clips.contains(where: { $0.id != clip.id && $0.startFrame < clip.endFrame && clip.startFrame < $0.endFrame }) else {
                    throw ToolError("Audio finishing overlaps another clip on the track. Adjust the edit before finishing.")
                }
            }
        }
        let records = editor.mediaManifest.productionAudioOperations.filter { latest(for: $0.key)?.id == $0.id }
        editor.undoManager?.beginUndoGrouping()
        editor.timeline = after
        editor.registerTimelineSwap(undoState: before, redoState: after, actionName: "Finish Production Audio")
        editor.undoManager?.endUndoGrouping()
        for item in records {
            guard let placed = after.tracks.flatMap(\.clips).first(where: { $0.id == item.clipId }) else { continue }
            if item.id == id {
                mutate(item.id) {
                    $0.placedClip = placed; $0.stage = .placed; $0.failureReason = nil
                    $0.placementFPS = after.fps; $0.pictureEndFrame = pictureEnd
                }
            } else if let baseline = item.placedClip, let old = before.tracks.flatMap(\.clips).first(where: { $0.id == item.clipId }) {
                mutate(item.id) {
                    var updated = baseline
                    if Self.sameTiming(baseline, old) { updated.startFrame = placed.startFrame }
                    if baseline.volumeTrack == old.volumeTrack { updated.volumeTrack = placed.volumeTrack }
                    $0.placedClip = updated
                }
            } else if let destination = item.destination, before.tracks.flatMap(\.clips).first(where: { $0.id == item.clipId }) == destination {
                mutate(item.id) { $0.destination = placed }
            }
        }
        editor.notifyTimelineChanged()
        try await editor.checkpointProductionState()
    }

    func reconcile(_ timeline: inout Timeline, candidate: ProductionAudioOperation? = nil, records: [ProductionAudioOperation]? = nil) throws {
        guard let editor, let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        let records = records ?? editor.mediaManifest.productionAudioOperations.filter { latest(for: $0.key)?.id == $0.id }
        let gap = max(1, secondsToFrame(seconds: 0.12, fps: timeline.fps))
        var windows: [ClosedRange<Int>] = []
        let shots = try plan.shots.compactMap { shot -> (Shot, Clip)? in
            guard let picture = try editor.productionClip(for: shot) else { return nil }
            return (shot, picture)
        }.sorted { $0.1.startFrame < $1.1.startFrame }
        var globalEnd = 0
        for (shot, picture) in shots {
            var cursor = max(picture.startFrame, globalEnd)
            for line in shot.dialogue where line.voiceOver {
                let key = ProductionAudioOperation.Key(role: .dialogue, shotId: shot.id, lineId: line.id)
                guard let record = records.first(where: { $0.key == key }) else { continue }
                guard record.line == line else { throw ToolError("A generated dialogue line is stale. Produce its current revision before finishing audio.") }
                let location = timeline.tracks.indices.compactMap { ti -> (Int, Int)? in
                    timeline.tracks[ti].clips.firstIndex { $0.id == record.clipId }.map { (ti, $0) }
                }.first
                guard let (ti, ci) = location else {
                    if record.placedClip != nil { throw ToolError("A dialogue clip was removed. Reconcile its binding before finishing audio.") }
                    let duration = record.measuredSeconds.map { secondsToFrame(seconds: $0, fps: timeline.fps) } ?? record.requestedFrames
                    cursor += max(1, duration) + gap
                    continue
                }
                var clip = timeline.tracks[ti].clips[ci]
                let owned = record.ownsTiming && (record.id == candidate?.id || (record.placedClip ?? record.destination).map { Self.sameTiming($0, clip) } == true)
                if owned { clip.startFrame = cursor }
                guard clip.startFrame >= cursor, clip.endFrame <= picture.endFrame else {
                    throw ToolError("Dialogue for \(shot.slug ?? shot.id) exceeds its picture window or overlaps a manual edit. Shorten the line or extend the shot; audio was not moved into the next shot.")
                }
                timeline.tracks[ti].clips[ci] = clip
                windows.append(clip.startFrame...clip.endFrame)
                cursor = clip.endFrame + gap
            }
            globalEnd = max(globalEnd, cursor)
            if shot.dialogue.contains(where: { !$0.voiceOver && !$0.text.isEmpty }), shot.nativeAudio != .mute {
                windows.append(picture.startFrame...picture.endFrame)
            }
        }
        for record in records where record.key.role != .dialogue {
            for ti in timeline.tracks.indices {
                guard let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.id == record.clipId }) else { continue }
                var clip = timeline.tracks[ti].clips[ci]
                let baseline = record.id == candidate?.id ? candidate?.destination : record.placedClip
                guard record.ownsDucking, baseline == nil || baseline?.volumeTrack == clip.volumeTrack else { continue }
                let relative = windows.filter { $0.upperBound > clip.startFrame && $0.lowerBound < clip.endFrame }
                    .map { max(0, $0.lowerBound - clip.startFrame)...min(clip.durationFrames, $0.upperBound - clip.startFrame) }
                let points = DialogueScheduler.duckKeyframes(windows: relative, baseVolume: 1, duckVolume: 0.25,
                                                            rampFrames: max(1, secondsToFrame(seconds: 0.3, fps: timeline.fps)), clipFrames: clip.durationFrames)
                var track = KeyframeTrack<Double>()
                for point in points { track.upsert(Keyframe(frame: point.frame, value: VolumeScale.dbFromLinear(point.value), interpolationOut: .linear)) }
                clip.volumeTrack = track
                timeline.tracks[ti].clips[ci] = clip
            }
        }
        for ti in timeline.tracks.indices { timeline.tracks[ti].clips.sort { $0.startFrame < $1.startFrame } }
    }

    func mutate(_ id: String, _ body: (inout ProductionAudioOperation) -> Void) {
        guard let editor, let index = editor.mediaManifest.productionAudioOperations.firstIndex(where: { $0.id == id }) else { return }
        let before = editor.mediaManifest.productionAudioOperations[index]
        body(&editor.mediaManifest.productionAudioOperations[index])
        guard before != editor.mediaManifest.productionAudioOperations[index] else { return }
        editor.onProjectContentChanged?()
        editor.onProjectCheckpointRequired?()
    }

    private static func recipe(_ input: GenerationInput) -> GenerationInput {
        var value = input
        value.productionAudioOperationId = nil
        value.createdAt = nil
        return value
    }

    static func sameTiming(_ a: Clip, _ b: Clip) -> Bool {
        a.startFrame == b.startFrame && a.durationFrames == b.durationFrames && a.trimStartFrame == b.trimStartFrame
            && a.trimEndFrame == b.trimEndFrame && a.speed == b.speed && a.mediaRef == b.mediaRef
    }
}
