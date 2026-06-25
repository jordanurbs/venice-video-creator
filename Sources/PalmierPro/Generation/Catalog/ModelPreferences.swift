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

    private(set) var disabledIds: Set<String>
    /// task.rawValue -> model id
    private var defaultIds: [String: String]

    private init() {
        let stored = UserDefaults.standard.stringArray(forKey: Self.disabledKey) ?? []
        disabledIds = Set(stored)
        defaultIds = (UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String]) ?? [:]
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
