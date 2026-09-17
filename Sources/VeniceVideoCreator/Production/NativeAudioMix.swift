import Foundation

struct NativeAudioMix: Codable, Sendable, Equatable {
    var policy: ShotNativeAudio
    var baseVolumes: [String: Double] = [:]
    var appliedVolumes: [String: Double] = [:]
}

extension EditorViewModel {
    func nativeAudioMix(for placement: ShotPlacement, policy: ShotNativeAudio, previous: NativeAudioMix?) -> NativeAudioMix {
        var mix = previous ?? NativeAudioMix(policy: policy)
        let gain = nativeAudioGain(policy)
        for id in [placement.videoClipId] + placement.linkedAudioClipIds {
            guard let clip = clipFor(id: id) else { continue }
            if previous?.appliedVolumes[id] != clip.volume {
                mix.baseVolumes[id] = previous?.appliedVolumes[id] == nil && clip.volume == gain ? 1 : clip.volume
            }
            mix.appliedVolumes[id] = clip.volume
        }
        mix.policy = policy
        return mix
    }

    func validateNativeAudioPolicyChanges(_ plan: ShotPlan) throws {
        var plan = plan
        var proposed = timeline
        try applyNativeAudioPolicyChanges(from: shotPlan, to: &plan, timeline: &proposed)
    }

    func applyNativeAudioPolicyChanges(from previous: ShotPlan?, to plan: inout ShotPlan, timeline proposed: inout Timeline) throws {
        for index in plan.shots.indices {
            let shot = plan.shots[index]
            guard let old = previous?.shot(id: shot.id), old.nativeAudio != shot.nativeAudio,
                  var placement = try productionPlacement(for: shot) else { continue }
            guard !plan.shots.contains(where: { $0.id != shot.id && $0.placement?.videoClipId == placement.videoClipId }),
                  let vi = proposed.tracks.indices.first(where: { proposed.tracks[$0].clips.contains { $0.id == placement.videoClipId } }),
                  let ci = proposed.tracks[vi].clips.firstIndex(where: { $0.id == placement.videoClipId }) else {
                throw ToolError("Restore or reconcile the shot's picture clip before changing its native audio mix.")
            }
            var video = proposed.tracks[vi].clips[ci]
            guard video.mediaRef == placement.assetId, video.mediaType == .video else {
                throw ToolError("The shot's picture source changed. Reconcile its placement before changing the mix.")
            }
            for id in placement.linkedAudioClipIds {
                guard let audio = proposed.tracks.flatMap(\.clips).first(where: { $0.id == id }), audio.mediaType == .audio,
                      audio.mediaRef == placement.assetId, video.linkGroupId != nil, audio.linkGroupId == video.linkGroupId else {
                    throw ToolError("Native audio was removed or detached. Restore its link or reconcile the placement before changing the mix.")
                }
            }
            var mix = nativeAudioMix(for: placement, policy: old.nativeAudio, previous: placement.nativeAudioMix)
            if placement.linkedAudioClipIds.isEmpty, mediaAssets.first(where: { $0.id == placement.assetId })?.hasAudio == true {
                guard !proposed.tracks.filter({ $0.type == .audio }).flatMap(\.clips).contains(where: {
                    $0.mediaRef == video.mediaRef && $0.startFrame < video.endFrame && video.startFrame < $0.endFrame
                }) else { throw ToolError("Native audio is already present without a binding. Reconcile its link before restoring audio.") }
                let group = video.linkGroupId ?? UUID().uuidString
                video.linkGroupId = group
                proposed.tracks[vi].clips[ci] = video
                var audio = Clip(mediaRef: video.mediaRef, mediaType: .audio, sourceClipType: .video,
                                 startFrame: video.startFrame, durationFrames: video.durationFrames)
                audio.trimStartFrame = video.trimStartFrame
                audio.trimEndFrame = video.trimEndFrame
                audio.speed = video.speed
                audio.linkGroupId = group
                placement.linkedAudioClipIds = [audio.id]
                mix.baseVolumes[audio.id] = mix.baseVolumes[video.id] ?? 1
                proposed.tracks.append(Track(type: .audio, clips: [audio]))
            }
            let ids = Set([placement.videoClipId] + placement.linkedAudioClipIds)
            let gain = nativeAudioGain(shot.nativeAudio)
            for ti in proposed.tracks.indices {
                for ai in proposed.tracks[ti].clips.indices where ids.contains(proposed.tracks[ti].clips[ai].id) {
                    let id = proposed.tracks[ti].clips[ai].id
                    let base = mix.baseVolumes[id] ?? proposed.tracks[ti].clips[ai].volume
                    guard base.isFinite, base >= 0 else { throw ToolError("Native audio has an invalid volume. Correct the clip mix first.") }
                    proposed.tracks[ti].clips[ai].volume = base * gain
                    mix.appliedVolumes[id] = base * gain
                }
            }
            mix.policy = shot.nativeAudio
            placement.nativeAudioMix = mix
            plan.shots[index].placement = placement
        }
    }

    private func nativeAudioGain(_ policy: ShotNativeAudio) -> Double {
        switch policy { case .keep: 1; case .duck: 0.3; case .mute: 0 }
    }
}
