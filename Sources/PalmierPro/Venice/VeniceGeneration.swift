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
        }
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
        // Image-to-video: the source image is a data URL produced by uploadReference.
        if let imageURL = params.startFrameURL ?? params.referenceImageURLs.first {
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
        let isMusic = ModelRegistry.byId[model].map { kind -> Bool in
            if case .audio(let m) = kind { return m.category == .music }
            return false
        } ?? false

        if isMusic {
            var body: [String: Any] = ["model": model, "prompt": params.prompt]
            if params.instrumental { body["instrumental"] = true }
            if let lyrics = params.lyrics { body["lyrics"] = lyrics }
            if let style = params.styleInstructions { body["style"] = style }
            let bytes = try await binaryOrBase64(path: "audio/music", body: body, accept: "audio/mpeg", api: api)
            return [try writeTemp(data: bytes, ext: "mp3").absoluteString]
        } else {
            let body: [String: Any] = [
                "model": model,
                "input": params.prompt,
                "voice": params.voice ?? VeniceVoices.defaults.first ?? "af_sky",
                "response_format": "mp3",
            ]
            let bytes = try await binaryOrBase64(path: "audio/speech", body: body, accept: "audio/mpeg", api: api)
            return [try writeTemp(data: bytes, ext: "mp3").absoluteString]
        }
    }

    // MARK: - Upscale

    private static func runUpscale(
        model: String, params: UpscaleGenerationParams, api: VeniceAPI
    ) async throws -> [String] {
        let body: [String: Any] = [
            "model": model,
            "image": params.sourceURL,
            "scale": 2,
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
