import Foundation

extension ProductionAudioCoordinator {
    struct LayoutState: Encodable, Equatable {
        var placedClip: Clip?
        var placementFPS: Int?
        var pictureEndFrame: Int?
        var ownsTiming: Bool
        var ownsDucking: Bool

        init(_ record: ProductionAudioOperation) {
            placedClip = record.placedClip
            placementFPS = record.placementFPS
            pictureEndFrame = record.pictureEndFrame
            ownsTiming = record.ownsTiming
            ownsDucking = record.ownsDucking
        }
    }

    @discardableResult
    func reconcilePlacedAudio() throws -> Int {
        let proposal = try audioLayoutProposal()
        guard proposal.hasChanges, let editor else { return 0 }
        editor.undoManager?.beginUndoGrouping()
        applyLayout(timeline: proposal.timeline, states: proposal.states)
        editor.undoManager?.setActionName("Reconcile Audio")
        editor.undoManager?.endUndoGrouping()
        return proposal.changedClipCount
    }

    struct LayoutProposal {
        var timeline: Timeline
        var states: [String: LayoutState]
        var hasChanges: Bool
        var changedClipCount: Int
    }

    func audioLayoutProposal() throws -> LayoutProposal {
        guard let editor, let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        guard !isFinishing, !editor.productionOrchestrator.isRunning else { throw ToolError("Wait for production to settle before reconciling audio.") }
        try requireLineBindings()
        let records = editor.mediaManifest.productionAudioOperations.filter { record in
            guard latest(for: record.key)?.id == record.id else { return false }
            return record.key.role != .dialogue || editor.clipFor(id: record.clipId) != nil
                || record.key.shotId.flatMap { plan.shot(id: $0) }?.dialogue.contains { $0.id == record.key.lineId && $0.voiceOver } == true
        }
        guard !records.isEmpty else { return .init(timeline: editor.timeline, states: [:], hasChanges: false, changedClipCount: 0) }
        let before = editor.timeline
        var after = before
        var prepared: [ProductionAudioOperation] = []
        for var record in records {
            try requireCurrentLine(record)
            guard record.stage == .placed, let saved = record.placedClip, let assetId = record.placeholderId,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetId }), asset.generationStatus == .none,
                  FileManager.default.fileExists(atPath: asset.url.path),
                  let current = editor.clipFor(id: record.clipId), current.mediaType == .audio,
                  current.mediaRef == saved.mediaRef, current.mediaRef == assetId else {
                throw ToolError("Finish pending audio and restore any missing or replaced bindings before reconciling.")
            }
            guard let seconds = record.measuredSeconds, seconds.isFinite, seconds > 0,
                  before.fps > 0, seconds * Double(before.fps) < Double(Int.max) else {
                throw ToolError("Audio needs measured duration evidence before its timing can be reconciled.")
            }
            let baseline = try rescaled(saved, from: record.placementFPS ?? record.fps, to: before.fps)
            record.placedClip = baseline
            record.ownsTiming = record.ownsTiming && Self.sameTiming(baseline, current)
            record.ownsDucking = record.ownsDucking && baseline.volumeTrack == current.volumeTrack
            record.placementFPS = before.fps
            record.pictureEndFrame = pictureEnd
            if record.key.role != .dialogue, record.ownsTiming {
                guard pictureEnd > 0, let location = editor.findClip(id: record.clipId) else { throw ToolError("Place picture before fitting an audio bed.") }
                after.tracks[location.trackIndex].clips[location.clipIndex].durationFrames = pictureEnd
                after.tracks[location.trackIndex].clips[location.clipIndex].trimEndFrame = max(0, secondsToFrame(seconds: seconds, fps: before.fps) - pictureEnd)
            }
            prepared.append(record)
        }
        try reconcile(&after, records: prepared)
        for record in prepared {
            guard let clip = after.tracks.flatMap(\.clips).first(where: { $0.id == record.clipId }),
                  clip.startFrame >= 0, clip.durationFrames > 0, clip.trimStartFrame >= 0,
                  clip.speed.isFinite, clip.speed > 0,
                  Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed <= record.measuredSeconds! * Double(after.fps) + 1,
                  clip.fadeInFrames + clip.fadeOutFrames <= clip.durationFrames else {
                throw ToolError("Audio coverage or fades do not fit the current cut. Extend the source, shorten the edit, or adjust the fades.")
            }
            if record.key.role != .dialogue, clip.endFrame > pictureEnd {
                throw ToolError("A manually timed audio bed extends beyond picture. Trim it before reconciling.")
            }
        }
        for track in after.tracks where track.type == .audio {
            for record in prepared {
                guard let clip = track.clips.first(where: { $0.id == record.clipId }) else { continue }
                guard !track.clips.contains(where: { $0.id != clip.id && $0.startFrame < clip.endFrame && clip.startFrame < $0.endFrame }) else {
                    throw ToolError("Reconciled audio overlaps another clip on its track. Adjust the edit first.")
                }
            }
        }
        var states: [String: LayoutState] = [:]
        for record in prepared {
            var state = LayoutState(record)
            state.placedClip = after.tracks.flatMap(\.clips).first { $0.id == record.clipId }
            states[record.id] = state
        }
        let priorStates = Dictionary(uniqueKeysWithValues: records.map { ($0.id, LayoutState($0)) })
        let changed = prepared.filter { record in
            editor.clipFor(id: record.clipId) != states[record.id]?.placedClip
        }.count
        return .init(timeline: after, states: states, hasChanges: after != before || states != priorStates, changedClipCount: changed)
    }

    private func applyLayout(timeline: Timeline, states: [String: LayoutState]) {
        guard let editor else { return }
        let previousTimeline = editor.timeline
        let previousStates = Dictionary(uniqueKeysWithValues: states.keys.compactMap { id in operation(id).map { (id, LayoutState($0)) } })
        editor.timeline = timeline
        for (id, state) in states {
            mutate(id) {
                $0.placedClip = state.placedClip
                $0.placementFPS = state.placementFPS
                $0.pictureEndFrame = state.pictureEndFrame
                $0.ownsTiming = state.ownsTiming
                $0.ownsDucking = state.ownsDucking
            }
        }
        editor.undoManager?.registerUndo(withTarget: self) { coordinator in
            coordinator.applyLayout(timeline: previousTimeline, states: previousStates)
        }
        editor.undoManager?.setActionName("Reconcile Audio")
        editor.onProjectContentChanged?()
        editor.onProjectCheckpointRequired?()
        editor.notifyTimelineChanged()
    }

    private func rescaled(_ clip: Clip, from oldFPS: Int, to newFPS: Int) throws -> Clip {
        guard oldFPS > 0, newFPS > 0 else { throw ToolError("Audio has an invalid frame-rate binding.") }
        guard oldFPS != newFPS else { return clip }
        let scale = Double(newFPS) / Double(oldFPS)
        func frame(_ value: Int) throws -> Int {
            let result = (Double(value) * scale).rounded()
            guard result.isFinite, result >= 0, result < Double(Int.max) else { throw ToolError("Audio timing exceeds the supported frame range.") }
            return Int(result)
        }
        var result = clip
        result.startFrame = try frame(clip.startFrame)
        result.durationFrames = try max(1, frame(clip.endFrame) - result.startFrame)
        result.trimStartFrame = try frame(clip.trimStartFrame)
        result.trimEndFrame = try frame(clip.trimEndFrame)
        result.fadeInFrames = try frame(clip.fadeInFrames)
        result.fadeOutFrames = try frame(clip.fadeOutFrames)
        result.rescaleKeyframes(by: scale)
        result.clampKeyframesToDuration()
        result.clampFadesToDuration()
        return result
    }
}
