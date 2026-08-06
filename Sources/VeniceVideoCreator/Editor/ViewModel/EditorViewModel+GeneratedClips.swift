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
