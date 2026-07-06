import Foundation

/// Which Venice async queue a job went through; picks the retrieve endpoint on resume.
enum VeniceQueueKind: String, Sendable {
    case video, audio
}

/// Executes a single Venice generation request and returns result URLs that
/// `GenerationService` can download/finalize. Image generation is synchronous;
/// video generation goes through Venice's async queue/retrieve flow.
@MainActor
enum VeniceGenerationRunner {
    static func run(
        model: String,
        params: BackendGenerationParams,
        api: VeniceAPI,
        onQueue: (@MainActor (String, String?) -> Void)? = nil
    ) async throws -> [String] {
        switch params {
        case .image(let p): return try await runImage(model: model, params: p, api: api)
        case .video(let p): return try await runVideo(model: model, params: p, api: api, onQueue: onQueue)
        case .audio(let p): return try await runAudio(model: model, params: p, api: api, onQueue: onQueue)
        case .upscale(let p): return try await runUpscale(model: model, params: p, api: api)
        case .imageEdit(let p): return try await runImageEdit(model: model, params: p, api: api)
        case .imageMultiEdit(let p): return try await runImageMultiEdit(model: model, params: p, api: api)
        case .backgroundRemove(let p): return try await runBackgroundRemove(params: p, api: api)
        }
    }

    /// Re-polls an already-queued Venice job by its persisted queue id (after relaunch).
    static func resume(
        queueId: String,
        model: String,
        kind: VeniceQueueKind,
        downloadURL: String?,
        api: VeniceAPI
    ) async throws -> [String] {
        switch kind {
        case .video: [try await pollVideo(queueId: queueId, model: model, downloadURL: downloadURL, api: api)]
        case .audio: [try await pollAudio(queueId: queueId, model: model, api: api)]
        }
    }

    // MARK: - Image edit / multi-edit / background-remove

    /// Venice `/image/edit` — prompt-driven single-image transform. Returns PNG.
    private static func runImageEdit(
        model: String, params: ImageEditParams, api: VeniceAPI
    ) async throws -> [String] {
        let resolvedModel = model.isEmpty ? VeniceBuiltInModel.defaultEdit : model
        var body: [String: Any] = [
            "model": resolvedModel,
            "prompt": params.prompt,
            "image": stripDataURLPrefix(params.sourceURL),
            "safe_mode": false,
        ]
        if let aspectRatio = params.aspectRatio,
           supportsImageEditAspectRatio(model: resolvedModel, aspectRatio: aspectRatio) {
            body["aspect_ratio"] = aspectRatio
        }
        let bytes = try await binaryOrBase64(path: "image/edit", body: body, accept: "image/png", api: api)
        try assertPlausibleImage(bytes)
        return [try writeTemp(data: bytes, ext: "png").absoluteString]
    }

    /// Venice `/image/multi-edit` — compose 1–3 images. Uses `modelId` (not `model`). Returns PNG.
    private static func runImageMultiEdit(
        model: String, params: ImageMultiEditParams, api: VeniceAPI
    ) async throws -> [String] {
        let body: [String: Any] = [
            "modelId": model.isEmpty ? VeniceBuiltInModel.defaultEdit : model,
            "prompt": params.prompt,
            // multi-edit accepts base64 or data: URLs; pass them through as-is.
            "images": params.sourceURLs,
            "safe_mode": false,
        ]
        let bytes = try await binaryOrBase64(path: "image/multi-edit", body: body, accept: "image/png", api: api)
        // Venice multi-edit returns a square image; restore the requested shape.
        let restored = ImageAspectRestorer.restore(pngData: bytes, toAspectRatio: params.aspectRatio)
        try assertPlausibleImage(restored)
        return [try writeTemp(data: restored, ext: "png").absoluteString]
    }

    /// Venice `/image/background-remove` — transparent cutout. Returns PNG with alpha.
    private static func runBackgroundRemove(
        params: BackgroundRemoveParams, api: VeniceAPI
    ) async throws -> [String] {
        let body: [String: Any] = ["image": stripDataURLPrefix(params.sourceURL)]
        let bytes = try await binaryOrBase64(path: "image/background-remove", body: body, accept: "image/png", api: api)
        return [try writeTemp(data: bytes, ext: "png").absoluteString]
    }

    // MARK: - Image (synchronous)

    private static func runImage(
        model: String, params: ImageGenerationParams, api: VeniceAPI
    ) async throws -> [String] {
        let catalogModel = imageModel(for: model)
        let variants = catalogModel.map {
            min($0.maxImages, max(1, params.numImages))
        } ?? max(1, min(4, params.numImages))
        var body: [String: Any] = [
            "model": model,
            "prompt": params.prompt,
            "format": "png",
            "safe_mode": false,
            "return_binary": false,
            "variants": variants,
        ]
        if supports(params.aspectRatio, allowed: catalogModel?.aspectRatios, knownModel: catalogModel != nil) {
            body["aspect_ratio"] = params.aspectRatio
        }
        if let resolution = params.resolution,
           supports(resolution, allowed: catalogModel?.resolutions, knownModel: catalogModel != nil) {
            body["resolution"] = resolution
        }
        if let quality = params.quality,
           supports(quality, allowed: catalogModel?.qualities, knownModel: catalogModel != nil) {
            body["quality"] = quality
        }
        if let style = params.stylePreset, !style.isEmpty { body["style_preset"] = style }
        // /image/generate has no reference-image field; reference-bearing requests
        // are routed to /image/edit or /image/multi-edit upstream (see ImageGenerationSubmission.imageParams).

        let obj = try await api.postJSON(path: "image/generate", body: body)
        guard let images = obj["images"] as? [String], !images.isEmpty else {
            throw VeniceAPI.VeniceError.empty
        }
        return try images.map { base64 in
            guard let data = Data(base64Encoded: stripDataURLPrefix(base64)) else {
                throw VeniceAPI.VeniceError.decode("invalid base64 image")
            }
            try assertPlausibleImage(data)
            return try writeTemp(data: data, ext: "png").absoluteString
        }
    }

    // MARK: - Video (async queue + poll)

    private static func runVideo(
        model: String, params: VideoGenerationParams, api: VeniceAPI,
        onQueue: (@MainActor (String, String?) -> Void)? = nil
    ) async throws -> [String] {
        let catalogModel = videoModel(for: model)
        var body: [String: Any] = [
            "model": model,
            "prompt": params.prompt,
        ]
        if supportsVideoDuration(params.duration, model: catalogModel) {
            body["duration"] = "\(max(1, params.duration))s"
        }
        if let resolution = params.resolution,
           supports(resolution, allowed: catalogModel?.resolutions, knownModel: catalogModel != nil) {
            body["resolution"] = resolution
        }
        if supports(params.aspectRatio, allowed: catalogModel?.aspectRatios, knownModel: catalogModel != nil) {
            body["aspect_ratio"] = params.aspectRatio
        }
        if catalogModel?.supportsFirstFrame ?? true, let startFrame = params.startFrameURL {
            body["image_url"] = startFrame
        }
        if catalogModel?.supportsLastFrame ?? true, let endFrame = params.endFrameURL {
            body["end_image_url"] = endFrame
        }
        if catalogModel?.requiresSourceVideo ?? true, let sourceVideo = params.sourceVideoURL {
            body["video_url"] = sourceVideo
        }
        if let imageRefs = supportedRefs(params.referenceImageURLs, limit: catalogModel?.maxReferenceImages) {
            body["reference_image_urls"] = imageRefs
        }
        if let videoRefs = supportedRefs(params.referenceVideoURLs, limit: catalogModel?.maxReferenceVideos) {
            body["reference_video_urls"] = videoRefs
        }
        if (catalogModel?.maxReferenceAudios ?? 1) > 0, let audioURL = params.referenceAudioURLs.first {
            body["audio_url"] = audioURL
        }
        if catalogModel?.audioConfigurable == true { body["audio"] = params.generateAudio }
        // Seedance requires an explicit consent object for face-bearing media.
        // The user grants this once in Settings → Models; attach it for every Seedance job.
        if isSeedance(model: model), ModelPreferences.shared.seedanceConsentGranted {
            body["consents"] = [
                "seedance": [
                    "confirmed_terms_and_privacy": true,
                    "confirmed_legal_right": true,
                    "confirmed_screening_acknowledged": true,
                ]
            ]
        }

        let queued = try await api.postJSON(path: "video/queue", body: body)
        guard let queueId = queued["queue_id"] as? String else {
            throw VeniceAPI.VeniceError.decode("missing queue_id")
        }
        let downloadURL = queued["download_url"] as? String
        onQueue?(queueId, downloadURL)

        return [try await pollVideo(queueId: queueId, model: model, downloadURL: downloadURL, api: api)]
    }

    /// Polls `/video/retrieve` until the video is ready, returning a downloadable URL.
    /// Venice requires both `queue_id` and `model` on the retrieve call.
    private static func pollVideo(
        queueId: String, model: String, downloadURL: String?, api: VeniceAPI
    ) async throws -> String {
        // 30-min ceiling matches the probe-verified harness poll window; slow
        // models at longer durations routinely outrun a 15-min window. The job
        // runs server-side and resumes by queue_id.
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            let request = api.makeRequest(
                path: "video/retrieve",
                accept: "video/mp4",
                body: try api.jsonBody(["queue_id": queueId, "model": model])
            )
            let (data, response) = try await api.data(for: request)
            try VeniceAPI.assertOK(data: data, response: response)
            let http = response as? HTTPURLResponse
            let contentType = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()

            if contentType.contains("video/") {
                try assertPlausibleVideo(data)
                return try writeTemp(data: data, ext: "mp4").absoluteString
            }
            // Otherwise it's a JSON status payload.
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let status = (json?["status"] as? String)?.uppercased() ?? ""
            if status == "COMPLETED" {
                if let downloadURL { return downloadURL }
                return try writeTemp(data: data, ext: "mp4").absoluteString
            }
            // Surface a terminal server-side failure immediately instead of waiting
            // out the whole poll window and reporting a misleading "timed out".
            if status.contains("FAIL") {
                let detail = (json?["error"] as? String) ?? (json?["message"] as? String)
                throw VeniceAPI.VeniceError.transport(detail ?? "Video generation failed.")
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        throw VeniceAPI.VeniceError.transport("Video generation timed out.")
    }

    // MARK: - Audio

    private static func runAudio(
        model: String, params: AudioGenerationParams, api: VeniceAPI,
        onQueue: (@MainActor (String, String?) -> Void)? = nil
    ) async throws -> [String] {
        let catalogModel = audioModel(for: model)
        // Route by the endpoint recorded in the catalog: type=tts models use the
        // synchronous /audio/speech; music/SFX use the async /audio/queue flow.
        let usesSpeech = catalogModel?.entry.allowedEndpoints.contains("audio/speech") ?? false

        if usesSpeech {
            var body: [String: Any] = [
                "model": model,
                "input": params.prompt,
                "response_format": "mp3",
            ]
            if let voice = params.voice,
               supports(voice, allowed: catalogModel?.voices, knownModel: catalogModel != nil) {
                body["voice"] = voice
            }
            let request = api.makeRequest(path: "audio/speech", accept: "audio/mpeg", body: try api.jsonBody(body))
            let (data, response) = try await api.data(for: request)
            try VeniceAPI.assertOK(data: data, response: response)
            return [try writeTemp(data: data, ext: "mp3").absoluteString]
        }

        // Async queue (music / SFX).
        var body: [String: Any] = ["model": model, "prompt": params.prompt]
        if let duration = params.durationSeconds, supportsAudioDuration(duration, model: catalogModel) {
            body["duration_seconds"] = duration
        }
        if catalogModel?.supportsLyrics ?? true, let lyrics = params.lyrics, !lyrics.isEmpty {
            body["lyrics_prompt"] = lyrics
        }
        if catalogModel?.supportsStyleInstructions == true,
           let instructions = params.styleInstructions, !instructions.isEmpty {
            body["style_instructions"] = instructions
        }
        if catalogModel?.supportsInstrumental ?? true, params.instrumental {
            body["force_instrumental"] = true
        }
        if let voice = params.voice,
           supports(voice, allowed: catalogModel?.voices, knownModel: catalogModel != nil) {
            body["voice"] = voice
        }
        if catalogModel?.inputs.contains(.video) == true, let videoURL = params.videoURL {
            body["video_url"] = videoURL
        }

        let queued = try await api.postJSON(path: "audio/queue", body: body)
        guard let queueId = queued["queue_id"] as? String else {
            throw VeniceAPI.VeniceError.decode("missing queue_id")
        }
        onQueue?(queueId, nil)
        return [try await pollAudio(queueId: queueId, model: model, api: api)]
    }

    /// Polls `/audio/retrieve` until the audio is ready. Requires queue_id + model.
    private static func pollAudio(queueId: String, model: String, api: VeniceAPI) async throws -> String {
        let deadline = Date().addingTimeInterval(10 * 60)
        while Date() < deadline {
            let request = api.makeRequest(
                path: "audio/retrieve",
                accept: "audio/mpeg",
                body: try api.jsonBody(["queue_id": queueId, "model": model])
            )
            let (data, response) = try await api.data(for: request)
            try VeniceAPI.assertOK(data: data, response: response)
            let contentType = ((response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if contentType.contains("audio/") {
                return try writeTemp(data: data, ext: contentType.contains("wav") ? "wav" : "mp3").absoluteString
            }
            try await Task.sleep(nanoseconds: 3_000_000_000)
        }
        throw VeniceAPI.VeniceError.transport("Audio generation timed out.")
    }

    // MARK: - Upscale

    private static func runUpscale(
        model: String, params: UpscaleGenerationParams, api: VeniceAPI
    ) async throws -> [String] {
        if let catalogModel = upscaleModel(for: model), !catalogModel.supportedTypes.contains(.image) {
            throw VeniceAPI.VeniceError.transport("\(catalogModel.displayName) does not support image upscale.")
        }
        // Venice /image/upscale takes a raw base64 image (no data: prefix) + scale.
        let body: [String: Any] = [
            "image": stripDataURLPrefix(params.sourceURL),
            "scale": 2,
            "enhance": true,
        ]
        let bytes = try await binaryOrBase64(path: "image/upscale", body: body, accept: "image/png", api: api)
        return [try writeTemp(data: bytes, ext: "png").absoluteString]
    }

    // MARK: - Helpers

    private static func videoModel(for id: String) -> VideoModelConfig? {
        if case .video(let model) = ModelRegistry.byId[id] { return model }
        return nil
    }

    private static func isSeedance(model: String) -> Bool {
        model.lowercased().contains("seedance")
    }

    private static func imageModel(for id: String) -> ImageModelConfig? {
        if case .image(let model) = ModelRegistry.byId[id] { return model }
        return nil
    }

    private static func audioModel(for id: String) -> AudioModelConfig? {
        if case .audio(let model) = ModelRegistry.byId[id] { return model }
        return nil
    }

    private static func upscaleModel(for id: String) -> UpscaleModelConfig? {
        if case .upscale(let model) = ModelRegistry.byId[id] { return model }
        return nil
    }

    private static func supports(_ value: String?, allowed: [String]?, knownModel: Bool) -> Bool {
        guard let value, !value.isEmpty else { return false }
        guard knownModel else { return true }
        guard let allowed, !allowed.isEmpty else { return false }
        return allowed.contains(value)
    }

    private static func supportsVideoDuration(_ duration: Int, model: VideoModelConfig?) -> Bool {
        guard let model else { return duration > 0 }
        return !model.durations.isEmpty && model.durations.contains(duration)
    }

    private static func supportsAudioDuration(_ duration: Int, model: AudioModelConfig?) -> Bool {
        guard duration > 0 else { return false }
        guard let model else { return true }
        if model.inputs.contains(.video) { return true }
        guard let allowed = model.durations, !allowed.isEmpty else { return false }
        return allowed.contains(duration)
    }

    private static func supportedRefs(_ refs: [String], limit: Int?) -> [String]? {
        guard !refs.isEmpty else { return nil }
        guard let limit else { return refs }
        guard limit > 0 else { return nil }
        return Array(refs.prefix(limit))
    }

    private static func supportsImageEditAspectRatio(model: String, aspectRatio: String?) -> Bool {
        guard let aspectRatio, !aspectRatio.isEmpty else { return false }
        if let editModel = ModelCatalog.shared.editModels.first(where: { $0.id == model }) {
            return !editModel.aspectRatios.isEmpty && editModel.aspectRatios.contains(aspectRatio)
        }
        if let imageModel = imageModel(for: model) {
            return !imageModel.aspectRatios.isEmpty && imageModel.aspectRatios.contains(aspectRatio)
        }
        return true
    }

    /// Performs a POST that may return either raw binary or a JSON envelope with
    /// base64 data, and normalizes both to `Data`.
    private static func binaryOrBase64(
        path: String, body: [String: Any], accept: String, api: VeniceAPI
    ) async throws -> Data {
        let request = api.makeRequest(path: path, accept: accept, body: try api.jsonBody(body))
        let (data, response) = try await api.data(for: request)
        try VeniceAPI.assertOK(data: data, response: response)
        let contentType = ((response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("application/json") {
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if let images = obj?["images"] as? [String], let first = images.first,
               let decoded = Data(base64Encoded: stripDataURLPrefix(first)) {
                return decoded
            }
            if let image = obj?["image"] as? String,
               let decoded = Data(base64Encoded: stripDataURLPrefix(image)) {
                return decoded
            }
            if let audio = obj?["audio"] as? String,
               let decoded = Data(base64Encoded: stripDataURLPrefix(audio)) {
                return decoded
            }
            throw VeniceAPI.VeniceError.decode("no media in response")
        }
        return data
    }

    private static func stripDataURLPrefix(_ s: String) -> String {
        guard let range = s.range(of: "base64,") else { return s }
        return String(s[range.upperBound...])
    }

    // MARK: - Silent-rejection guard

    // Venice occasionally answers HTTP 200 with a tiny placeholder instead of real
    // media. Treat an implausibly small payload as a failure so we never save an
    // unusable asset as a successful generation. Thresholds are conservative floors,
    // far below any real generated frame or clip.
    private enum SilentReject {
        static let imageMinBytes = 30_000
        static let videoMinBytes = 100_000
    }

    private static func assertPlausibleImage(_ data: Data) throws {
        if data.count < SilentReject.imageMinBytes {
            throw VeniceAPI.VeniceError.transport(
                "The model returned an empty or placeholder image. Try again or switch models."
            )
        }
    }

    private static func assertPlausibleVideo(_ data: Data) throws {
        if data.count < SilentReject.videoMinBytes {
            throw VeniceAPI.VeniceError.transport(
                "The model returned an empty or placeholder video. Try again or switch models."
            )
        }
    }

    private static func writeTemp(data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("venice-\(UUID().uuidString.prefix(8)).\(ext)")
        try data.write(to: url)
        return url
    }
}
