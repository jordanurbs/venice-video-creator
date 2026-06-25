import Foundation

/// Executes a single Venice generation request and returns result URLs that
/// `GenerationService` can download/finalize. Image generation is synchronous;
/// video generation goes through Venice's async queue/retrieve flow.
@MainActor
enum VeniceGenerationRunner {
    static func run(
        model: String,
        params: BackendGenerationParams,
        api: VeniceAPI
    ) async throws -> [String] {
        switch params {
        case .image(let p): return try await runImage(model: model, params: p, api: api)
        case .video(let p): return try await runVideo(model: model, params: p, api: api)
        case .audio(let p): return try await runAudio(model: model, params: p, api: api)
        case .upscale(let p): return try await runUpscale(model: model, params: p, api: api)
        case .imageEdit(let p): return try await runImageEdit(model: model, params: p, api: api)
        case .imageMultiEdit(let p): return try await runImageMultiEdit(model: model, params: p, api: api)
        case .backgroundRemove(let p): return try await runBackgroundRemove(params: p, api: api)
        }
    }

    // MARK: - Image edit / multi-edit / background-remove

    /// Venice `/image/edit` — prompt-driven single-image transform. Returns PNG.
    private static func runImageEdit(
        model: String, params: ImageEditParams, api: VeniceAPI
    ) async throws -> [String] {
        var body: [String: Any] = [
            "model": model.isEmpty ? VeniceBuiltInModel.defaultEdit : model,
            "prompt": params.prompt,
            "image": stripDataURLPrefix(params.sourceURL),
            "safe_mode": false,
        ]
        if let ar = params.aspectRatio, !ar.isEmpty { body["aspect_ratio"] = ar }
        let bytes = try await binaryOrBase64(path: "image/edit", body: body, accept: "image/png", api: api)
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
        return [try writeTemp(data: bytes, ext: "png").absoluteString]
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
        var body: [String: Any] = [
            "model": model,
            "prompt": params.prompt,
            "format": "png",
            "safe_mode": false,
            "return_binary": false,
            "variants": max(1, min(4, params.numImages)),
        ]
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = params.aspectRatio }
        if let resolution = params.resolution, !resolution.isEmpty { body["resolution"] = resolution }
        if let quality = params.quality, !quality.isEmpty { body["quality"] = quality }
        if let style = params.stylePreset, !style.isEmpty { body["style_preset"] = style }
        // Best-effort reference image passthrough for models that accept it.
        if let first = params.imageURLs.first { body["image"] = first }

        let obj = try await api.postJSON(path: "image/generate", body: body)
        guard let images = obj["images"] as? [String], !images.isEmpty else {
            throw VeniceAPI.VeniceError.empty
        }
        return try images.map { base64 in
            guard let data = Data(base64Encoded: stripDataURLPrefix(base64)) else {
                throw VeniceAPI.VeniceError.decode("invalid base64 image")
            }
            return try writeTemp(data: data, ext: "png").absoluteString
        }
    }

    // MARK: - Video (async queue + poll)

    private static func runVideo(
        model: String, params: VideoGenerationParams, api: VeniceAPI
    ) async throws -> [String] {
        var body: [String: Any] = [
            "model": model,
            "prompt": params.prompt,
            "duration": "\(max(1, params.duration))s",
        ]
        if let resolution = params.resolution, !resolution.isEmpty { body["resolution"] = resolution }
        if !params.aspectRatio.isEmpty { body["aspect_ratio"] = params.aspectRatio }
        // Image-to-video / reference-to-video / video-to-video all condition on a
        // source passed via image_url (a data URL produced by uploadReference).
        if let imageURL = params.startFrameURL ?? params.referenceImageURLs.first ?? params.sourceVideoURL {
            body["image_url"] = imageURL
        }

        let queued = try await api.postJSON(path: "video/queue", body: body)
        guard let queueId = queued["queue_id"] as? String else {
            throw VeniceAPI.VeniceError.decode("missing queue_id")
        }
        let downloadURL = queued["download_url"] as? String

        return [try await pollVideo(queueId: queueId, model: model, downloadURL: downloadURL, api: api)]
    }

    /// Polls `/video/retrieve` until the video is ready, returning a downloadable URL.
    /// Venice requires both `queue_id` and `model` on the retrieve call.
    private static func pollVideo(
        queueId: String, model: String, downloadURL: String?, api: VeniceAPI
    ) async throws -> String {
        let deadline = Date().addingTimeInterval(15 * 60)
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
                return try writeTemp(data: data, ext: "mp4").absoluteString
            }
            // Otherwise it's a JSON status payload.
            let status = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["status"] as? String
            if status?.uppercased() == "COMPLETED" {
                if let downloadURL { return downloadURL }
                return try writeTemp(data: data, ext: "mp4").absoluteString
            }
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
        throw VeniceAPI.VeniceError.transport("Video generation timed out.")
    }

    // MARK: - Audio

    private static func runAudio(
        model: String, params: AudioGenerationParams, api: VeniceAPI
    ) async throws -> [String] {
        // Route by the endpoint recorded in the catalog: type=tts models use the
        // synchronous /audio/speech; music/SFX use the async /audio/queue flow.
        let usesSpeech = ModelRegistry.byId[model].map { kind -> Bool in
            if case .audio(let m) = kind { return m.entry.allowedEndpoints.contains("audio/speech") }
            return false
        } ?? false

        if usesSpeech {
            var body: [String: Any] = [
                "model": model,
                "input": params.prompt,
                "response_format": "mp3",
            ]
            if let voice = params.voice, !voice.isEmpty { body["voice"] = voice }
            let request = api.makeRequest(path: "audio/speech", accept: "audio/mpeg", body: try api.jsonBody(body))
            let (data, response) = try await api.data(for: request)
            try VeniceAPI.assertOK(data: data, response: response)
            return [try writeTemp(data: data, ext: "mp3").absoluteString]
        }

        // Async queue (music / SFX).
        var body: [String: Any] = ["model": model, "prompt": params.prompt]
        if let duration = params.durationSeconds, duration > 0 { body["duration_seconds"] = duration }
        if let lyrics = params.lyrics, !lyrics.isEmpty { body["lyrics_prompt"] = lyrics }
        if params.instrumental { body["force_instrumental"] = true }
        if let voice = params.voice, !voice.isEmpty { body["voice"] = voice }

        let queued = try await api.postJSON(path: "audio/queue", body: body)
        guard let queueId = queued["queue_id"] as? String else {
            throw VeniceAPI.VeniceError.decode("missing queue_id")
        }
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

    private static func writeTemp(data: Data, ext: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("venice-\(UUID().uuidString.prefix(8)).\(ext)")
        try data.write(to: url)
        return url
    }
}
