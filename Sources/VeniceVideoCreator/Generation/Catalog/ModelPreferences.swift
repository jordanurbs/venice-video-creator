import Foundation

/// User model preferences, persisted in `UserDefaults`.
///
/// Two kinds of preference:
/// - `disabledIds`: models the user hid from the per-generation dropdowns.
/// - default model per task (`ModelTask`): the model used by default for the
///   agent's inference and for each generation type. The Settings → Models pane
///   is the single place to set all of these.
@Observable
@MainActor
final class ModelPreferences {
    static let shared = ModelPreferences()

    /// A task the user can pick a default model for.
    enum ModelTask: String, CaseIterable, Sendable {
        case agent          // chat / inference
        case image
        case textToVideo
        case imageToVideo
        case audio          // speech + music
        case upscale

        var title: String {
            switch self {
            case .agent: return "Agent (inference)"
            case .image: return "Image"
            case .textToVideo: return "Text to video"
            case .imageToVideo: return "Image to video"
            case .audio: return "Audio / music"
            case .upscale: return "Upscale"
            }
        }
    }

    private static let disabledKey = "disabledModelIds"
    private static let defaultsKey = "defaultModelIds"
    private static let characterSlugKey = "agentCharacterSlug"
    private static let seedanceConsentKey = "seedanceConsentGranted"
    private static let multiShotGroupingKey = "multiShotGroupingEnabled"

    private(set) var disabledIds: Set<String>
    /// task.rawValue -> model id
    private var defaultIds: [String: String]

    /// Optional Venice character persona slug applied to the agent (nil = none).
    var agentCharacterSlug: String? {
        didSet { UserDefaults.standard.set(agentCharacterSlug, forKey: Self.characterSlugKey) }
    }

    /// When true, Seedance video requests auto-attach the `consents.seedance`
    /// acknowledgement Venice requires for face-bearing media.
    var seedanceConsentGranted: Bool {
        didSet { UserDefaults.standard.set(seedanceConsentGranted, forKey: Self.seedanceConsentKey) }
    }

    /// When true, production groups consecutive same-scene shots into one
    /// multi-shot generation (`Lens switch.` beats — harness rule 21) instead
    /// of one render per shot. Opt-in: it changes paid request bodies, so the
    /// non-regression rule keeps it off by default.
    var multiShotGroupingEnabled: Bool {
        didSet { UserDefaults.standard.set(multiShotGroupingEnabled, forKey: Self.multiShotGroupingKey) }
    }

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []
        disabledIds = Set(stored)
        defaultIds = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
        agentCharacterSlug = UserDefaults.standard.string(forKey: Self.characterSlugKey)
        // Opt-in: off until granted in first-run setup or Settings → Models.
        seedanceConsentGranted = UserDefaults.standard.object(forKey: Self.seedanceConsentKey) as? Bool ?? false
        multiShotGroupingEnabled = UserDefaults.standard.object(forKey: Self.multiShotGroupingKey) as? Bool ?? false
    }

    // MARK: - Enable / disable

    func isEnabled(_ id: String) -> Bool { !disabledIds.contains(id) }

    func setEnabled(_ id: String, _ enabled: Bool) {
        if enabled {
            disabledIds.remove(id)
        } else {
            disabledIds.insert(id)
        }
        UserDefaults.standard.set(Array(disabledIds), forKey: Self.disabledKey)
    }

    /// True when every id in `ids` is enabled.
    func allEnabled(_ ids: [String]) -> Bool { ids.allSatisfy(isEnabled) }

    /// Bulk enable/disable, e.g. for a section's master toggle.
    func setEnabled(_ ids: [String], _ enabled: Bool) {
        if enabled {
            disabledIds.subtract(ids)
        } else {
            disabledIds.formUnion(ids)
        }
        UserDefaults.standard.set(Array(disabledIds), forKey: Self.disabledKey)
    }

    // MARK: - Per-task default model

    func defaultModel(for task: ModelTask) -> String? { defaultIds[task.rawValue] }

    func setDefaultModel(_ id: String?, for task: ModelTask) {
        if let id { defaultIds[task.rawValue] = id } else { defaultIds[task.rawValue] = nil }
        UserDefaults.standard.set(defaultIds, forKey: Self.defaultsKey)
    }

    /// Convenience for the agent: which Venice text model to use.
    var agentModelId: String? {
        get { defaultModel(for: .agent) }
        set { setDefaultModel(newValue, for: .agent) }
    }
}
