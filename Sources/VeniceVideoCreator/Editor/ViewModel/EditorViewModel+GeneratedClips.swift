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
            windows: relative, baseVolume: 1, duckVolume: duckVolume,
            rampFrames: ramp, clipFrames: bedFrames
        )
        guard points.count > 1 else { return }
        var track = KeyframeTrack<Double>()
        for p in points { track.upsert(Keyframe(frame: p.frame, value: VolumeScale.dbFromLinear(p.value), interpolationOut: .linear)) }
        commitClipProperty(clipId: bedClipId) { $0.volumeTrack = track }
    }

    /// Index of the first video track, creating one if the timeline has none. Used by the
    /// production orchestrator to lay shots down on a dedicated visual lane.
    func productionVideoTrackIndex() -> Int {
        if zones.firstAudioIndex > 0 { return 0 }
        return insertTrack(at: 0, type: .video)
    }

    /// Re-sorts the production track's shot clips into PLAN order and re-packs
    /// them back-to-back. With parallel production, shots finish (and get
    /// appended) out of order — S5 must not sit before S4 in the edit just
    /// because it rendered faster.
    func reorderProductionClipsToPlanOrder() {
        guard let plan = shotPlan else { return }
        let trackIdx = productionVideoTrackIndex()
        guard timeline.tracks.indices.contains(trackIdx) else { return }

        var orderByClip: [String: Int] = [:]
        for (i, shot) in plan.shots.enumerated() {
            do {
                if let clip = try productionClip(for: shot) { orderByClip[clip.id] = i }
            } catch {
                editorToast = MediaPanelToast(message: error.localizedDescription)
                return
            }
        }

        let track = timeline.tracks[trackIdx]
        let shotClips = track.clips.filter { orderByClip[$0.id] != nil }.sorted { $0.startFrame < $1.startFrame }
        guard shotClips.count > 1 else { return }

        let sorted = shotClips.enumerated().sorted { a, b in
            let oa = orderByClip[a.element.id] ?? Int.max
            let ob = orderByClip[b.element.id] ?? Int.max
            return oa == ob ? a.offset < b.offset : oa < ob
        }.map(\.element)
        guard sorted.map(\.id) != shotClips.map(\.id) else { return }

        let before = timeline
        var after = timeline
        var cursor = shotClips.map(\.startFrame).min() ?? 0
        var repacked = sorted
        var moves: [String: Int] = [:]
        for i in repacked.indices {
            let delta = cursor - repacked[i].startFrame
            let members = expandToLinkGroup([repacked[i].id])
            for id in members {
                if let previous = moves[id], previous != delta {
                    editorToast = MediaPanelToast(message: "Unlink shots that share a clip group before reordering production.")
                    return
                }
                moves[id] = delta
            }
            repacked[i].startFrame = cursor
            cursor += repacked[i].durationFrames
        }
        let shotClipIds = Set(shotClips.map(\.id))
        var newClips = track.clips.filter { !shotClipIds.contains($0.id) }
        guard !newClips.contains(where: { manual in repacked.contains { $0.startFrame < manual.endFrame && manual.startFrame < $0.endFrame } }) else {
            editorToast = MediaPanelToast(message: "Production reorder overlaps a manual clip. Move the clip before reordering shots.")
            return
        }
        for ti in after.tracks.indices {
            for ci in after.tracks[ti].clips.indices {
                let clip = after.tracks[ti].clips[ci]
                if let delta = moves[clip.id] {
                    guard clip.startFrame + delta >= 0 else { return }
                    after.tracks[ti].clips[ci].startFrame += delta
                }
            }
            after.tracks[ti].clips.sort { $0.startFrame < $1.startFrame }
        }
        newClips.append(contentsOf: repacked)
        after.tracks[trackIdx].clips = newClips.sorted { $0.startFrame < $1.startFrame }
        for track in after.tracks where track.type == .audio {
            for clip in track.clips where moves[clip.id] != nil {
                for other in track.clips where other.id != clip.id && clip.startFrame < other.endFrame && other.startFrame < clip.endFrame {
                    guard let oldClip = clipFor(id: clip.id), let oldOther = clipFor(id: other.id) else { continue }
                    if oldClip.startFrame >= oldOther.endFrame || oldOther.startFrame >= oldClip.endFrame {
                        editorToast = MediaPanelToast(message: "Production reorder overlaps an audio edit. Adjust the audio track before reordering shots.")
                        return
                    }
                }
            }
        }
        timeline = after
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: "Reorder Shots")
        notifyTimelineChanged()
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
