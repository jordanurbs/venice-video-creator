import Foundation

/// Builds and dispatches AI-tab submissions (Upscale, Rerun) pipeline.
@MainActor
enum EditSubmitter {

    /// Marks the source asset busy for the life of the job so a second click
    /// can't submit (and charge for) a duplicate.
    private static func trackJob(
        sourceAssetId: String,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)?,
        onFailure: (@MainActor () -> Void)?
    ) -> (onComplete: @MainActor (MediaAsset) -> Void, onFailure: @MainActor () -> Void) {
        editor.activeAIEditSourceIds.insert(sourceAssetId)
        return (
            { [weak editor] asset in
                editor?.activeAIEditSourceIds.remove(sourceAssetId)
                onComplete?(asset)
            },
            { [weak editor] in
                editor?.activeAIEditSourceIds.remove(sourceAssetId)
                onFailure?()
            }
        )
    }

    // MARK: - Upscale

    @discardableResult
    static func submitUpscale(
        asset: MediaAsset,
        model: UpscaleModelConfig,
        editor: EditorViewModel,
        trimmedSource: TrimmedSource? = nil,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn else { return nil }
        guard model.supportedTypes.contains(asset.type) else { return nil }
        guard !editor.activeAIEditSourceIds.contains(asset.id) else { return nil }
        let tracked = trackJob(sourceAssetId: asset.id, editor: editor, onComplete: onComplete, onFailure: onFailure)

        let effectiveDuration: Int = {
            if let trim = trimmedSource, trim.hasTrim {
                return max(1, Int(trim.durationSeconds.rounded()))
            }
            return max(1, Int(asset.duration.rounded()))
        }()
        let genInput = GenerationInput(
            prompt: "",
            model: model.id,
            duration: effectiveDuration,
            aspectRatio: "",
            resolution: nil
        )

        let isImage = asset.type == .image
        let placeholderDuration: Double
        if isImage {
            placeholderDuration = Defaults.imageDurationSeconds
        } else if let trim = trimmedSource, trim.hasTrim {
            placeholderDuration = trim.durationSeconds
        } else {
            placeholderDuration = asset.duration > 0 ? asset.duration : Double(effectiveDuration)
        }

        let sourceAssetId = asset.id
        return editor.generationService.generate(
            genInput: genInput,
            assetType: asset.type,
            placeholderDuration: placeholderDuration,
            references: [asset],
            trimmedSourceOverride: trimmedSource,
            name: upscaleName(for: asset),
            folderId: asset.folderId,
            buildParams: { uploaded in
                .upscale(UpscaleGenerationParams(
                    sourceURL: uploaded.first ?? "",
                    durationSeconds: isImage ? 1 : effectiveDuration
                ))
            },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = [sourceAssetId]
            },
            fileExtension: isImage ? "jpg" : "mp4",
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: tracked.onComplete,
            onFailure: tracked.onFailure
        )
    }

    // MARK: - Background remove

    @discardableResult
    static func submitBackgroundRemove(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn, asset.type == .image else { return nil }
        guard !editor.activeAIEditSourceIds.contains(asset.id) else { return nil }
        let tracked = trackJob(sourceAssetId: asset.id, editor: editor, onComplete: onComplete, onFailure: onFailure)
        let genInput = GenerationInput(
            prompt: "", model: VeniceBuiltInModel.backgroundRemove,
            duration: 0, aspectRatio: "", resolution: nil
        )
        let sourceAssetId = asset.id
        return editor.generationService.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: [asset],
            name: "Cutout \(stripPrefix(asset.name))",
            folderId: asset.folderId,
            buildParams: { uploaded in
                .backgroundRemove(BackgroundRemoveParams(sourceURL: uploaded.first ?? ""))
            },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = [sourceAssetId]
            },
            fileExtension: "png",
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: tracked.onComplete,
            onFailure: tracked.onFailure
        )
    }

    // MARK: - Image edit (prompt-driven)

    @discardableResult
    static func submitImageEdit(
        asset: MediaAsset,
        prompt: String,
        modelId: String?,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) -> String? {
        guard AccountService.shared.isSignedIn, asset.type == .image else { return nil }
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !editor.activeAIEditSourceIds.contains(asset.id) else { return nil }
        let tracked = trackJob(sourceAssetId: asset.id, editor: editor, onComplete: onComplete, onFailure: onFailure)
        let model = modelId
            ?? ModelCatalog.shared.editModels.first?.id
            ?? VeniceBuiltInModel.defaultEdit
        let genInput = GenerationInput(
            prompt: trimmed, model: model,
            duration: 0, aspectRatio: "", resolution: nil
        )
        let sourceAssetId = asset.id
        return editor.generationService.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: [asset],
            name: "Edited \(stripPrefix(asset.name))",
            folderId: asset.folderId,
            buildParams: { uploaded in
                .imageEdit(ImageEditParams(
                    sourceURL: uploaded.first ?? "",
                    prompt: trimmed,
                    aspectRatio: nil
                ))
            },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = [sourceAssetId]
            },
            fileExtension: "png",
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: tracked.onComplete,
            onFailure: tracked.onFailure
        )
    }

    // MARK: - Rerun

    enum RerunError: LocalizedError {
        case notGenerated
        case unknownModel(String)
        case missingSource
        case invalid(String)
        case unauthorized
        case busy

        var errorDescription: String? {
            switch self {
            case .notGenerated: "This asset was not AI-generated"
            case .unknownModel(let id): "Model no longer available: \(id)"
            case .missingSource: "Cannot rerun: source not recorded"
            case .invalid(let msg): msg
            case .unauthorized: "Add your Venice API key to rerun generations"
            case .busy: "A generation from this asset is already running"
            }
        }
    }

    @discardableResult
    static func rerun(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        guard AccountService.shared.isSignedIn else {
            throw RerunError.unauthorized
        }
        guard !editor.activeAIEditSourceIds.contains(asset.id) else { throw RerunError.busy }
        let tracked = trackJob(sourceAssetId: asset.id, editor: editor, onComplete: onComplete, onFailure: onFailure)
        do {
            return try rerunSubmission(
                asset: asset, editor: editor,
                onComplete: tracked.onComplete, onFailure: tracked.onFailure
            )
        } catch {
            editor.activeAIEditSourceIds.remove(asset.id)
            throw error
        }
    }

    private static func rerunSubmission(
        asset: MediaAsset,
        editor: EditorViewModel,
        onComplete: (@MainActor (MediaAsset) -> Void)? = nil,
        onFailure: (@MainActor () -> Void)? = nil
    ) throws -> String {
        guard let stored = asset.generationInput else { throw RerunError.notGenerated }
        var gen = stored
        gen.createdAt = nil
        let modelId = gen.model
        let preUploaded = gen.imageURLs

        if let videoModel = VideoModelConfig.allModels.first(where: { $0.id == modelId }) {
            if videoModel.requiresSourceVideo {
                if let err = videoModel.validate(
                    duration: gen.duration,
                    aspectRatio: gen.aspectRatio,
                    resolution: gen.resolution,
                    validateDuration: false
                ) {
                    throw RerunError.invalid(err)
                }
                guard let source = preUploaded?.first else { throw RerunError.missingSource }
                let imageRefs = Array((preUploaded ?? []).dropFirst())
                let params = VideoGenerationParams(
                    prompt: gen.prompt,
                    duration: gen.duration,
                    aspectRatio: gen.aspectRatio,
                    resolution: gen.resolution,
                    sourceVideoURL: source,
                    startFrameURL: nil,
                    endFrameURL: nil,
                    referenceImageURLs: imageRefs,
                    generateAudio: gen.generateAudio ?? true
                )
                return editor.generationService.generate(
                    genInput: gen,
                    assetType: .video,
                    placeholderDuration: asset.duration > 0 ? asset.duration : Double(max(1, gen.duration)),
                    references: [],
                    preUploadedURLs: preUploaded,
                    name: rerunName(for: asset),
                    folderId: asset.folderId,
                    buildParams: { _ in .video(params) },
                    fileExtension: "mp4",
                    projectURL: editor.projectURL,
                    editor: editor,
                    onComplete: onComplete,
                    onFailure: onFailure
                )
            }
            if let err = videoModel.validate(
                duration: gen.duration, aspectRatio: gen.aspectRatio, resolution: gen.resolution
            ) {
                throw RerunError.invalid(err)
            }
            let params = VideoGenerationParams(
                prompt: gen.prompt,
                duration: gen.duration,
                aspectRatio: gen.aspectRatio,
                resolution: gen.resolution,
                sourceVideoURL: nil,
                startFrameURL: preUploaded?.first,
                endFrameURL: (preUploaded?.count ?? 0) > 1 ? preUploaded?[1] : nil,
                referenceImageURLs: gen.referenceImageURLs ?? [],
                referenceVideoURLs: gen.referenceVideoURLs ?? [],
                referenceAudioURLs: gen.referenceAudioURLs ?? [],
                generateAudio: gen.generateAudio ?? true
            )
            let bundled = (preUploaded ?? [])
                + (gen.referenceImageURLs ?? [])
                + (gen.referenceVideoURLs ?? [])
                + (gen.referenceAudioURLs ?? [])
            return editor.generationService.generate(
                genInput: gen,
                assetType: .video,
                placeholderDuration: Double(max(1, gen.duration)),
                references: [],
                preUploadedURLs: bundled.isEmpty ? nil : bundled,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .video(params) },
                snapshotRefs: { _, _ in },
                fileExtension: "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let imageModel = ImageModelConfig.allModels.first(where: { $0.id == modelId }) {
            let count = min(imageModel.maxImages, max(1, gen.numImages ?? 1))
            let refCount = (preUploaded ?? []).count
            if let err = imageModel.validate(
                aspectRatio: gen.aspectRatio, resolution: gen.resolution, quality: gen.quality,
                imageRefCount: refCount, numImages: count
            ) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                numImages: count,
                folderId: asset.folderId,
                buildParams: { uploaded in
                    ImageGenerationSubmission.imageParams(
                        prompt: gen.prompt,
                        aspectRatio: gen.aspectRatio,
                        resolution: gen.resolution,
                        quality: gen.quality,
                        uploaded: uploaded,
                        numImages: count,
                        stylePreset: gen.stylePreset
                    )
                },
                fileExtension: "jpg",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let audioModel = AudioModelConfig.allModels.first(where: { $0.id == modelId }) {
            let sourceVideoURL = audioModel.inputs.contains(.video) ? preUploaded?.first : nil
            let expectsVideoSource = audioModel.inputs.contains(.video)
                && (!audioModel.inputs.contains(.text)
                    || (gen.referenceVideoAssetIds?.isEmpty == false)
                    || sourceVideoURL != nil)
            if expectsVideoSource, sourceVideoURL == nil {
                throw RerunError.missingSource
            }
            let placeholderDuration: Double = asset.duration > 0
                ? asset.duration
                : (audioModel.category == .music
                    ? Defaults.audioMusicDurationSeconds
                    : Defaults.audioTTSDurationSeconds)
            let params = AudioGenerationParams(
                prompt: gen.prompt,
                voice: gen.voice,
                lyrics: gen.lyrics,
                styleInstructions: gen.styleInstructions,
                instrumental: gen.instrumental ?? false,
                durationSeconds: (audioModel.durations?.isEmpty == false || expectsVideoSource) && gen.duration > 0 ? gen.duration : nil,
                videoURL: sourceVideoURL
            )
            if let err = audioModel.validate(params: params) {
                throw RerunError.invalid(err)
            }
            return editor.generationService.generate(
                genInput: gen,
                assetType: .audio,
                placeholderDuration: placeholderDuration,
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in .audio(params) },
                fileExtension: "mp3",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        if let upscaleModel = UpscaleModelConfig.allModels.first(where: { $0.id == modelId }) {
            guard upscaleModel.supportedTypes.contains(asset.type) else {
                throw RerunError.invalid("\(upscaleModel.displayName) does not support \(asset.type.rawValue).")
            }
            guard let source = preUploaded?.first else { throw RerunError.missingSource }
            let isImage = asset.type == .image
            return editor.generationService.generate(
                genInput: gen,
                assetType: asset.type,
                placeholderDuration: isImage
                    ? Defaults.imageDurationSeconds
                    : (asset.duration > 0 ? asset.duration : Double(gen.duration)),
                references: [],
                preUploadedURLs: preUploaded,
                name: rerunName(for: asset),
                folderId: asset.folderId,
                buildParams: { _ in
                    .upscale(UpscaleGenerationParams(
                        sourceURL: source,
                        durationSeconds: isImage ? 1 : gen.duration
                    ))
                },
                fileExtension: isImage ? "jpg" : "mp4",
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: onComplete,
                onFailure: onFailure
            )
        }

        throw RerunError.unknownModel(modelId)
    }

    // MARK: - Panel seeds

    /// GenerationInput for an Edit action — opens the generation panel pre-filled with the asset as source.
    static func editSeed(for asset: MediaAsset, preferredModelId: String? = nil) -> GenerationInput? {
        let modelId: String
        switch asset.type {
        case .video:
            let candidates = VideoModelConfig.allModels.filter { $0.requiresSourceVideo }
            guard let m = candidates.first(where: { $0.id == preferredModelId }) ?? candidates.first else { return nil }
            modelId = m.id
        case .image:
            guard let m = ImageModelConfig.nanoBananaPro else { return nil }
            modelId = m.id
        case .audio, .text, .lottie:
            return nil
        }
        var stored = GenerationInput(prompt: "", model: modelId, duration: 0, aspectRatio: "", resolution: nil)
        stored.imageURLAssetIds = [asset.id]
        return stored
    }

    /// GenerationInput for Create Video — uses the image as a first frame or as a reference.
    static func createVideoSeed(for asset: MediaAsset, asReference: Bool, preferredModelId: String? = nil) -> GenerationInput? {
        let candidates = VideoModelConfig.allModels.filter {
            !$0.requiresSourceVideo && (asReference ? $0.supportsReferences : $0.supportsFirstFrame)
        }
        guard let model = candidates.first(where: { $0.id == preferredModelId }) ?? candidates.first else { return nil }
        var stored = GenerationInput(prompt: "", model: model.id, duration: 0, aspectRatio: "", resolution: nil)
        if asReference { stored.referenceImageAssetIds = [asset.id] } else { stored.imageURLAssetIds = [asset.id] }
        return stored
    }

    static func videoAudioSeed(for asset: MediaAsset, kind: VideoToAudioEditKind) -> GenerationInput? {
        guard let model = kind.model else { return nil }
        return videoAudioSeed(for: asset, model: model)
    }

    /// Seed the generation panel for a specific Venice audio model.
    ///
    /// Seed with clip duration and source video when the audio model accepts video.
    static func videoAudioSeed(for asset: MediaAsset, model: AudioModelConfig) -> GenerationInput? {
        guard asset.type == .video else { return nil }
        var stored = GenerationInput(
            prompt: "",
            model: model.id,
            duration: max(0, Int(asset.duration.rounded())),
            aspectRatio: "",
            resolution: nil
        )
        if model.inputs.contains(.video) {
            stored.referenceVideoAssetIds = [asset.id]
        }
        return stored
    }

    // MARK: - Names

    private static func upscaleName(for asset: MediaAsset) -> String {
        "Upscaled \(stripPrefix(asset.name))"
    }

    private static func rerunName(for asset: MediaAsset) -> String {
        "Rerun \(stripPrefix(asset.name))"
    }

    private static func stripPrefix(_ name: String) -> String {
        for prefix in ["Upscaled ", "Edited ", "Rerun "] where name.hasPrefix(prefix) {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }
}
