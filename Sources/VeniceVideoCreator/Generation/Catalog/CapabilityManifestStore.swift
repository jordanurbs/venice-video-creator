import Foundation
import Synchronization

/// Thread-safe snapshot of the active manifest, readable from any isolation
/// context (the catalog mapper parses off the main actor). Written only by
/// `CapabilityManifestStore`.
enum CapabilityManifestSnapshot {
    private static let storage = Mutex<CapabilityManifest?>(nil)

    static var current: CapabilityManifest? {
        storage.withLock { $0 }
    }

    static func set(_ manifest: CapabilityManifest?) {
        storage.withLock { $0 = manifest }
    }
}

/// Loads, caches, and (optionally) refreshes the harness capability manifest.
///
/// Resolution order, safest wins:
/// 1. A remotely fetched manifest cached in Application Support — only used
///    when the user has "Update model capabilities automatically" on
///    (Settings → Models) AND the cached copy decodes at a supported
///    schemaVersion.
/// 2. The bundled snapshot (`Resources/Capabilities/capabilities.json`),
///    committed from the harness at build time.
/// 3. `nil` — callers (VideoModelCapabilities) fall back to their
///    family-substring allowlists, then conservative off.
///
/// The remote fetch happens at most once per launch, in the background, off
/// the model-catalog path: a fresh manifest applies on the NEXT catalog
/// reload/launch rather than racing the current one. Failures are logged and
/// ignored — the app never degrades below its bundled snapshot.
@Observable
@MainActor
final class CapabilityManifestStore {
    static let shared = CapabilityManifestStore()

    /// UserDefaults key for the Settings → Models toggle.
    static let autoUpdateKey = "capabilityManifestAutoUpdate"

    /// Raw GitHub URL of the snapshot the harness commits on every release.
    /// Data-only JSON; served over HTTPS; schema-gated on decode.
    static let remoteURL = URL(string: "https://raw.githubusercontent.com/jordanurbs/venice-video-harness/main/capabilities.json")!

    /// The active manifest (remote-cached if allowed and valid, else bundled).
    private(set) var manifest: CapabilityManifest?
    /// Where the active manifest came from, for the Settings UI.
    private(set) var source: Source = .none

    enum Source: Equatable {
        case none
        case bundled(harnessVersion: String)
        case remote(harnessVersion: String, fetchedAt: Date)

        var label: String {
            switch self {
            case .none: "unavailable"
            case .bundled(let v): "bundled (harness \(v))"
            case .remote(let v, _): "auto-updated (harness \(v))"
            }
        }
    }

    /// Settings → Models toggle. Off by default (no network calls without opt-in).
    var autoUpdateEnabled: Bool {
        didSet {
            guard autoUpdateEnabled != oldValue else { return }
            UserDefaults.standard.set(autoUpdateEnabled, forKey: Self.autoUpdateKey)
            if autoUpdateEnabled { refreshRemote() } else { load() }
        }
    }

    @ObservationIgnored private var didConfigure = false
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    private init() {
        autoUpdateEnabled = UserDefaults.standard.object(forKey: Self.autoUpdateKey) as? Bool ?? false
    }

    /// Called once at app startup (before the model catalog builds): loads the
    /// best available manifest synchronously from disk, then kicks off the
    /// background refresh when the toggle is on.
    func configure() {
        guard !didConfigure else { return }
        didConfigure = true
        load()
        if autoUpdateEnabled { refreshRemote() }
    }

    // MARK: - Load (disk only, synchronous, cheap)

    private func load() {
        if autoUpdateEnabled,
           let cached = Self.decode(at: Self.cacheURL),
           let fetchedAt = Self.cacheModificationDate() {
            apply(cached, source: .remote(harnessVersion: cached.harnessVersion, fetchedAt: fetchedAt))
            Log.generation.notice("capability manifest: using cached remote (harness \(cached.harnessVersion), \(cached.videoModels.count) models)")
            return
        }
        if let bundledURL = Self.bundledURL, let bundled = Self.decode(at: bundledURL) {
            apply(bundled, source: .bundled(harnessVersion: bundled.harnessVersion))
            Log.generation.notice("capability manifest: using bundled snapshot (harness \(bundled.harnessVersion), \(bundled.videoModels.count) models)")
            return
        }
        apply(nil, source: .none)
        Log.generation.warning("capability manifest: none available — falling back to family-substring allowlists")
    }

    private func apply(_ new: CapabilityManifest?, source newSource: Source) {
        manifest = new
        source = newSource
        CapabilityManifestSnapshot.set(new)
    }

    // MARK: - Remote refresh (background, at most once per call site)

    func refreshRemote() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            defer { Task { @MainActor in self?.refreshTask = nil } }
            do {
                var request = URLRequest(url: Self.remoteURL)
                request.timeoutInterval = 15
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                // Decode BEFORE caching: schema gate + shape check. A manifest
                // from a future harness we can't interpret is discarded.
                let decoded = try JSONDecoder().decode(CapabilityManifest.self, from: data)
                let dir = Self.cacheURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: Self.cacheURL, options: .atomic)
                await MainActor.run { [weak self] in
                    guard let self, self.autoUpdateEnabled else { return }
                    self.apply(decoded, source: .remote(harnessVersion: decoded.harnessVersion, fetchedAt: Date()))
                    Log.generation.notice("capability manifest: refreshed from remote (harness \(decoded.harnessVersion))")
                    // Rebuild the catalog so the new capabilities apply now,
                    // not on next launch.
                    ModelCatalog.shared.reload()
                }
            } catch {
                Log.generation.warning("capability manifest refresh failed (keeping current): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Paths

    private static var bundledURL: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("Capabilities/capabilities.json"),
            resourceURL.appendingPathComponent("VeniceVideoCreator_VeniceVideoCreator.bundle/Capabilities/capabilities.json"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    static var cacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("VeniceVideoCreator", isDirectory: true)
            .appendingPathComponent("capabilities.json")
    }

    private static func cacheModificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
    }

    private static func decode(at url: URL) -> CapabilityManifest? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(CapabilityManifest.self, from: data)
        } catch {
            Log.generation.warning("capability manifest at \(url.lastPathComponent) failed to decode: \(error.localizedDescription)")
            return nil
        }
    }
}
