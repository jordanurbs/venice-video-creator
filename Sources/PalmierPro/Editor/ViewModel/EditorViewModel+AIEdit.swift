import Foundation

extension EditorViewModel {
    var aiEditAllowed: Bool {
        AccountService.shared.isSignedIn && !AccountService.shared.isMisconfigured
    }

    /// The video model to prefer when seeding the generation panel: the last one
    /// used this session, else the most recently generated video asset's model.
    var lastUsedVideoModelId: String? {
        if let id = lastUsedVideoModelIdOverride,
           VideoModelConfig.allModels.contains(where: { $0.id == id }) {
            return id
        }
        return mediaAssets
            .compactMap { asset -> (String, Date)? in
                guard asset.type == .video, let gen = asset.generationInput,
                      VideoModelConfig.allModels.contains(where: { $0.id == gen.model }) else { return nil }
                return (gen.model, gen.createdAt ?? .distantPast)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }

    /// Called on every submission so the panel remembers the project's last video model.
    func recordUsedModel(id: String, assetType: ClipType) {
        guard assetType == .video,
              VideoModelConfig.allModels.contains(where: { $0.id == id }) else { return }
        lastUsedVideoModelIdOverride = id
    }

    func aiEditActions(clipId: String) -> [EditAction] {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual else { return [] }
        return EditAction.available(
            for: asset,
            effectiveDurationOverride: aiEditTrimmedSource(clip: clip, asset: asset)?.durationSeconds
        )
    }

    func aiEditUpscaleModels(clipId: String) -> [UpscaleModelConfig] {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return [] }
        return UpscaleModelConfig.models(for: asset.type)
    }

    // MARK: - Clip-aware actions (trim + replace-on-complete where applicable)

    /// Edit: seed the panel with the trimmed range, replacing the clip's source on completion.
    func beginAIEdit(clipId: String) {
        guard let (clip, asset) = aiEditClipAsset(clipId), clip.mediaType.isVisual,
              let stored = EditSubmitter.editSeed(for: asset, preferredModelId: lastUsedVideoModelId) else { return }
        seedGenerationPanel(
            asset: asset,
            stored: stored,
            replacementClipId: clipId,
            trimmedSource: aiEditTrimmedSource(clip: clip, asset: asset)
        )
    }

    func runAIUpscale(clipId: String, model: UpscaleModelConfig) {
        guard let (clip, asset) = aiEditClipAsset(clipId) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        let handlers = clipReplacementHandlers(clipId: clipId, resetTrim: trim != nil)
        _ = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: self,
            trimmedSource: trim,
            onComplete: handlers.onComplete,
            onFailure: handlers.onFailure
        )
    }

    /// Music/SFX: output is new audio, so no source replacement — place it on the timeline at the clip.
    func beginAIVideoAudio(clipId: String, kind: VideoToAudioEditKind) {
        guard let (clip, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.videoAudioSeed(for: asset, kind: kind) else { return }
        let trim = aiEditTrimmedSource(clip: clip, asset: asset)
        let span = trim?.durationSeconds
            ?? (asset.duration > 0 ? asset.duration : Double(clip.durationFrames) / Double(max(1, timeline.fps)))
        let placement = PendingAudioPlacement(
            startFrame: clip.startFrame,
            spanSeconds: max(span, 1 / Double(max(1, timeline.fps))),
            actionName: kind.timelineActionName
        )
        seedGenerationPanel(asset: asset, stored: stored, trimmedSource: trim, audioPlacement: placement)
    }

    func beginAIRerun(clipId: String) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        let modelId = asset.generationInput?.model ?? ""
        if UpscaleModelConfig.allIds.contains(modelId) {
            let handlers = clipReplacementHandlers(clipId: clipId, resetTrim: false)
            _ = try? EditSubmitter.rerun(
                asset: asset, editor: self,
                onComplete: handlers.onComplete, onFailure: handlers.onFailure
            )
        } else if let stored = asset.generationInput {
            seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
        }
    }

    func beginAICreateVideo(clipId: String, asReference: Bool) {
        guard let (_, asset) = aiEditClipAsset(clipId),
              let stored = EditSubmitter.createVideoSeed(for: asset, asReference: asReference, preferredModelId: lastUsedVideoModelId) else { return }
        seedGenerationPanel(asset: asset, stored: stored, replacementClipId: clipId)
    }

    func beginAILastFrameToVideo(clipId: String) {
        guard let (_, asset) = aiEditClipAsset(clipId) else { return }
        createVideoFromLastFrame(asset: asset, clipId: clipId)
    }

    /// Captures the clip's final visible frame as a still, adds it to the media
    /// library, then opens the generation panel with it set as the first frame.
    func createVideoFromLastFrame(asset: MediaAsset, clipId: String?) {
        guard asset.type == .video else { return }
        let seconds = lastFrameSeconds(asset: asset, clipId: clipId)
        let url = asset.url
        let folderId = asset.folderId
        let baseName = aiEditStripPrefix(asset.name)
        Task { @MainActor in
            guard let data = await LastFrameExtractor.pngData(url: url, atSeconds: seconds),
                  let frameAsset = await importPastedImageData(data, fileExtension: "png") else { return }
            frameAsset.name = "Last frame · \(baseName)"
            if let idx = mediaManifest.entries.firstIndex(where: { $0.id == frameAsset.id }) {
                mediaManifest.entries[idx].name = frameAsset.name
            }
            moveAssetsToFolder(assetIds: [frameAsset.id], folderId: folderId)
            guard let stored = EditSubmitter.createVideoSeed(for: frameAsset, asReference: false, preferredModelId: lastUsedVideoModelId) else { return }
            seedGenerationPanel(asset: frameAsset, stored: stored)
        }
    }

    /// Source time (seconds) of the clip's last visible frame, mapped through the
    /// same trim/speed math the renderer uses. Falls back to the asset's end.
    private func lastFrameSeconds(asset: MediaAsset, clipId: String?) -> Double {
        if let clipId, let clip = clipFor(id: clipId), clip.mediaType == .video {
            let fps = Double(max(1, timeline.fps))
            let sourceFrame = Double(clip.trimStartFrame) + Double(max(0, clip.durationFrames - 1)) * clip.speed
            return sourceFrame / fps
        }
        return max(0, asset.duration - 0.05)
    }

    private func aiEditStripPrefix(_ name: String) -> String {
        for prefix in ["Upscaled ", "Edited ", "Rerun ", "Last frame · "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    func seedGenerationPanel(
        asset: MediaAsset,
        stored: GenerationInput,
        replacementClipId: String? = nil,
        trimmedSource: TrimmedSource? = nil,
        audioPlacement: PendingAudioPlacement? = nil
    ) {
        pendingEditReplacementClipId = replacementClipId
        pendingEditTrimmedSource = trimmedSource
        pendingEditAudioPlacement = audioPlacement
        pendingPanelSeed = PendingPanelSeed(asset: asset, stored: stored)
        showGenerationPanel = true
    }

    private func aiEditClipAsset(_ clipId: String) -> (clip: Clip, asset: MediaAsset)? {
        guard let clip = clipFor(id: clipId),
              let asset = mediaAssets.first(where: { $0.id == clip.mediaRef }) else { return nil }
        return (clip, asset)
    }

    private func aiEditTrimmedSource(clip: Clip, asset: MediaAsset) -> TrimmedSource? {
        guard asset.type == .video, clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: asset.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: timeline.fps
        )
    }

    /// onComplete/onFailure for a direct (non-panel) submission that replaces the clip's source.
    private func clipReplacementHandlers(
        clipId: String,
        resetTrim: Bool
    ) -> (onComplete: (@MainActor (MediaAsset) -> Void)?, onFailure: (@MainActor () -> Void)?) {
        markPendingReplacement(clipId: clipId)
        let fired = FirstOnlyFlag()
        let onComplete: @MainActor (MediaAsset) -> Void = { [weak self] newAsset in
            guard fired.fire() else { return }
            self?.replaceClipMediaRef(clipId: clipId, newAssetId: newAsset.id, resetTrim: resetTrim)
            self?.clearPendingReplacement(clipId: clipId)
        }
        let onFailure: @MainActor () -> Void = { [weak self] in
            self?.clearPendingReplacement(clipId: clipId)
        }
        return (onComplete, onFailure)
    }
}
