import Foundation

/// The harness capability manifest — the machine-readable export of the
/// probe-verified `venice-video-harness` registry (`venice-video capabilities`,
/// harness ≥2.15.0). Carries exact-id capability sets, per-model budgets, and
/// routing defaults that Venice's `/models` payload does not expose.
///
/// Decoded tolerantly: unknown fields are ignored, missing sets fall back to
/// empty (which reads as "capability off" — the conservative default). A
/// manifest with a `schemaVersion` above what this build understands is
/// rejected so a future shape change can never mis-enable a paid capability.
struct CapabilityManifest: Codable, Sendable, Equatable {
    /// Highest manifest schema this build knows how to interpret.
    static let supportedSchemaVersion = 1

    var schemaVersion: Int
    var harnessVersion: String
    var generatedAt: String
    var capabilitySets: CapabilitySets
    var budgets: Budgets
    var defaults: Defaults
    var videoModels: [VideoModelSpec]

    struct CapabilitySets: Codable, Sendable, Equatable {
        var elements: [String]
        var referenceImages: [String]
        var sceneImages: [String]
        var endImage: [String]
        /// Pure-reference models that honor @ImageN prompt tags and reject image_url.
        var imageTags: [String]
        var audioInput: [String]
        var perReferenceAudio: [String]
        var referenceAudio: [String]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            elements = try c.decodeIfPresent([String].self, forKey: .elements) ?? []
            referenceImages = try c.decodeIfPresent([String].self, forKey: .referenceImages) ?? []
            sceneImages = try c.decodeIfPresent([String].self, forKey: .sceneImages) ?? []
            endImage = try c.decodeIfPresent([String].self, forKey: .endImage) ?? []
            imageTags = try c.decodeIfPresent([String].self, forKey: .imageTags) ?? []
            audioInput = try c.decodeIfPresent([String].self, forKey: .audioInput) ?? []
            perReferenceAudio = try c.decodeIfPresent([String].self, forKey: .perReferenceAudio) ?? []
            referenceAudio = try c.decodeIfPresent([String].self, forKey: .referenceAudio) ?? []
        }
    }

    struct Budgets: Codable, Sendable, Equatable {
        var maxReferenceImagesByModel: [String: Int]
        var defaultMaxReferenceImages: Int
        var videoPromptCharLimit: Int

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            maxReferenceImagesByModel = try c.decodeIfPresent([String: Int].self, forKey: .maxReferenceImagesByModel) ?? [:]
            defaultMaxReferenceImages = try c.decodeIfPresent(Int.self, forKey: .defaultMaxReferenceImages) ?? 4
            videoPromptCharLimit = try c.decodeIfPresent(Int.self, forKey: .videoPromptCharLimit) ?? 2500
        }
    }

    struct Defaults: Codable, Sendable, Equatable {
        var actionModel: String?
        var atmosphereModel: String?
        var characterConsistencyModel: String?
        var multiShotModel: String?
        var lipSyncModel: String?
    }

    /// One harness `VideoModelSpec`. Only the fields the app consumes are
    /// decoded; the rest of the object is ignored.
    struct VideoModelSpec: Codable, Sendable, Equatable {
        var id: String
        var audioInput: Bool
        var supportsEndImage: Bool
        var supportsReferenceImages: Bool
        var minAudioInputSec: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            audioInput = try c.decodeIfPresent(Bool.self, forKey: .audioInput) ?? false
            supportsEndImage = try c.decodeIfPresent(Bool.self, forKey: .supportsEndImage) ?? false
            supportsReferenceImages = try c.decodeIfPresent(Bool.self, forKey: .supportsReferenceImages) ?? false
            minAudioInputSec = try c.decodeIfPresent(Double.self, forKey: .minAudioInputSec)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        guard schemaVersion >= 1, schemaVersion <= Self.supportedSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion, in: c,
                debugDescription: "Unsupported capability manifest schemaVersion \(schemaVersion) (this build supports ≤\(Self.supportedSchemaVersion))"
            )
        }
        harnessVersion = try c.decodeIfPresent(String.self, forKey: .harnessVersion) ?? "unknown"
        generatedAt = try c.decodeIfPresent(String.self, forKey: .generatedAt) ?? ""
        capabilitySets = try c.decode(CapabilitySets.self, forKey: .capabilitySets)
        budgets = try c.decode(Budgets.self, forKey: .budgets)
        defaults = try c.decodeIfPresent(Defaults.self, forKey: .defaults) ?? Defaults()
        videoModels = try c.decodeIfPresent([VideoModelSpec].self, forKey: .videoModels) ?? []
    }

    // MARK: - Lookups (exact id, O(1) after first use)

    /// Ids the manifest knows at all — membership gates exact-id resolution
    /// (unknown ids fall back to family substrings, then conservative off).
    var knownIds: Set<String> { Set(videoModels.map(\.id)) }

    func minAudioInputSeconds(id: String) -> Double? {
        videoModels.first(where: { $0.id == id })?.minAudioInputSec
    }
}
