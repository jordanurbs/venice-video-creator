import Foundation

extension EditorViewModel {
    struct TimelineSpan: Equatable, Sendable {
        var startFrame: Int
        var frameCount: Int
    }

    func selectedTimelineSpan() -> TimelineSpan? {
        if let range = validSelectedTimelineRange {
            let count = range.endFrame - range.startFrame
            guard count > 0 else { return nil }
            return TimelineSpan(startFrame: range.startFrame, frameCount: count)
        }
        let total = timeline.totalFrames
        guard total > 0 else { return nil }
        return TimelineSpan(startFrame: 0, frameCount: total)
    }

    @discardableResult
    func placeGeneratingAudioClip(
        placeholderId: String,
        startFrame: Int,
        spanSeconds: Double,
        actionName: String
    ) -> String? {
        guard let asset = mediaAssets.first(where: { $0.id == placeholderId }) else { return nil }
        let durationFrames = max(1, secondsToFrame(seconds: spanSeconds, fps: timeline.fps))

        let before = timeline
        undoManager?.disableUndoRegistration()
        let trackIdx = resolveOrCreateAudioTrack(startFrame: startFrame, duration: durationFrames)
        let ids = placeClip(
            asset: asset,
            trackIndex: trackIdx,
            startFrame: startFrame,
            durationFrames: durationFrames,
            addLinkedAudio: false
        )
        undoManager?.enableUndoRegistration()
        guard let clipId = ids.first else {
            timeline = before
            return nil
        }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
        notifyTimelineChanged()
        return clipId
    }

    func finalizeGeneratingClip(placeholderId: String, asset: MediaAsset) {
        guard let loc = findClipLocationByMediaRef(placeholderId) else { return }
        let realFrames = max(1, secondsToFrame(seconds: asset.duration, fps: timeline.fps))
        undoManager?.disableUndoRegistration()
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames = realFrames
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimStartFrame = 0
        timeline.tracks[loc.trackIndex].clips[loc.clipIndex].trimEndFrame = 0
        undoManager?.enableUndoRegistration()
        notifyTimelineChanged()
    }

    /// Re-flows an ordered dialogue lane once real clip lengths land so no two
    /// lines overlap (harness rules 35/36). Each entry keeps its scheduled
    /// `desiredStart` unless the prior (now-measured) clip runs into it, in
    /// which case it slides forward by `gapFrames`. A dialogue clip that ran
    /// long therefore ripples the later lines instead of overlapping them.
    func reflowProductionDialogueLane(
        _ ordered: [(clipId: String, desiredStart: Int)],
        gapFrames: Int
    ) {
        var located: [(loc: ClipLocation, desired: Int, dur: Int)] = []
        for entry in ordered {
            guard let loc = findClip(id: entry.clipId) else { continue }
            let dur = timeline.tracks[loc.trackIndex].clips[loc.clipIndex].durationFrames
            located.append((loc, entry.desiredStart, dur))
        }
        guard !located.isEmpty else { return }
        let starts = DialogueScheduler.reflow(
            desiredStarts: located.map(\.desired),
            durations: located.map(\.dur),
            gapFrames: gapFrames
        )
        var changed = false
        undoManager?.disableUndoRegistration()
        for (i, item) in located.enumerated() where
            timeline.tracks[item.loc.trackIndex].clips[item.loc.clipIndex].startFrame != starts[i] {
            timeline.tracks[item.loc.trackIndex].clips[item.loc.clipIndex].startFrame = starts[i]
            changed = true
        }
        undoManager?.enableUndoRegistration()
        if changed { notifyTimelineChanged() }
    }

    /// Ducks a placed music/ambient bed clip under every dialogue window with
    /// volume keyframes (full level → `duckVolume` across each window with short
    /// ramps), replacing static full-volume beds (harness auto-duck). Windows
    /// are absolute timeline frames; converted to clip-relative here.
    func duckBedUnderDialogue(
        bedClipId: String,
        windows: [ClosedRange<Int>],
        duckVolume: Double = 0.25,
        rampSeconds: Double = 0.3
    ) {
        guard !windows.isEmpty, let loc = findClip(id: bedClipId) else { return }
        let bed = timeline.tracks[loc.trackIndex].clips[loc.clipIndex]
        let bedStart = bed.startFrame
        let bedFrames = bed.durationFrames
        let relative = windows.map { max(0, $0.lowerBound - bedStart)...max(0, $0.upperBound - bedStart) }
        let ramp = max(1, secondsToFrame(seconds: rampSeconds, fps: timeline.fps))
        let points = DialogueScheduler.duckKeyframes(
            windows: relative, baseVolume: bed.volume, duckVolume: duckVolume,
            rampFrames: ramp, clipFrames: bedFrames
        )
        guard points.count > 1 else { return }
        var track = KeyframeTrack<Double>()
        for p in points { track.upsert(Keyframe(frame: p.frame, value: p.value, interpolationOut: .linear)) }
        commitClipProperty(clipId: bedClipId) { $0.volumeTrack = track }
    }

    /// Index of the first video track, creating one if the timeline has none. Used by the
    /// production orchestrator to lay shots down on a dedicated visual lane.
    func productionVideoTrackIndex() -> Int {
        if zones.firstAudioIndex > 0 { return 0 }
        return insertTrack(at: 0, type: .video)
    }

    /// Appends a finished shot's video clip at the end of the production video track (in shot
    /// order). Returns the clip id and start frame. Undoable as one swap.
    @discardableResult
    func placeProductionShotClip(asset: MediaAsset, actionName: String) -> (clipId: String, startFrame: Int)? {
        let trackIdx = productionVideoTrackIndex()
        guard timeline.tracks.indices.contains(trackIdx) else { return nil }
        let startFrame = timeline.tracks[trackIdx].endFrame
        let durationFrames = max(1, secondsToFrame(seconds: asset.duration, fps: timeline.fps))
        let before = timeline
        let ids = placeClip(
            asset: asset,
            trackIndex: trackIdx,
            startFrame: startFrame,
            durationFrames: durationFrames
        )
        guard let clipId = ids.first else { return nil }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
        notifyTimelineChanged()
        return (clipId, startFrame)
    }

    /// Appends one beat of a multi-shot unit's video at the end of the production
    /// track: the clip shows only `sourceSegment` (source seconds) of the shared
    /// asset, so one generated take fans out into per-shot clips. Undoable as
    /// one swap per clip.
    @discardableResult
    func placeProductionUnitClip(
        asset: MediaAsset,
        sourceSegment: ClosedRange<Double>,
        actionName: String
    ) -> String? {
        let trackIdx = productionVideoTrackIndex()
        guard timeline.tracks.indices.contains(trackIdx) else { return nil }
        let startFrame = timeline.tracks[trackIdx].endFrame
        let visibleSeconds = max(0.1, sourceSegment.upperBound - sourceSegment.lowerBound)
        let durationFrames = max(1, secondsToFrame(seconds: visibleSeconds, fps: timeline.fps))
        let before = timeline
        let ids = placeClip(
            asset: asset,
            trackIndex: trackIdx,
            startFrame: startFrame,
            durationFrames: durationFrames,
            sourceSegment: sourceSegment
        )
        guard let clipId = ids.first else { return nil }
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
        notifyTimelineChanged()
        return clipId
    }

    /// Re-sorts the production track's shot clips into PLAN order and re-packs
    /// them back-to-back. With parallel production, shots finish (and get
    /// appended) out of order — S5 must not sit before S4 in the edit just
    /// because it rendered faster.
    func reorderProductionClipsToPlanOrder() {
        guard let plan = shotPlan else { return }
        let trackIdx = productionVideoTrackIndex()
        guard timeline.tracks.indices.contains(trackIdx) else { return }

        // Shot order index per video asset id (multi-shot units share an asset;
        // their per-beat clips keep their relative order via stable sort).
        var orderByAsset: [String: Int] = [:]
        for (i, shot) in plan.shots.enumerated() {
            if let aid = shot.videoAssetId, orderByAsset[aid] == nil { orderByAsset[aid] = i }
        }

        let track = timeline.tracks[trackIdx]
        let shotClips = track.clips.filter { orderByAsset[$0.mediaRef] != nil }
        guard shotClips.count > 1 else { return }

        let sorted = shotClips.enumerated().sorted { a, b in
            let oa = orderByAsset[a.element.mediaRef] ?? Int.max
            let ob = orderByAsset[b.element.mediaRef] ?? Int.max
            return oa == ob ? a.offset < b.offset : oa < ob
        }.map(\.element)
        guard sorted.map(\.id) != shotClips.map(\.id) else { return }

        let before = timeline
        undoManager?.disableUndoRegistration()
        var cursor = shotClips.map(\.startFrame).min() ?? 0
        var repacked = sorted
        for i in repacked.indices {
            repacked[i].startFrame = cursor
            cursor += repacked[i].durationFrames
        }
        let shotClipIds = Set(shotClips.map(\.id))
        var newClips = timeline.tracks[trackIdx].clips.filter { !shotClipIds.contains($0.id) }
        newClips.append(contentsOf: repacked)
        timeline.tracks[trackIdx].clips = newClips.sorted { $0.startFrame < $1.startFrame }
        undoManager?.enableUndoRegistration()
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Reorder Shots")
        notifyTimelineChanged()
    }

    /// Finds the timeline clip currently backed by `assetId` (a placed shot's video), if any.
    /// `occurrence` disambiguates when one asset backs several clips (a multi-shot
    /// unit's video fans out into per-beat clips): 0 = first clip in track order.
    func productionClipId(forAsset assetId: String, occurrence: Int = 0) -> String? {
        var matches: [String] = []
        for track in timeline.tracks where track.type == .video {
            for clip in track.clips where clip.mediaRef == assetId {
                matches.append(clip.id)
            }
        }
        guard occurrence >= 0, occurrence < matches.count else { return matches.first }
        return matches[occurrence]
    }

    private func findClipLocationByMediaRef(_ mediaRef: String) -> ClipLocation? {
        for ti in timeline.tracks.indices {
            if let ci = timeline.tracks[ti].clips.firstIndex(where: { $0.mediaRef == mediaRef }) {
                return ClipLocation(trackIndex: ti, clipIndex: ci)
            }
        }
        return nil
    }
}
