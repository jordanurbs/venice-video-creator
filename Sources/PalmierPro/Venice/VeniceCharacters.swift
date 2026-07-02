import Foundation

/// A Venice public character (persona) usable via `character_slug`.
struct VeniceCharacter: Sendable, Identifiable, Hashable {
    let slug: String
    let name: String
    let description: String
    var id: String { slug }

    /// Public Venice page for this character (`venice.ai/c/<slug>`).
    var veniceURL: URL { URL(string: "https://venice.ai/c/\(slug)")! }
}

extension VeniceAPI {
    /// Venice `/characters` — browse/search the public persona catalog.
    /// `search` matches name, description, or tags (server-side).
    func listCharacters(
        search: String? = nil,
        sortBy: String = "featured",
        limit: Int = 50
    ) async throws -> [VeniceCharacter] {
        var path = "characters?sortBy=\(sortBy)&limit=\(max(1, min(100, limit)))"
        if let search, !search.isEmpty {
            let encoded = search.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? search
            path += "&search=\(encoded)"
        }
        let obj = try await getJSON(path: path)
        let data = (obj["data"] as? [[String: Any]]) ?? []
        return data.compactMap(VeniceCharacter.init(row:))
    }

    /// Venice `/characters/{slug}` — fetch a single character by its public slug.
    /// Returns `nil` on 404 (unknown/unpublished slug).
    func character(slug: String) async throws -> VeniceCharacter? {
        let trimmed = slug.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        do {
            let obj = try await getJSON(path: "characters/\(encoded)")
            guard let row = obj["data"] as? [String: Any] else { return nil }
            return VeniceCharacter(row: row)
        } catch let VeniceError.http(status, _) where status == 404 {
            return nil
        }
    }
}

private extension VeniceCharacter {
    init?(row: [String: Any]) {
        guard let slug = row["slug"] as? String else { return nil }
        self.init(
            slug: slug,
            name: (row["name"] as? String) ?? slug,
            description: (row["description"] as? String) ?? ""
        )
    }
}

/// Caches the Venice character catalog for the agent persona picker.
///
/// The default list is curated to writing / creative / prompt-engineering
/// personas, but the user can search the full Venice catalog (and pull any
/// character by exact slug) via `setSearch`.
@Observable
@MainActor
final class CharacterCatalog {
    static let shared = CharacterCatalog()

    /// Venice character list / chat page (creation lives behind its "+" button).
    /// Venice exposes no character-creation API — only GET endpoints — so this is
    /// a link-out rather than an in-app create flow.
    static let createCharacterURL = URL(string: "https://venice.ai/character-chat")!

    /// Display order of the curated default categories.
    static let categoryOrder = ["Story & writing", "Prompt writing", "Assistants"]

    /// Hand-picked default personas (shown when the search field is empty),
    /// curated from the Venice catalog for a filmmaking / AI-generation workflow.
    /// Order here is the display order within each category; any slug that no
    /// longer resolves is silently dropped.
    private static let curated: [(slug: String, category: String)] = [
        ("ai-scenario-creator", "Story & writing"),                       // story/scenario development
        ("new-writers-workshop", "Story & writing"),                      // creative writing workshop
        ("professor-aris-thorne", "Story & writing"),                     // descriptive writing specialist
        ("masterful-prompter-writerengineer", "Prompt writing"),          // AI prompt writing
        ("the-architect-of-precision-the-architect", "Prompt writing"),   // elite prompt engineer
        ("video-prompt-guide", "Prompt writing"),                         // prompts for AI video
        ("seedance-20-prompt-creator", "Prompt writing"),                 // Seedance video-model prompts
        ("sasha-surreal-ultra-hd-photo-agent", "Prompt writing"),         // image-generation prompts
        ("persona-tensor-generator", "Assistants"),                       // build/refine AI characters
        ("lucy", "Assistants"),                                           // general critical-thinking assistant (web)
        ("ara-9", "Assistants"),                                          // source-driven research assistant
    ]

    private static let categoryBySlug: [String: String] =
        Dictionary(uniqueKeysWithValues: curated.map { ($0.slug, $0.category) })

    /// Curated default personas, shown when the search field is empty.
    private(set) var characters: [VeniceCharacter] = []
    /// Results for the current search query (empty when not searching).
    private(set) var searchResults: [VeniceCharacter] = []
    private(set) var isLoading = false
    private(set) var isSearching = false
    /// The active search query (empty = show curated defaults).
    private(set) var query = ""

    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false
    /// Resolved slug → name for label display (covers defaults, search, lookups).
    private var nameCache: [String: String] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: .veniceAPIKeyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.didLoad = false
                self?.characters = []
                self?.searchResults = []
                self?.query = ""
            }
        }
    }

    /// Loads the curated default catalog once (lazily, when the picker appears).
    func loadIfNeeded() {
        guard !didLoad, let api = VeniceAPI.fromKeychain() else { return }
        didLoad = true
        isLoading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            // Fetch the curated slugs concurrently, preserving the listed order
            // and dropping any that no longer resolve.
            let fetched = await withTaskGroup(of: (Int, VeniceCharacter?).self) { group in
                for (index, entry) in Self.curated.enumerated() {
                    group.addTask { (index, try? await api.character(slug: entry.slug)) }
                }
                var collected: [(Int, VeniceCharacter?)] = []
                for await result in group { collected.append(result) }
                return collected.sorted { $0.0 < $1.0 }.compactMap(\.1)
            }
            guard !Task.isCancelled else { return }
            self?.cacheNames(fetched)
            self?.characters = fetched
            self?.isLoading = false
        }
    }

    /// Curated defaults grouped by category, in `categoryOrder`.
    var defaultGroups: [(category: String, characters: [VeniceCharacter])] {
        Self.categoryOrder.compactMap { category in
            let items = characters.filter { Self.categoryBySlug[$0.slug] == category }
            return items.isEmpty ? nil : (category, items)
        }
    }

    /// Updates the search query and (debounced) fetches matching characters.
    /// Empty query restores the curated default list.
    func setSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query else { return }
        query = trimmed
        searchTask?.cancel()

        guard !trimmed.isEmpty else {
            isSearching = false
            searchResults = []
            return
        }
        guard let api = VeniceAPI.fromKeychain() else { return }

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
            var results = (try? await api.listCharacters(search: trimmed, limit: 40)) ?? []
            if Task.isCancelled { return }
            // Fall back to an exact slug lookup so users can pull any character by ID.
            if results.isEmpty, trimmed.rangeOfCharacter(from: .whitespaces) == nil,
               let exact = try? await api.character(slug: trimmed) {
                results = [exact]
            }
            guard !Task.isCancelled, self?.query == trimmed else { return }
            self?.cacheNames(results)
            self?.searchResults = results
            self?.isSearching = false
        }
    }

    func name(forSlug slug: String) -> String? {
        nameCache[slug]
    }

    /// Resolves a selected slug's display name if it isn't cached yet.
    func ensureName(forSlug slug: String) {
        guard nameCache[slug] == nil, let api = VeniceAPI.fromKeychain() else { return }
        Task { [weak self] in
            guard let character = try? await api.character(slug: slug) else { return }
            self?.cacheNames([character])
        }
    }

    private func cacheNames(_ characters: [VeniceCharacter]) {
        for c in characters { nameCache[c.slug] = c.name }
    }
}
