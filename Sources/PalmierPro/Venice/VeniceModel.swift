import Foundation

/// A Venice text/chat model usable by the in-app agent.
struct VeniceTextModel: Sendable, Identifiable, Hashable {
    let id: String
    let displayName: String
    let supportsFunctionCalling: Bool
    let supportsVision: Bool
}

/// The fully-parsed Venice model catalog, ready to apply to `ModelCatalog`.
/// All members are `Sendable` so parsing can happen off the main actor.
struct VeniceCatalog: Sendable {
    var entries: [CatalogEntry] = []
    var textModels: [VeniceTextModel] = []
}

extension VeniceAPI {
    /// Fetch `/models?type=all` and map it into the app's catalog types.
    func fetchCatalog() async throws -> VeniceCatalog {
        let obj = try await getJSON(path: "models?type=all")
        let data = (obj["data"] as? [[String: Any]]) ?? []
        return VeniceModelMapper.map(data)
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
                    supportsVision: capabilities["supportsVision"] as? Bool ?? false
                ))
            case "image":
                catalog.entries.append(imageEntry(id: id, name: name, constraints: constraints, pricing: pricing))
            case "video":
                catalog.entries.append(videoEntry(id: id, name: name, constraints: constraints, pricing: pricing))
            case "tts", "music":
                catalog.entries.append(audioEntry(id: id, name: name, type: type, spec: spec, pricing: pricing))
            case "upscale":
                catalog.entries.append(upscaleEntry(id: id, name: name, pricing: pricing))
            default:
                break // asr / embedding / inpaint are not surfaced in the editor catalog
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
        return CatalogEntry(
            id: id, kind: .image, displayName: name,
            allowedEndpoints: ["image/generate"], responseShape: .images,
            uiCapabilities: .image(caps),
            creditsPerImage: ["": usdPrice(pricing)]
        )
    }

    private static func videoEntry(
        id: String, name: String, constraints: [String: Any], pricing: [String: Any]
    ) -> CatalogEntry {
        let aspectRatios = (constraints["aspect_ratios"] as? [String]) ?? []
        let resolutions = constraints["resolutions"] as? [String]
        let durations = parseDurations(constraints["durations"] as? [String]) 
        let modelType = (constraints["model_type"] as? String) ?? "text-to-video"
        let isImageToVideo = modelType == "image-to-video"
        let caps = VideoCaps(
            durations: durations.isEmpty ? [5] : durations,
            resolutions: resolutions,
            aspectRatios: aspectRatios,
            supportsFirstFrame: isImageToVideo,
            supportsLastFrame: false,
            maxReferenceImages: isImageToVideo ? 1 : 0,
            maxReferenceVideos: 0,
            maxReferenceAudios: 0,
            maxTotalReferences: isImageToVideo ? 1 : 0,
            maxCombinedVideoRefSeconds: nil,
            maxCombinedAudioRefSeconds: nil,
            framesAndReferencesExclusive: false,
            referenceTagNoun: "reference",
            requiresSourceVideo: false,
            requiresReferenceImage: isImageToVideo
        )
        return CatalogEntry(
            id: id, kind: .video, displayName: name,
            allowedEndpoints: ["video/queue"], responseShape: .video,
            uiCapabilities: .video(caps),
            creditsPerSecond: ["": usdPrice(pricing)]
        )
    }

    private static func audioEntry(
        id: String, name: String, type: String, spec: [String: Any], pricing: [String: Any]
    ) -> CatalogEntry {
        let isMusic = type == "music"
        let caps = AudioCaps(
            category: isMusic ? "music" : "tts",
            voices: isMusic ? nil : VeniceVoices.defaults,
            defaultVoice: isMusic ? nil : VeniceVoices.defaults.first,
            supportsLyrics: (spec["supports_lyrics"] as? Bool) ?? false,
            supportsInstrumental: (spec["supports_force_instrumental"] as? Bool) ?? isMusic,
            supportsStyleInstructions: isMusic,
            durations: nil,
            minPromptLength: 1,
            inputs: ["text"],
            promptLabel: isMusic ? "Describe the music" : "Text to speak",
            minSeconds: nil,
            maxSeconds: nil
        )
        return CatalogEntry(
            id: id, kind: .audio, displayName: name,
            allowedEndpoints: [isMusic ? "audio/music" : "audio/speech"],
            responseShape: .audio,
            uiCapabilities: .audio(caps),
            audioPricing: .perThousandChars(rate: usdPrice(pricing))
        )
    }

    private static func upscaleEntry(id: String, name: String, pricing: [String: Any]) -> CatalogEntry {
        let caps = UpscaleCaps(speed: "Medium", p75DurationSeconds: 30, supportedTypes: ["image", "video"])
        return CatalogEntry(
            id: id, kind: .upscale, displayName: name,
            allowedEndpoints: ["image/upscale"], responseShape: .upscaledImage,
            uiCapabilities: .upscale(caps),
            creditsPerSecondUpscale: usdPrice(pricing)
        )
    }

    // MARK: - Helpers

    /// Venice durations arrive as strings like "5s"; convert to integer seconds.
    private static func parseDurations(_ raw: [String]?) -> [Int] {
        (raw ?? []).compactMap { Int($0.replacingOccurrences(of: "s", with: "")) }
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
