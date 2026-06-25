import Foundation

extension VeniceAPI {
    /// Venice `/image/styles` — list of style preset names for `style_preset`.
    func imageStyles() async throws -> [String] {
        let obj = try await getJSON(path: "image/styles")
        // The endpoint returns either `{ data: ["Name", ...] }` or
        // `{ styles: [{ name: "..." }, ...] }` depending on version — handle both.
        if let names = obj["data"] as? [String] { return names }
        if let names = obj["styles"] as? [String] { return names }
        if let objs = obj["styles"] as? [[String: Any]] {
            return objs.compactMap { $0["name"] as? String }
        }
        if let objs = obj["data"] as? [[String: Any]] {
            return objs.compactMap { $0["name"] as? String }
        }
        return []
    }
}

/// Caches the Venice image style preset list (small + stable) for the picker.
@Observable
@MainActor
final class ImageStyleCatalog {
    static let shared = ImageStyleCatalog()

    private(set) var styles: [String] = []
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var didConfigure = false

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
        loadTask?.cancel()
        guard let api = VeniceAPI.fromKeychain() else {
            styles = []
            return
        }
        loadTask = Task { [weak self] in
            let loaded = (try? await api.imageStyles()) ?? []
            guard !Task.isCancelled else { return }
            self?.styles = loaded
        }
    }
}
