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

    /// Finds the timeline clip currently backed by `assetId` (a placed shot's video), if any.
    func productionClipId(forAsset assetId: String) -> String? {
        for track in timeline.tracks where track.type == .video {
            if let clip = track.clips.first(where: { $0.mediaRef == assetId }) {
                return clip.id
            }
        }
        return nil
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
