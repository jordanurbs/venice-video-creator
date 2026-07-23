import Foundation

extension ToolExecutor {
    func generate(_ editor: EditorViewModel, _ args: [String: Any], type: ClipType) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Generation requires a Venice API key. Tell the user to add it in Settings.")
        }
        switch type {
        case .video:
            guard let modelId = args.string("model")
                ?? enabledDefault(.textToVideo, in: VideoModelConfig.allModels.map(\.id))
                ?? VideoModelConfig.allModels.first(where: { ModelPreferences.shared.isEnabled($0.id) })?.id else {
                throw ToolError("Model catalog not loaded yet. Try again in a moment.")
            }
            guard let model = VideoModelConfig.allModels.first(where: { $0.id == modelId }) else {
                throw ToolError("Unknown model '\(modelId)'. Available: \(enabledIds(VideoModelConfig.allModels.map(\.id)))")
            }
            try ensureEnabled(model.id, kind: "video")
            return model.requiresSourceVideo
                ? try generateVideoEdit(editor, args, prompt: prompt, model: model)
                : try generateVideoText(editor, args, prompt: prompt, model: model)
        case .image:
            return try generateImage(editor, args, prompt: prompt)
        case .audio:
            throw ToolError("internal: audio generation is dispatched via the async path")
        case .text:
            throw ToolError("Text generation is not wired through the generate tool.")
        case .lottie:
            throw ToolError("Lottie animations aren't generated through this tool.")
        }
    }

    /// The saved default for `task`, but only if it's still enabled and present in `candidates`.
    private func enabledDefault(_ task: ModelPreferences.ModelTask, in candidates: [String]) -> String? {
        guard let id = ModelPreferences.shared.defaultModel(for: task),
              candidates.contains(id), ModelPreferences.shared.isEnabled(id) else { return nil }
        return id
    }

    /// Comma-joined enabled ids, for "available models" error messages.
    private func enabledIds(_ ids: [String]) -> String {
        let enabled = ids.filter { ModelPreferences.shared.isEnabled($0) }
        return enabled.isEmpty ? "(none enabled — turn some on in Settings → Models)" : enabled.joined(separator: ", ")
    }

    /// Rejects a model the user has turned off in Settings → Models.
    private func ensureEnabled(_ id: String, kind: String) throws {
        guard ModelPreferences.shared.isEnabled(id) else {
            throw ToolError("Model '\(id)' is turned off in Settings → Models. Pick an enabled \(kind) model (see list_models) or ask the user to turn it back on.")
        }
    }

    private func generateVideoEdit(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) throws -> ToolResult {
        guard let sourceRef = args.string("sourceVideoMediaRef") else {
            throw ToolError("Model '\(model.id)' requires 'sourceVideoMediaRef' pointing to a video asset.")
        }
        let sourceAsset = try asset(sourceRef, editor: editor, label: "Source video")
        let trimmed = try trimmedSource(args, editor: editor, source: sourceAsset)

        var imageRefs: [MediaAsset] = []
        for id in args.stringArray("referenceImageMediaRefs") {
            imageRefs.append(try asset(id, editor: editor, label: "Reference image"))
        }

        if let err = model.validate(duration: 0, aspectRatio: "", resolution: nil, validateDuration: false) {
            throw ToolError(err)
        }
        let inputAssets = VideoGenerationSubmission.InputAssets(sourceVideo: sourceAsset, imageRefs: imageRefs)
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: Int(sourceAsset.duration.rounded()),
            aspectRatio: "", resolution: nil
        )
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: trimmed?.durationSeconds ?? (sourceAsset.duration > 0 ? sourceAsset.duration : 5),
            trimmedSourceOverride: trimmed,
            name: args.string("name"),
            folderId: sourceAsset.folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Edit started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(sourceAsset.name)")
    }

    private func generateVideoText(
        _ editor: EditorViewModel, _ args: [String: Any],
        prompt: String, model: VideoModelConfig
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }

        let duration = args.int("duration") ?? model.durations.first ?? 0
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        let resolution = args.string("resolution") ?? model.resolutions?.first

        if let err = model.validate(duration: duration, aspectRatio: aspectRatio, resolution: resolution) {
            throw ToolError(err)
        }

        var frameSlots: [MediaAsset] = []
        if let startRef = args.string("startFrameMediaRef") {
            frameSlots.append(try asset(startRef, editor: editor, label: "Start frame"))
        }
        if let endRef = args.string("endFrameMediaRef") {
            frameSlots.append(try asset(endRef, editor: editor, label: "End frame"))
        }

        func refs(_ argName: String, label: String) throws -> [MediaAsset] {
            try args.stringArray(argName).map { id in
                try asset(id, editor: editor, label: label)
            }
        }
        let imageRefs = try refs("referenceImageMediaRefs", label: "Image reference")
        let videoRefs = try refs("referenceVideoMediaRefs", label: "Video reference")
        let audioRefs = try refs("referenceAudioMediaRefs", label: "Audio reference")
        let inputAssets = VideoGenerationSubmission.InputAssets(
            frames: frameSlots,
            imageRefs: imageRefs,
            videoRefs: videoRefs,
            audioRefs: audioRefs
        )
        if let err = inputAssets.validate(for: model) {
            throw ToolError(err)
        }

        let imageRefCount = imageRefs.count
        let videoRefCount = videoRefs.count
        let audioRefCount = audioRefs.count
        let totalRefs = inputAssets.totalRefCount

        let genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: duration,
            aspectRatio: aspectRatio, resolution: resolution
        )

        let folderId = try resolveFolderId(
            args, editor: editor, fallbackReferences: inputAssets.textToVideoReferences
        )
        let placeholderId = VideoGenerationSubmission.make(
            genInput: genInput,
            model: model,
            inputAssets: inputAssets,
            placeholderDuration: Double(max(1, duration)),
            name: args.string("name"),
            folderId: folderId,
            generateAudio: true
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let refSummary = totalRefs > 0
            ? ", refs: \(imageRefCount)img/\(videoRefCount)vid/\(audioRefCount)aud"
            : ""
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), duration: \(duration)s, aspect: \(aspectRatio)\(refSummary)")
    }

    private func generateImage(
        _ editor: EditorViewModel, _ args: [String: Any], prompt: String
    ) throws -> ToolResult {
        guard !prompt.isEmpty else { throw ToolError("Empty prompt") }
        guard let modelId = args.string("model")
            ?? enabledDefault(.image, in: ImageModelConfig.allModels.map(\.id))
            ?? ImageModelConfig.allModels.first(where: { ModelPreferences.shared.isEnabled($0.id) })?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = ImageModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(enabledIds(ImageModelConfig.allModels.map(\.id)))")
        }
        try ensureEnabled(model.id, kind: "image")
        let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
        // Default agent-initiated stills to the cheapest resolution; the user can
        // request a higher resolution explicitly or upscale the result afterward.
        let resolution = args.string("resolution") ?? Self.cheapestResolution(model)
        let quality = args.string("quality") ?? model.qualities?.last
        let refIds = args.stringArray("referenceMediaRefs")
        if let err = model.validate(
            aspectRatio: aspectRatio, resolution: resolution, quality: quality,
            imageRefCount: refIds.count, numImages: 1
        ) {
            throw ToolError(err)
        }
        let refs: [MediaAsset] = try refIds.map { id in
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image asset (got \(a.type.rawValue))")
            }
            return a
        }

        let genInput = GenerationInput(
            prompt: prompt, model: modelId, duration: 0,
            aspectRatio: aspectRatio, resolution: resolution, quality: quality
        )
        let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: refs)
        let placeholderId = ImageGenerationSubmission.make(
            genInput: genInput,
            model: model,
            references: refs,
            name: args.string("name"),
            folderId: folderId
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        var reply = "Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), aspect: \(aspectRatio)"
        if let redirect = Self.storyboardRedirectHint(prompt: prompt, name: args.string("name"), editor: editor) {
            reply += "\n\(redirect)"
        }
        return .ok(reply)
    }

    /// Storyboard- or character-reference-looking raw image generations get a
    /// firm redirect to the pipeline path, so they don't land as loose Media
    /// assets invisible to the Production/Cast tabs.
    private static func storyboardRedirectHint(prompt: String, name: String?, editor: EditorViewModel) -> String? {
        let haystack = (prompt + " " + (name ?? "")).lowercased()
        if haystack.contains("storyboard") || haystack.contains("panel") {
            if let plan = editor.shotPlan, !plan.shots.isEmpty {
                return "WARNING: This looks like a storyboard panel generated outside the pipeline — it will NOT be linked to any shot or visible in the Production panel. Use storyboard_shots (one call, all shots) instead; pass shotIds to target specific shots."
            }
            return "WARNING: This looks like a storyboard panel, but no shot plan exists. save_shot_plan first (one shot per panel), then ONE storyboard_shots call — panels land linked to their shots in the Production panel instead of as loose Media assets."
        }
        let characterTerms = ["character reference", "reference sheet", "character design", "front view", "three-quarter view"]
        if characterTerms.contains(where: haystack.contains)
            || (editor.shotPlan?.characters.contains { !$0.name.isEmpty && haystack.contains($0.name.lowercased()) } ?? false) {
            return "WARNING: This looks like a character reference image. Loose Media images are invisible to the Cast tab and shot consistency. Use create_character (generates linked references), or after this asset finishes, attach it with update_character addReferenceMediaRefs."
        }
        return nil
    }

    /// Lowest-resolution option a model offers, so chat-driven generations stay cheap.
    /// Handles WxH IDs ("3840x2160") and tier labels ("1K", "1080p").
    static func cheapestResolution(_ model: ImageModelConfig) -> String? {
        guard let resolutions = model.resolutions, !resolutions.isEmpty else { return nil }
        return resolutions.min { resolutionRank($0) < resolutionRank($1) }
    }

    private static func resolutionRank(_ id: String) -> Int {
        if let (w, h) = ImageModelConfig.parseWxH(id) { return max(w, h) }
        let lower = id.lowercased()
        if lower.hasSuffix("k"), let n = Int(lower.dropLast()) { return n * 1024 }
        if lower.hasSuffix("p"), let n = Int(lower.dropLast()) { return n }
        return .max
    }

    func generateAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Generation requires a Venice API key. Tell the user to add it in Settings.")
        }
        guard let modelId = args.string("model")
            ?? enabledDefault(.audio, in: AudioModelConfig.allModels.map(\.id))
            ?? AudioModelConfig.allModels.first(where: { ModelPreferences.shared.isEnabled($0.id) })?.id else {
            throw ToolError("Model catalog not loaded yet. Try again in a moment.")
        }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == modelId }) else {
            throw ToolError("Unknown model '\(modelId)'. Available: \(enabledIds(AudioModelConfig.allModels.map(\.id)))")
        }
        try ensureEnabled(model.id, kind: "audio")

        let prompt = (args.string("prompt") ?? "").trimmingCharacters(in: .whitespaces)
        let acceptsVideo = model.inputs.contains(.video)
        var videoURL: String?
        var spanSeconds: Double?
        var placementStartFrame: Int?   // set when a timeline span is given -> auto-place on the timeline
        if let ref = args.string("videoSourceMediaRef") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            let videoAsset = try asset(ref, editor: editor, label: "Video source")
            guard videoAsset.type == .video else {
                throw ToolError("videoSourceMediaRef must be a video asset (got \(videoAsset.type.rawValue)).")
            }
            guard let fileURL = editor.mediaResolver.resolveURL(for: videoAsset.id) else {
                throw ToolError("Could not read the video source file.")
            }
            videoURL = try await GenerationBackend.uploadReference(fileURL: fileURL, contentType: "video/mp4")
            spanSeconds = videoAsset.duration
        } else if let start = args.int("videoSourceStartFrame"), let end = args.int("videoSourceEndFrame") {
            guard acceptsVideo else {
                throw ToolError("Model '\(model.id)' does not accept a video input (see list_models 'inputs').")
            }
            guard start >= 0, end > start else {
                throw ToolError("videoSourceEndFrame must be greater than videoSourceStartFrame (>= 0).")
            }
            let mp4 = try await TimelineRenderer.render(
                timeline: editor.timeline, resolver: editor.mediaResolver,
                missingMediaRefs: editor.missingMediaRefs,
                startFrame: start, frameCount: end - start,
                shortSide: 360, includeAudio: false
            )
            defer { try? FileManager.default.removeItem(at: mp4) }
            videoURL = try await GenerationBackend.uploadReference(fileURL: mp4, contentType: "video/mp4")
            spanSeconds = Double(end - start) / Double(max(1, editor.timeline.fps))
            placementStartFrame = start
        }

        // A video-only model (no text input, e.g. Mirelo) needs a source.
        if acceptsVideo && !model.inputs.contains(.text) && videoURL == nil {
            throw ToolError("Model '\(model.id)' generates audio from video. Provide videoSourceStartFrame + videoSourceEndFrame (a timeline span) or videoSourceMediaRef.")
        }

        let instrumental = args.bool("instrumental") ?? false
        let requestedDuration = args.int("duration") ?? spanSeconds.map { max(1, Int($0.rounded())) }
        let durationSeconds = model.reconciledDuration(requestedDuration)
        let params = AudioGenerationParams(
            prompt: prompt,
            voice: model.voices != nil ? (args.string("voice") ?? model.defaultVoice) : nil,
            lyrics: model.supportsLyrics ? args.string("lyrics") : nil,
            styleInstructions: model.supportsStyleInstructions ? args.string("styleInstructions") : nil,
            instrumental: model.supportsInstrumental ? instrumental : false,
            durationSeconds: durationSeconds,
            videoURL: videoURL
        )
        if let err = model.validate(params: params) {
            throw ToolError(err)
        }

        let genInput = GenerationInput(
            prompt: prompt,
            model: model.id,
            duration: durationSeconds ?? 0,
            aspectRatio: "",
            resolution: nil,
            voice: params.voice,
            lyrics: params.lyrics,
            styleInstructions: params.styleInstructions,
            instrumental: model.supportsInstrumental ? instrumental : nil
        )

        let folderId = try resolveFolderId(args, editor: editor)
        let submission = AudioGenerationSubmission.make(
            genInput: genInput,
            model: model,
            params: params,
            name: args.string("name"),
            folderId: folderId
        )

        if let startFrame = placementStartFrame, let span = spanSeconds {
            let placeholderId = submission.submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: { asset in
                    editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                }
            )
            editor.placeGeneratingAudioClip(
                placeholderId: placeholderId, startFrame: startFrame,
                spanSeconds: span, actionName: "Add \(model.category.label)"
            )
            return .ok("Generation started and placed on the timeline at frame \(startFrame). Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label) (scored from video).")
        }

        let placeholderId = submission.submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor
        )
        let scored = videoURL != nil ? " (scored from video)" : ""
        let lengthNote = durationSeconds.map { ", \($0)s" } ?? ""
        return .ok("Generation started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), \(model.category.label)\(lengthNote)\(scored). Place it with add_clips.")
    }

    func editImage(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let prompt = try args.requireString("prompt")
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError("Empty prompt")
        }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Image editing requires a Venice API key. Tell the user to add it in Settings.")
        }
        let mediaRef = try args.requireString("mediaRef")
        let base = try asset(mediaRef, editor: editor, label: "Source image")
        guard base.type == .image else {
            throw ToolError("edit_image requires an image asset (got \(base.type.rawValue)).")
        }
        let modelId = args.string("model")
        if let modelId, !ModelCatalog.shared.editModels.contains(where: { $0.id == modelId }) {
            let ids = ModelCatalog.shared.editModels.map(\.id).joined(separator: ", ")
            throw ToolError("Unknown edit model '\(modelId)'. Available: \(ids.isEmpty ? "(none loaded)" : ids)")
        }

        let extraIds = args.stringArray("referenceMediaRefs")
        let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: [base])

        if extraIds.isEmpty {
            guard let placeholderId = EditSubmitter.submitImageEdit(
                asset: base, prompt: prompt, modelId: modelId, editor: editor
            ) else {
                throw ToolError("Failed to start image edit.")
            }
            return .ok("Image edit started. Placeholder asset ID: \(placeholderId). Source: \(base.name)")
        }

        // Multi-edit: base image first, then up to 2 additional references (3 total).
        var refs: [MediaAsset] = [base]
        for id in extraIds {
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image (got \(a.type.rawValue)).")
            }
            refs.append(a)
        }
        guard refs.count <= 3 else {
            throw ToolError("/image/multi-edit supports up to 3 images total (base + 2 references); got \(refs.count).")
        }
        let model = modelId ?? ModelCatalog.shared.editModels.first?.id ?? VeniceBuiltInModel.defaultEdit
        let refIds = refs.map(\.id)
        let genInput = GenerationInput(
            prompt: prompt, model: model, duration: 0, aspectRatio: "", resolution: nil
        )
        let placeholderId = editor.generationService.generate(
            genInput: genInput,
            assetType: .image,
            placeholderDuration: Defaults.imageDurationSeconds,
            references: refs,
            name: args.string("name") ?? "Edited \(base.name)",
            folderId: folderId,
            buildParams: { uploaded in
                .imageMultiEdit(ImageMultiEditParams(sourceURLs: uploaded, prompt: prompt, aspectRatio: nil))
            },
            snapshotRefs: { input, uploaded in
                input.imageURLs = uploaded.isEmpty ? nil : uploaded
                input.imageURLAssetIds = refIds
            },
            fileExtension: "png",
            projectURL: editor.projectURL,
            editor: editor
        )
        return .ok("Multi-image edit started. Placeholder asset ID: \(placeholderId). Base: \(base.name), +\(refs.count - 1) reference(s).")
    }

    /// Grabs a video clip's last visible frame as a still image asset, so the agent
    /// can pass it back as startFrameMediaRef to chain the next shot continuously.
    func extractLastFrame(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let source = try asset(mediaRef, editor: editor, label: "Source video")
        guard source.type == .video else {
            throw ToolError("extract_last_frame requires a video asset (got \(source.type.rawValue)).")
        }
        guard let url = editor.mediaResolver.resolveURL(for: source.id) else {
            throw ToolError("Could not read the video file for '\(source.name)'.")
        }
        let seconds = try Self.lastFrameSeconds(args, editor: editor, source: source)

        guard let data = await LastFrameExtractor.pngData(url: url, atSeconds: seconds) else {
            throw ToolError("Couldn't decode a frame from '\(source.name)' at \(String(format: "%.2f", seconds))s.")
        }
        guard let frameAsset = await editor.importPastedImageData(data, fileExtension: "png") else {
            throw ToolError("Extracted the frame but couldn't add it to the media library.")
        }
        let name = args.string("name") ?? "Last frame · \(source.name)"
        frameAsset.name = name
        if let idx = editor.mediaManifest.entries.firstIndex(where: { $0.id == frameAsset.id }) {
            editor.mediaManifest.entries[idx].name = name
        }
        if let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: [source]) {
            editor.moveAssetsToFolder(assetIds: [frameAsset.id], folderId: folderId)
        }
        return .ok("Extracted the last frame of '\(source.name)' as image asset \(frameAsset.id) (at \(String(format: "%.2f", seconds))s). Pass it as startFrameMediaRef in generate_video to continue the shot from this frame.")
    }

    /// Source-time (seconds) of the frame to grab: an explicit atSeconds, else the
    /// clip's trim/speed-aware last visible frame, else the asset's end.
    private static func lastFrameSeconds(_ args: [String: Any], editor: EditorViewModel, source: MediaAsset) throws -> Double {
        if let atSeconds = args.double("atSeconds") { return max(0, atSeconds) }
        if let clipId = args.string("sourceClipId") {
            guard let clip = editor.clipFor(id: clipId) else {
                throw ToolError("sourceClipId not found: \(clipId)")
            }
            guard clip.mediaRef == source.id else {
                throw ToolError("sourceClipId \(clipId) references a different asset than mediaRef.")
            }
            guard clip.mediaType == .video else {
                throw ToolError("sourceClipId must reference a video clip.")
            }
            let fps = Double(max(1, editor.timeline.fps))
            let sourceFrame = Double(clip.trimStartFrame) + Double(max(0, clip.durationFrames - 1)) * clip.speed
            return sourceFrame / fps
        }
        return max(0, source.duration - 0.05)
    }

    func removeBackground(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Background removal requires a Venice API key. Tell the user to add it in Settings.")
        }
        let mediaRef = try args.requireString("mediaRef")
        let base = try asset(mediaRef, editor: editor, label: "Source image")
        guard base.type == .image else {
            throw ToolError("remove_background requires an image asset (got \(base.type.rawValue)).")
        }
        guard let placeholderId = EditSubmitter.submitBackgroundRemove(asset: base, editor: editor) else {
            throw ToolError("Failed to start background removal.")
        }
        return .ok("Background removal started. Placeholder asset ID: \(placeholderId). Source: \(base.name)")
    }

    func upscaleMedia(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let mediaRef = try args.requireString("mediaRef")
        let asset = try asset(mediaRef, editor: editor)
        guard asset.type == .image else {
            throw ToolError("Upscale supports image assets only (got \(asset.type.rawValue))")
        }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Upscale requires a Venice API key. Tell the user to add it in Settings.")
        }

        let available = UpscaleModelConfig.models(for: asset.type)
        let model: UpscaleModelConfig
        if let requested = args.string("model") {
            guard let match = available.first(where: { $0.id == requested }) else {
                let ids = enabledIds(available.map(\.id))
                throw ToolError("Model '\(requested)' does not support \(asset.type.rawValue). Available: \(ids)")
            }
            try ensureEnabled(match.id, kind: "upscale")
            model = match
        } else {
            guard let first = available.first(where: { ModelPreferences.shared.isEnabled($0.id) }) else {
                throw ToolError("No enabled upscaler for \(asset.type.rawValue). Turn one on in Settings → Models.")
            }
            model = first
        }

        let trimmed = try trimmedSource(args, editor: editor, source: asset)
        guard let placeholderId = EditSubmitter.submitUpscale(
            asset: asset, model: model, editor: editor, trimmedSource: trimmed
        ) else {
            throw ToolError("Failed to start upscale")
        }
        return .ok("Upscale started. Placeholder asset ID: \(placeholderId). Model: \(model.displayName), source: \(asset.name)\(trimmed != nil ? " (trimmed range)" : "")")
    }

    private func trimmedSource(
        _ args: [String: Any], editor: EditorViewModel, source: MediaAsset
    ) throws -> TrimmedSource? {
        guard let clipId = args.string("sourceClipId") else { return nil }
        guard let clip = editor.clipFor(id: clipId) else {
            throw ToolError("sourceClipId not found: \(clipId)")
        }
        guard clip.mediaRef == source.id else {
            throw ToolError("sourceClipId \(clipId) references a different asset than the source")
        }
        guard source.type == .video else {
            throw ToolError("sourceClipId only applies to video sources")
        }
        guard clip.trimStartFrame > 0 || clip.trimEndFrame > 0 else { return nil }
        return TrimmedSource(
            sourceURL: source.url,
            trimStartFrame: clip.trimStartFrame,
            trimEndFrame: clip.trimEndFrame,
            sourceFramesConsumed: clip.sourceFramesConsumed,
            fps: editor.timeline.fps
        )
    }

    func listModels(_ args: [String: Any]) -> ToolResult {
        let filter = args.string("type")
        let prefs = ModelPreferences.shared
        var out: [[String: Any]] = []
        if filter == nil || filter == "video" {
            out += VideoModelConfig.allModels.filter { prefs.isEnabled($0.id) }.map { Self.videoModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "image" {
            out += ImageModelConfig.allModels.filter { prefs.isEnabled($0.id) }.map { Self.imageModelInfo($0, includeType: true) }
        }
        if filter == nil || filter == "audio" {
            out += AudioModelConfig.allModels.filter { prefs.isEnabled($0.id) }.map { Self.audioModelInfo($0) }
        }
        if filter == nil || filter == "upscale" {
            out += UpscaleModelConfig.allModels.filter { prefs.isEnabled($0.id) }.map { Self.upscaleModelInfo($0) }
        }
        if filter == nil || filter == "edit" {
            out += ModelCatalog.shared.editModels.map { m -> [String: Any] in
                var info: [String: Any] = ["id": m.id, "displayName": m.displayName, "type": "edit"]
                if !m.aspectRatios.isEmpty { info["aspectRatios"] = m.aspectRatios }
                return info
            }
        }
        let body: [String: Any] = [
            "models": out,
            "loaded": ModelCatalog.shared.isLoaded,
        ]
        guard let json = Self.jsonString(roundJSONFloatingPointNumbers(body, toPlaces: 3)) else {
            return .error("Failed to encode model list")
        }
        return .ok(json)
    }

    nonisolated static func videoModelInfo(_ m: VideoModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "durations": m.durations, "aspectRatios": m.aspectRatios,
            "supportsFirstFrame": m.supportsFirstFrame,
            "supportsLastFrame": m.supportsLastFrame,
            "supportsReferences": m.supportsReferences,
        ]
        if includeType { info["type"] = "video" }
        if let r = m.resolutions { info["resolutions"] = r }
        if m.supportsReferences {
            if m.maxReferenceImages > 0 { info["maxReferenceImages"] = m.maxReferenceImages }
            if m.maxReferenceVideos > 0 { info["maxReferenceVideos"] = m.maxReferenceVideos }
            if m.maxReferenceAudios > 0 { info["maxReferenceAudios"] = m.maxReferenceAudios }
            if let total = m.maxTotalReferences { info["maxTotalReferences"] = total }
            if let s = m.maxCombinedVideoRefSeconds { info["maxCombinedVideoRefSeconds"] = Int(s) }
            if let s = m.maxCombinedAudioRefSeconds { info["maxCombinedAudioRefSeconds"] = Int(s) }
            if m.framesAndReferencesExclusive { info["framesAndReferencesExclusive"] = true }
            info["referenceTagNoun"] = m.referenceTagNoun
        }
        return info
    }

    nonisolated static func imageModelInfo(_ m: ImageModelConfig, includeType: Bool = false) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "aspectRatios": m.aspectRatios,
            "supportsImageReference": m.supportsImageReference,
        ]
        if includeType { info["type"] = "image" }
        if let r = m.resolutions { info["resolutions"] = r }
        if let q = m.qualities { info["qualities"] = q }
        return info
    }

    nonisolated static func audioModelInfo(_ m: AudioModelConfig) -> [String: Any] {
        var info: [String: Any] = [
            "id": m.id, "displayName": m.displayName,
            "type": "audio",
            "category": m.category == .music ? "music" : (m.category == .sfx ? "sfx" : "tts"),
            "inputs": m.inputs.map(\.rawValue),
            "minPromptLength": m.minPromptLength,
            "supportsLyrics": m.supportsLyrics,
            "supportsInstrumental": m.supportsInstrumental,
            "supportsStyleInstructions": m.supportsStyleInstructions,
        ]
        if let voices = m.voices {
            info["voicesSample"] = Array(voices.prefix(3))
            info["voiceCount"] = voices.count
        }
        if let defaultVoice = m.defaultVoice { info["defaultVoice"] = defaultVoice }
        if let durations = m.durations { info["durations"] = durations }
        return info
    }

    nonisolated static func upscaleModelInfo(_ m: UpscaleModelConfig) -> [String: Any] {
        [
            "id": m.id, "displayName": m.displayName,
            "type": "upscale",
            "speed": m.speed,
            "supportedTypes": m.supportedTypes.map(\.rawValue).sorted(),
        ]
    }
}
