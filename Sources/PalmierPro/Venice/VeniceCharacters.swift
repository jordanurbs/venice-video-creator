import Foundation

/// A Venice public character (persona) usable via `character_slug`.
struct VeniceCharacter: Sendable, Identifiable, Hashable {
    let slug: String
    let name: String
    let description: String
    var id: String { slug }
}

extension VeniceAPI {
    /// Venice `/characters` — browse public persona catalog.
    func listCharacters(sortBy: String = "featured", limit: Int = 50) async throws -> [VeniceCharacter] {
        let obj = try await getJSON(path: "characters?sortBy=\(sortBy)&limit=\(max(1, min(100, limit)))")
        let data = (obj["data"] as? [[String: Any]]) ?? []
        return data.compactMap { row in
            guard let slug = row["slug"] as? String else { return nil }
            return VeniceCharacter(
                slug: slug,
                name: (row["name"] as? String) ?? slug,
                description: (row["description"] as? String) ?? ""
            )
        }
    }
}

/// Caches the Venice character catalog for the agent persona picker.
@Observable
@MainActor
final class CharacterCatalog {
    static let shared = CharacterCatalog()

    private(set) var characters: [VeniceCharacter] = []
    private(set) var isLoading = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: .veniceAPIKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didLoad = false
                self?.characters = []
            }
        }
    }

    /// Loads the catalog once (lazily, when the picker is first opened).
    func loadIfNeeded() {
        guard !didLoad, let api = VeniceAPI.fromKeychain() else { return }
        didLoad = true
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let loaded = (try? await api.listCharacters()) ?? []
            guard !Task.isCancelled else { return }
            self?.characters = loaded
            self?.isLoading = false
        }
    }

    func name(forSlug slug: String) -> String? {
        characters.first(where: { $0.slug == slug })?.name
    }
}
