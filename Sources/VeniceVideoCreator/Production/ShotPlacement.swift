import Foundation

struct ShotSourceRange: Codable, Sendable, Equatable {
    var startSeconds: Double
    var endSeconds: Double
}

struct ShotPlacement: Codable, Sendable, Equatable {
    var videoClipId: String
    var linkedAudioClipIds: [String]
    var assetId: String
    var takeId: String?
    var productionUnitId: String?
    // Assigned source window; subsequent manual trims remain on the bound clips.
    var sourceRange: ShotSourceRange
    var nativeAudioMix: NativeAudioMix?

    var destinationBinding: ShotPlacement {
        var binding = self
        binding.nativeAudioMix = nil
        return binding
    }
}

extension EditorViewModel {
    @discardableResult
    func placeProductionShot(asset: MediaAsset, shotId: String, sourceSegment: ClosedRange<Double>? = nil,
                             actionName: String = "Place Shot") throws -> ShotPlacement {
        guard let shot = shot(id: shotId) else { throw ToolError("Shot not found: \(shotId)") }
        guard asset.type == .video, asset.duration.isFinite, asset.duration > 0 else {
            throw ToolError("Shot placement requires a video with a measured duration.")
        }
        let range = ShotSourceRange(startSeconds: sourceSegment?.lowerBound ?? 0,
                                    endSeconds: sourceSegment?.upperBound ?? asset.duration)
        guard range.startSeconds.isFinite, range.endSeconds.isFinite,
              range.startSeconds >= 0, range.endSeconds > range.startSeconds,
              range.endSeconds <= asset.duration else { throw ToolError("Shot source range exceeds the generated video.") }
        let previous = try productionPlacement(for: shot)
        let existing = try productionClip(for: shot)
        let sourceStart = secondsToFrame(seconds: range.startSeconds, fps: timeline.fps)
        let sourceEnd = secondsToFrame(seconds: range.endSeconds, fps: timeline.fps)
        let totalFrames = secondsToFrame(seconds: asset.duration, fps: timeline.fps)
        guard sourceEnd > sourceStart else { throw ToolError("Shot source range contains no frames.") }
        var replacements: [Clip] = []
        if let existing, let previous {
            let oldStart = secondsToFrame(seconds: previous.sourceRange.startSeconds, fps: timeline.fps)
            let ids = [existing.id] + previous.linkedAudioClipIds
            for id in ids {
                guard var clip = clipFor(id: id), clip.mediaRef == previous.assetId else {
                    throw ToolError("Shot's placed clip group changed. Reconcile its placement before replacing it.")
                }
                guard clip.linkGroupId == existing.linkGroupId else {
                    throw ToolError("Shot audio was unlinked. Reconcile its placement before replacing it.")
                }
                let offset = clip.trimStartFrame - oldStart
                let consumed = Int((Double(clip.durationFrames) * clip.speed).rounded())
                guard offset >= 0, consumed > 0, sourceStart + offset + consumed <= sourceEnd else {
                    throw ToolError("The new take does not cover the shot's edited source range. Adjust the trim or choose a longer take.")
                }
                clip.mediaRef = asset.id
                clip.trimStartFrame = sourceStart + offset
                clip.trimEndFrame = totalFrames - clip.trimStartFrame - consumed
                replacements.append(clip)
            }
        }

        undoManager?.beginUndoGrouping()
        defer { undoManager?.setActionName(actionName); undoManager?.endUndoGrouping() }
        let before = timeline
        undoManager?.disableUndoRegistration()
        let clipId: String
        if let existing {
            clipId = existing.id
            for clip in replacements {
                if let loc = findClip(id: clip.id) { timeline.tracks[loc.trackIndex].clips[loc.clipIndex] = clip }
            }
            if !asset.hasAudio, let previous {
                for index in timeline.tracks.indices {
                    timeline.tracks[index].clips.removeAll { previous.linkedAudioClipIds.contains($0.id) }
                }
                if let loc = findClip(id: clipId) { timeline.tracks[loc.trackIndex].clips[loc.clipIndex].linkGroupId = nil }
            } else if asset.hasAudio, previous?.linkedAudioClipIds.isEmpty == true, let video = clipFor(id: clipId) {
                let groupId = UUID().uuidString
                let audioIndex = resolveOrCreateAudioTrack(startFrame: video.startFrame, duration: video.durationFrames)
                var audio = Clip(mediaRef: asset.id, mediaType: .audio, sourceClipType: .video,
                                 startFrame: video.startFrame, durationFrames: video.durationFrames)
                audio.linkGroupId = groupId
                audio.trimStartFrame = video.trimStartFrame
                audio.trimEndFrame = video.trimEndFrame
                audio.speed = video.speed
                audio.volume = ShotPromptBuilder.placedClipVolume(for: shot)
                timeline.tracks[audioIndex].clips.append(audio)
                if let loc = findClip(id: clipId) { timeline.tracks[loc.trackIndex].clips[loc.clipIndex].linkGroupId = groupId }
            }
        } else {
            let trackIndex = productionVideoTrackIndex()
            let startFrame = timeline.tracks[trackIndex].endFrame
            let ids = placeClip(asset: asset, trackIndex: trackIndex, startFrame: startFrame,
                                durationFrames: sourceEnd - sourceStart,
                                sourceSegment: range.startSeconds...range.endSeconds)
            clipId = ids[0]
            for id in ids {
                if let loc = findClip(id: id) {
                    timeline.tracks[loc.trackIndex].clips[loc.clipIndex].volume = ShotPromptBuilder.placedClipVolume(for: shot)
                }
            }
        }
        undoManager?.enableUndoRegistration()
        let take = shot.takes.last { $0.videoAssetId == asset.id }
        var placement = makeProductionPlacement(clip: clipFor(id: clipId)!, take: take, sourceRange: range)
        placement.nativeAudioMix = nativeAudioMix(for: placement, policy: shot.nativeAudio, previous: previous?.nativeAudioMix)
        registerTimelineSwap(undoState: before, redoState: timeline, actionName: actionName)
        mutateShotPlan(actionName: actionName) { plan in
            guard let index = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[index].placement = placement
            plan.shots[index].videoAssetId = asset.id
            plan.shots[index].status = .placed
            if let takeIndex = plan.shots[index].takes.firstIndex(where: { $0.id == take?.id }) {
                plan.shots[index].takes[takeIndex].sourceRange = range
            }
        }
        notifyTimelineChanged()
        return placement
    }

    func productionPlacement(for shot: Shot) throws -> ShotPlacement? {
        if let placement = shot.placement { return placement }
        guard let assetId = shot.videoAssetId else { return nil }
        let matches = timeline.tracks.filter { $0.type == .video }.flatMap(\.clips).filter { $0.mediaRef == assetId }
        guard !matches.isEmpty else { return nil }
        guard matches.count == 1,
              shotPlan?.shots.filter({ $0.videoAssetId == assetId || $0.placement?.assetId == assetId }).count == 1 else {
            throw ToolError("Shot \(shot.slug ?? shot.id) has an ambiguous legacy clip binding. Use update_shots with placedClipId to bind its intended timeline clip before producing or resetting.")
        }
        return try productionPlacement(for: shot, clipId: matches[0].id, plan: shotPlan ?? ShotPlan(shots: [shot]))
    }

    func productionPlacement(for shot: Shot, clipId: String, plan: ShotPlan) throws -> ShotPlacement {
        guard let clip = clipFor(id: clipId), clip.mediaType == .video else { throw ToolError("Video clip not found: \(clipId)") }
        guard !plan.shots.contains(where: { $0.id != shot.id && $0.placement?.videoClipId == clipId }) else {
            throw ToolError("Timeline clip is already bound to another shot.")
        }
        guard shot.videoAssetId == nil || shot.videoAssetId == clip.mediaRef || shot.takes.contains(where: { $0.videoAssetId == clip.mediaRef }) else {
            throw ToolError("Timeline clip does not reference a take belonging to this shot.")
        }
        let linkedVideos = timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType == .video && clip.linkGroupId != nil && $0.linkGroupId == clip.linkGroupId
        }
        guard linkedVideos.count <= 1 else { throw ToolError("Unlink the shot from other video clips before binding its placement.") }
        let fps = Double(max(1, timeline.fps))
        let takes = shot.takes.filter { $0.videoAssetId == clip.mediaRef }
        return makeProductionPlacement(
            clip: clip, take: takes.count == 1 ? takes[0] : nil,
            sourceRange: .init(startSeconds: Double(clip.trimStartFrame) / fps,
                               endSeconds: (Double(clip.trimStartFrame) + Double(clip.durationFrames) * clip.speed) / fps)
        )
    }

    func productionClip(for shot: Shot) throws -> Clip? {
        guard let placement = try productionPlacement(for: shot) else { return nil }
        guard shotPlan?.shots.contains(where: { $0.id != shot.id && $0.placement?.videoClipId == placement.videoClipId }) != true else {
            throw ToolError("Timeline clip is bound to multiple shots. Reconcile the shot placements before producing.")
        }
        guard let clip = clipFor(id: placement.videoClipId) else {
            throw ToolError("Shot \(shot.slug ?? shot.id)'s bound clip was removed. Restore the clip or reset the shot before producing.")
        }
        guard clip.mediaRef == placement.assetId, clip.mediaType == .video else {
            throw ToolError("Shot \(shot.slug ?? shot.id)'s bound clip source changed. Reconcile its placement before producing.")
        }
        return clip
    }

    func productionClipIdsForReset(_ shot: Shot) throws -> Set<String> {
        guard let placement = try productionPlacement(for: shot) else { return [] }
        guard shotPlan?.shots.contains(where: { $0.id != shot.id && $0.placement?.videoClipId == placement.videoClipId }) != true else {
            throw ToolError("Timeline clip is bound to multiple shots. Reconcile the shot placements before resetting.")
        }
        return try Set(([placement.videoClipId] + placement.linkedAudioClipIds).compactMap { id in
            guard let clip = clipFor(id: id) else { return nil }
            if id != placement.videoClipId, let video = clipFor(id: placement.videoClipId),
               clip.linkGroupId == nil || clip.linkGroupId != video.linkGroupId { return nil }
            guard clip.mediaRef == placement.assetId else {
                throw ToolError("Shot \(shot.slug ?? shot.id)'s bound clip source changed. Reconcile its placement before resetting.")
            }
            return id
        })
    }

    func makeProductionPlacement(clip: Clip, take: ShotTake?, sourceRange: ShotSourceRange) -> ShotPlacement {
        let audio = timeline.tracks.flatMap(\.clips).filter {
            $0.mediaType == .audio && $0.mediaRef == clip.mediaRef && clip.linkGroupId != nil && $0.linkGroupId == clip.linkGroupId
        }
        return ShotPlacement(videoClipId: clip.id, linkedAudioClipIds: audio.map(\.id), assetId: clip.mediaRef,
                             takeId: take?.id, productionUnitId: take?.productionUnitId, sourceRange: sourceRange)
    }

    func reconcileLegacyProductionPlacements() {
        guard let plan = shotPlan else { return }
        var bindings: [String: ShotPlacement] = [:]
        for shot in plan.shots where shot.placement == nil {
            if let placement = try? productionPlacement(for: shot) { bindings[shot.id] = placement }
        }
        guard !bindings.isEmpty else { return }
        mutateShotPlan(actionName: "Reconcile Shot Placements") { plan in
            for index in plan.shots.indices {
                if let binding = bindings[plan.shots[index].id] { plan.shots[index].placement = binding }
            }
        }
    }
}
