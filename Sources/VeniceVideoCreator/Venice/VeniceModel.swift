import Foundation

/// A Venice text/chat model usable by the in-app agent.
struct VeniceTextModel: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let supportsFunctionCalling: Bool
    let supportsVision: Bool
    /// Total context window (input) tokens the model accepts, from Venice's spec.
    var availableContextTokens: Int?
    /// Max output tokens the model can produce, from Venice's spec.
    var maxCompletionTokens: Int?
}

/// A Venice edit-capable image model (`/models?type=inpaint`) used by `/image/edit`.
struct VeniceEditModel: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let aspectRatios: [String]
}

/// The fully-parsed Venice model catalog, ready to apply to `ModelCatalog`.
/// All members are `Sendable` so parsing can happen off the main actor.
struct VeniceCatalog: Sendable {
    var entries: [CatalogEntry] = []
    var textModels: [VeniceTextModel] = []
    var editModels: [VeniceEditModel] = []
    var embeddingModels: [String] = []
}

extension VeniceAPI {
    /// Fetch `/models?type=all` and map it into the app's catalog types.
    func fetchCatalog() async throws -> VeniceCatalog {
        let obj = try await getJSON(path: "models?type=all")
        let data = (obj["data"] as? [[String: Any]]) ?? []
        // Add known-good models this key's /models omits (de-duped against live).
        return VeniceModelMapper.map(SupplementalModels.merged(into: data))
    }
}

/// Maps raw Venice `/models` JSON into `CatalogEntry` + text model lists.
enum VeniceModelMapper {
    static func map(_ data: [[String: Any]]) -> VeniceCatalog {
        var catalog = VeniceCatalog()
        for raw in data {
            guard let id = raw["id"] as? String,
                  let type = raw["type"] as? String else { continue }
            let spec = raw["model_spec"] as? [String: Any] ?? [:]
            let name = (spec["name"] as? String) ?? id
            let constraints = spec["constraints"] as? [String: Any] ?? [:]
            let capabilities = spec["capabilities"] as? [String: Any] ?? [:]
            let pricing = spec["pricing"] as? [String: Any] ?? [:]

            switch type {
            case "text":
                catalog.textModels.append(VeniceTextModel(
                    id: id,
                    displayName: name,
                    supportsFunctionCalling: capabilities["supportsFunctionCalling"] as? Bool ?? false,
                    supportsVision: capabilities["supportsVision"] as? Bool ?? false,
                    availableContextTokens: spec["availableContextTokens"] as? Int,
                    maxCompletionTokens: spec["maxCompletionTokens"] as? Int
                ))
            case "image":
                catalog.entries.append(imageEntry(id: id, name: name, constraints: constraints, pricing: pricing))
            case "video":
                catalog.entries.append(videoEntry(id: id, name: name, constraints: constraints, pricing: pricing))
            case "tts", "music":
                catalog.entries.append(audioEntry(id: id, name: name, type: type, spec: spec, pricing: pricing))
            case "upscale":
                catalog.entries.append(upscaleEntry(id: id, name: name, pricing: pricing))
            case "inpaint":
                let aspectRatios = (constraints["aspectRatios"] as? [String])
                    ?? (constraints["aspect_ratios"] as? [String]) ?? []
                catalog.editModels.append(VeniceEditModel(id: id, displayName: name, aspectRatios: aspectRatios))
            case "embedding":
                catalog.embeddingModels.append(id)
            default:
                break // asr models are not surfaced in the editor catalog
            }
        }
        return catalog
    }

    // MARK: - Per-type mapping

    private static func imageEntry(
        id: String, name: String, constraints: [String: Any], pricing: [String: Any]
    ) -> CatalogEntry {
        let aspectRatios = (constraints["aspectRatios"] as? [String]) ?? ["1:1", "16:9", "9:16", "3:2", "2:3"]
        let resolutions = constraints["resolutions"] as? [String]
        let qualities = constraints["qualities"] as? [String]
        let caps = ImageCaps(
            resolutions: resolutions,
            aspectRatios: aspectRatios,
            qualities: qualities,
            supportsImageReference: (constraints["combineImages"] as? Bool) ?? true,
            maxImages: 4
        )
        // Image price is a flat per-image USD under pricing.generation.usd.
        let perImageCents = (nestedUSD(pricing, "generation") ?? 0) * 100
        return CatalogEntry(
            id: id, kind: .image, displayName: name,
            allowedEndpoints: ["image/generate"], responseShape: .images,
            uiCapabilities: .image(caps),
            creditsPerImage: ["": perImageCents]
        )
    }

    private static func videoEntry(
        id: String, name: String, constraints: [String: Any], pricing: [String: Any]
    ) -> CatalogEntry {
        let aspectRatios = (constraints["aspect_ratios"] as? [String]) ?? []
        let resolutions = constraints["resolutions"] as? [String]
        let durations = parseDurations(constraints["durations"] as? [String]) 
        let modelType = (constraints["model_type"] as? String) ?? "text-to-video"
        let videoInput = (constraints["video_input"] as? Bool) ?? false
        let audioConfigurable = (constraints["audio_configurable"] as? Bool) ?? false
        // Venice's model_type reports "image-to-video" for both image-to-video and
        // reference-to-video; only the id slug distinguishes them. They route their
        // image input to different request fields (image_url vs reference_image_urls),
        // so they must offer different input slots.
        let isVideoToVideo = modelType == "video" || videoInput
        let isReferenceToVideo = !isVideoToVideo && id.contains("reference-to-video")
        let isImageToVideo = !isVideoToVideo && !isReferenceToVideo && modelType == "image-to-video"
        let needsImageInput = isImageToVideo || isReferenceToVideo
        // Venice exposes the same model under several variants that share a name
        // (text-to-video / image-to-video / reference-to-video). Append the
        // variant so the picker shows distinct, self-explanatory entries.
        let variant: String = isVideoToVideo ? "Video→Video"
            : isReferenceToVideo ? "Reference→Video"
            : isImageToVideo ? "Image→Video"
            : "Text→Video"
        let displayName = "\(name) (\(variant))"
        // Venice doesn't expose end-frame support in constraints; enable it only
        // where usable — i2v models (end frame shares the first-frame slot) whose
        // family the harness registry marks end-image-capable.
        let supportsLastFrame = isImageToVideo && VideoModelCapabilities.supportsEndImage(id: id)
        // Venice's constraints don't flag audio_url support; enable a single audio
        // input for the families the harness registry marks audio-capable. Short
        // clips are padded to the model's floor before upload (see VideoGenerationSubmission).
        let maxReferenceAudios = VideoModelCapabilities.audioInputCapable(id: id) ? 1 : 0
        let caps = VideoCaps(
            durations: durations.isEmpty ? [5] : durations,
            resolutions: resolutions,
            aspectRatios: aspectRatios,
            supportsFirstFrame: isImageToVideo,
            supportsLastFrame: supportsLastFrame,
            maxReferenceImages: isReferenceToVideo ? 4 : 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: maxReferenceAudios,
            maxTotalReferences: nil,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "reference",
            requiresSourceVideo: isVideoToVideo,
            requiresReferenceImage: needsImageInput,
            audioConfigurable: audioConfigurable
        )
        return CatalogEntry(
            id: id, kind: .video, displayName: displayName,
            allowedEndpoints: ["video/queue"], responseShape: .video,
            uiCapabilities: .video(caps),
            creditsPerSecond: ["": usdPrice(pricing)]
        )
    }

    private static func audioEntry(
        id: String, name: String, type: String, spec: [String: Any], pricing: [String: Any]
    ) -> CatalogEntry {
        // Venice splits audio across two endpoints:
        //  - `type == "tts"` models use the synchronous OpenAI-style /audio/speech.
        //  - `type == "music"` models (music, SFX, and some hosted TTS) use the
        //    async /audio/queue + /audio/retrieve flow.
        let lower = (id + " " + name).lowercased()
        let isSpeechEndpoint = (type == "tts")
        let isSFX = lower.contains("sound-effect") || lower.contains("sound effect") || lower.contains("sfx")
        let isTTSLike = isSpeechEndpoint || lower.contains("tts") || lower.contains("text to speech")
        let constraints = spec["constraints"] as? [String: Any] ?? [:]
        // Honor an explicit category (used by supplemental async-TTS models like Seed Audio),
        // else fall back to the slug/name heuristic.
        let explicitCategory = (constraints["category"] as? String) ?? (spec["category"] as? String)
        let categoryStr: String = explicitCategory.map { $0.lowercased() }
            .flatMap { ["tts", "music", "sfx"].contains($0) ? $0 : nil }
            ?? (isTTSLike ? "tts" : (isSFX ? "sfx" : "music"))
        let endpoint = isSpeechEndpoint ? "audio/speech" : "audio/queue"

        // Venice video-to-music / video-to-audio models score a source video.
        // The slug is the reliable signal, but honor an explicit spec flag too.
        let declaredInputs = (constraints["inputs"] as? [String]) ?? (spec["inputs"] as? [String]) ?? []
        let hasVideoInput = !isSpeechEndpoint && (
            lower.contains("video-to-music") || lower.contains("video to music")
            || lower.contains("video-to-audio") || lower.contains("video to audio")
            || (constraints["video_input"] as? Bool ?? false)
            || (spec["video_input"] as? Bool ?? false)
            || declaredInputs.contains { $0.lowercased().contains("video") }
        )
        let inputs = hasVideoInput ? ["text", "video"] : ["text"]

        // Pre-flight metadata, read from constraints when Venice (or a supplemental entry) exposes it.
        let voices = (constraints["voices"] as? [String]) ?? (spec["voices"] as? [String])
        let defaultVoice = (constraints["default_voice"] as? String) ?? (spec["default_voice"] as? String)
        let durations = (constraints["durations"] as? [String]).map(parseDurations)
        let maxPromptLength = (constraints["max_prompt_length"] as? Int) ?? (spec["max_prompt_length"] as? Int)
        let minPromptLength = (constraints["min_prompt_length"] as? Int) ?? 1
        let minSpeed = (constraints["min_speed"] as? Double)
        let maxSpeed = (constraints["max_speed"] as? Double)
        let formats = (constraints["formats"] as? [String]) ?? (constraints["response_formats"] as? [String])

        let caps = AudioCaps(
            category: categoryStr,
            voices: voices,
            defaultVoice: defaultVoice,
            supportsLyrics: (spec["supports_lyrics"] as? Bool) ?? (constraints["supports_lyrics"] as? Bool) ?? false,
            supportsInstrumental: (spec["supports_force_instrumental"] as? Bool) ?? (constraints["supports_force_instrumental"] as? Bool) ?? false,
            supportsStyleInstructions: (constraints["supports_style_instructions"] as? Bool) ?? false,
            durations: durations,
            minPromptLength: minPromptLength,
            inputs: inputs,
            promptLabel: categoryStr == "tts" ? "Text to speak"
                : (categoryStr == "sfx" ? "Describe the sound" : "Describe the music"),
            minSeconds: 1,
            maxSeconds: 600,
            maxPromptLength: maxPromptLength,
            minSpeed: minSpeed,
            maxSpeed: maxSpeed,
            formats: formats
        )
        // Per-second pricing when declared (e.g. Seed Audio ~$0.0029/s), else char-based.
        let audioPricing: CatalogEntry.AudioPricing
        if let perSecond = (pricing["usd_per_second"] as? Double) ?? nestedUSD(pricing, "per_second") {
            audioPricing = .perSecond(rate: perSecond)
        } else {
            audioPricing = .perThousandChars(rate: usdPrice(pricing))
        }
        return CatalogEntry(
            id: id, kind: .audio, displayName: name,
            allowedEndpoints: [endpoint],
            responseShape: .audio,
            uiCapabilities: .audio(caps),
            audioPricing: audioPricing
        )
    }

    private static func upscaleEntry(id: String, name: String, pricing: [String: Any]) -> CatalogEntry {
        // Venice's upscaler is image-only (no video upscaling). Price is a flat
        // per-image USD (2x). The editor multiplies by duration (1 for images).
        let upscale = pricing["upscale"] as? [String: Any]
        let perCents = ((upscale?["2x"] as? [String: Any])?["usd"] as? Double ?? 0.02) * 100
        let caps = UpscaleCaps(speed: "Medium", p75DurationSeconds: 30, supportedTypes: ["image"])
        return CatalogEntry(
            id: id, kind: .upscale, displayName: name,
            allowedEndpoints: ["image/upscale"], responseShape: .upscaledImage,
            uiCapabilities: .upscale(caps),
            creditsPerSecondUpscale: perCents
        )
    }

    // MARK: - Helpers

    /// Venice durations arrive as strings like "5s"; convert to integer seconds.
    private static func parseDurations(_ raw: [String]?) -> [Int] {
        (raw ?? []).compactMap { Int($0.replacingOccurrences(of: "s", with: "")) }
    }

    /// USD price nested under `pricing.<key>.usd` (e.g. "generation").
    private static func nestedUSD(_ pricing: [String: Any], _ key: String) -> Double? {
        (pricing[key] as? [String: Any])?["usd"] as? Double
    }

    /// Pull a representative USD price out of Venice's pricing object so the app's
    /// (now informational) "credits" estimate has something to show. Scaled to
    /// approximate cents because the editor speaks in integer "credits".
    private static func usdPrice(_ pricing: [String: Any]) -> Double {
        func usd(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let dict = any as? [String: Any] { return dict["usd"] as? Double }
            return nil
        }
        let candidate = usd(pricing["usd"])
            ?? usd(pricing["output"])
            ?? usd(pricing["input"])
            ?? 0
        return candidate * 100.0
    }
}

/// Default Venice (Kokoro) TTS voices, used when a model doesn't enumerate its own.
enum VeniceVoices {
    static let defaults = ["af_sky", "af_bella", "af_nicole", "am_adam", "am_michael", "bf_emma", "bm_george"]
}

// MARK: - CatalogEntry construction

extension CatalogEntry {
    /// Memberwise initializer used when building the catalog from Venice models
    /// (the type otherwise only has a `Decodable` init for the legacy backend).
    init(
        id: String,
        kind: Kind,
        displayName: String,
        allowedEndpoints: [String],
        responseShape: ResponseShape,
        uiCapabilities: UICapabilities,
        creditsPerSecond: [String: Double]? = nil,
        audioDiscountRate: [String: Double]? = nil,
        creditsPerImage: [String: Double]? = nil,
        qualities: [String]? = nil,
        audioPricing: AudioPricing? = nil,
        creditsPerSecondUpscale: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.allowedEndpoints = allowedEndpoints
        self.responseShape = responseShape
        self.uiCapabilities = uiCapabilities
        self.creditsPerSecond = creditsPerSecond
        self.audioDiscountRate = audioDiscountRate
        self.creditsPerImage = creditsPerImage
        self.qualities = qualities
        self.audioPricing = audioPricing
        self.creditsPerSecondUpscale = creditsPerSecondUpscale
    }
}
