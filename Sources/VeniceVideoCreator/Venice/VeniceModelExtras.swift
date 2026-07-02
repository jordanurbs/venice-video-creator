import Foundation

extension VeniceAPI {
    /// Venice `/models/traits` — trait name → model ID map (e.g. "default",
    /// "fastest", "most_intelligent", "default_reasoning").
    func modelTraits(type: String = "text") async throws -> [String: String] {
        let obj = try await getJSON(path: "models/traits?type=\(type)")
        return (obj["data"] as? [String: String]) ?? [:]
    }

    /// Venice `/models/compatibility_mapping` — alias / OpenAI ID → Venice model ID.
    func compatibilityMapping(type: String = "text") async throws -> [String: String] {
        let obj = try await getJSON(path: "models/compatibility_mapping?type=\(type)")
        return (obj["data"] as? [String: String]) ?? [:]
    }
}

/// Caches Venice text-model traits + the OpenAI/alias compatibility mapping, so
/// the model picker can offer trait quick-picks and resolve legacy/alias ids.
@Observable
@MainActor
final class ModelTraitsCatalog {
    static let shared = ModelTraitsCatalog()

    /// trait name -> model id (text models)
    private(set) var textTraits: [String: String] = [:]
    /// alias id -> venice model id (text models)
    private(set) var compatibility: [String: String] = [:]

    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Friendly labels + ordering for the traits worth surfacing in the UI.
    static let displayTraits: [(key: String, label: String)] = [
        ("default", "Recommended"),
        ("fastest", "Fastest"),
        ("most_intelligent", "Most intelligent"),
        ("default_reasoning", "Reasoning"),
        ("function_calling_default", "Function calling"),
        ("default_vision", "Vision"),
        ("default_code", "Code"),
        ("most_uncensored", "Most uncensored"),
    ]

    private init() {}

    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        NotificationCenter.default.addObserver(
            forName: .veniceAPIKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        task?.cancel()
        guard let api = VeniceAPI.fromKeychain() else {
            textTraits = [:]
            compatibility = [:]
            return
        }
        task = Task { [weak self] in
            async let traits = try? api.modelTraits(type: "text")
            async let mapping = try? api.compatibilityMapping(type: "text")
            let (t, m) = await (traits, mapping)
            guard !Task.isCancelled else { return }
            self?.textTraits = t ?? [:]
            self?.compatibility = m ?? [:]
        }
    }

    /// Resolves a possibly-aliased model id to a concrete Venice id.
    func resolve(_ id: String) -> String {
        compatibility[id] ?? id
    }

    /// Trait quick-picks whose target model is in the current text catalog.
    func availableTraitPicks(in textModelIds: Set<String>) -> [(label: String, modelId: String)] {
        Self.displayTraits.compactMap { trait in
            guard let id = textTraits[trait.key] else { return nil }
            let resolved = resolve(id)
            guard textModelIds.contains(resolved) else { return nil }
            return (trait.label, resolved)
        }
    }
}
