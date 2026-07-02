import Foundation

func unsupportedValue(model displayName: String, field: String, value: String, allowed: [String]) -> String {
    "\(displayName) does not support \(field) '\(value)'. Valid: \(allowed.joined(separator: ", "))."
}

/// Renders a duration ladder as natural language: [5] → "5s", [5,10] → "5s or 10s",
/// [5,10,15] → "5s, 10s, or 15s".
func durationPhrase(_ durations: [Int]) -> String {
    let labels = durations.map { "\($0)s" }
    switch labels.count {
    case 0: return ""
    case 1: return labels[0]
    case 2: return "\(labels[0]) or \(labels[1])"
    default:
        return labels.dropLast().joined(separator: ", ") + ", or " + labels[labels.count - 1]
    }
}

struct VideoModelConfig: Identifiable, Sendable {
    @MainActor
    static var allModels: [VideoModelConfig] { ModelCatalog.shared.video }

    let entry: CatalogEntry
    let caps: VideoCaps

    var id: String { entry.id }
    var displayName: String { entry.displayName }
    var creditsPerSecond: [String: Double] { entry.creditsPerSecond ?? [:] }
    var audioDiscountRate: [String: Double]? { entry.audioDiscountRate }

    var durations: [Int] { caps.durations }
    var resolutions: [String]? { caps.resolutions }
    var aspectRatios: [String] { caps.aspectRatios }
    var supportsFirstFrame: Bool { caps.supportsFirstFrame }
    var supportsLastFrame: Bool { caps.supportsLastFrame }
    var maxReferenceImages: Int { caps.maxReferenceImages }
    var maxReferenceVideos: Int { caps.maxReferenceVideos }
    var maxReferenceAudios: Int { caps.maxReferenceAudios }
    var maxTotalReferences: Int? { caps.maxTotalReferences }
    var maxCombinedVideoRefSeconds: Double? { caps.maxCombinedVideoRefSeconds }
    var maxCombinedAudioRefSeconds: Double? { caps.maxCombinedAudioRefSeconds }
    var framesAndReferencesExclusive: Bool { caps.framesAndReferencesExclusive }
    var referenceTagNoun: String { caps.referenceTagNoun }
    var requiresSourceVideo: Bool { caps.requiresSourceVideo }
    var requiresReferenceImage: Bool { caps.requiresReferenceImage }
    var audioConfigurable: Bool { caps.audioConfigurable }

    var supportsReferences: Bool {
        maxReferenceImages > 0 || maxReferenceVideos > 0 || maxReferenceAudios > 0
    }

    /// Total reference count available across types. Used by agent tool info.
    var maxReferences: Int {
        maxTotalReferences ?? (maxReferenceImages + maxReferenceVideos + maxReferenceAudios)
    }

    func audioDiscount(for resolution: String?) -> Double? {
        guard let dict = audioDiscountRate else { return nil }
        if let key = resolution, let v = dict[key] { return v }
        return dict[""]
    }

    func validate(
        duration: Int,
        aspectRatio: String,
        resolution: String?,
        validateDuration: Bool = true
    ) -> String? {
        if validateDuration, durations.isEmpty, duration > 0 {
            return "\(displayName) does not support duration."
        }
        if validateDuration, !durations.isEmpty, !durations.contains(duration) {
            // Many video models accept only a stepped ladder (e.g. Reference→Video
            // models at 5s/10s). List the rungs and point at the nearest one.
            let allowed = durations.sorted()
            var message = "\(displayName) supports \(durationPhrase(allowed)), not \(duration)s."
            if let nearest = allowed.min(by: { abs($0 - duration) < abs($1 - duration) }) {
                message += " Try \(nearest)s."
            }
            return message
        }
        if aspectRatios.isEmpty, !aspectRatio.isEmpty {
            return "\(displayName) does not support aspect ratio."
        }
        if !aspectRatios.isEmpty, !aspectRatio.isEmpty, !aspectRatios.contains(aspectRatio) {
            return unsupportedValue(model: displayName, field: "aspect ratio", value: aspectRatio, allowed: aspectRatios)
        }
        if let r = resolution, !r.isEmpty {
            guard let allowed = resolutions, !allowed.isEmpty else {
                return "\(displayName) does not support resolution."
            }
            if !allowed.contains(r) {
                return unsupportedValue(model: displayName, field: "resolution", value: r, allowed: allowed)
            }
        }
        return nil
    }
}

struct VideoGenerationParams: Encodable, Sendable {
    let prompt: String
    let duration: Int
    let aspectRatio: String
    let resolution: String?
    let sourceVideoURL: String?
    let startFrameURL: String?
    let endFrameURL: String?
    let referenceImageURLs: [String]
    let referenceVideoURLs: [String]
    let referenceAudioURLs: [String]
    let generateAudio: Bool

    init(
        prompt: String, duration: Int, aspectRatio: String, resolution: String?,
        sourceVideoURL: String? = nil,
        startFrameURL: String? = nil, endFrameURL: String? = nil,
        referenceImageURLs: [String] = [],
        referenceVideoURLs: [String] = [],
        referenceAudioURLs: [String] = [],
        generateAudio: Bool = true
    ) {
        self.prompt = prompt; self.duration = duration
        self.aspectRatio = aspectRatio; self.resolution = resolution
        self.sourceVideoURL = sourceVideoURL
        self.startFrameURL = startFrameURL; self.endFrameURL = endFrameURL
        self.referenceImageURLs = referenceImageURLs
        self.referenceVideoURLs = referenceVideoURLs
        self.referenceAudioURLs = referenceAudioURLs
        self.generateAudio = generateAudio
    }

    var hasAnyReferences: Bool {
        !referenceImageURLs.isEmpty || !referenceVideoURLs.isEmpty || !referenceAudioURLs.isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case kind, prompt, duration, aspectRatio, resolution, sourceVideoURL
        case startFrameURL, endFrameURL, referenceImageURLs, referenceVideoURLs
        case referenceAudioURLs, generateAudio
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("video", forKey: .kind)
        try c.encode(prompt, forKey: .prompt)
        try c.encode(duration, forKey: .duration)
        try c.encode(aspectRatio, forKey: .aspectRatio)
        try c.encodeIfPresent(resolution, forKey: .resolution)
        try c.encodeIfPresent(sourceVideoURL, forKey: .sourceVideoURL)
        try c.encodeIfPresent(startFrameURL, forKey: .startFrameURL)
        try c.encodeIfPresent(endFrameURL, forKey: .endFrameURL)
        if !referenceImageURLs.isEmpty { try c.encode(referenceImageURLs, forKey: .referenceImageURLs) }
        if !referenceVideoURLs.isEmpty { try c.encode(referenceVideoURLs, forKey: .referenceVideoURLs) }
        if !referenceAudioURLs.isEmpty { try c.encode(referenceAudioURLs, forKey: .referenceAudioURLs) }
        try c.encode(generateAudio, forKey: .generateAudio)
    }
}
