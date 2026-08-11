import Foundation

/// Surfaces Venice's own model-deprecation response headers (harness rule 34) so
/// the agent and user learn a model is sunsetting before it stops working. The
/// header NAMES are Venice's own (the harness reads these exact ones, so they're
/// proven — unlike the generic `Deprecation`/`Sunset` headers PLAN.md 5.6 dropped
/// as unverified).
///
/// Dedupes per (model, sunset-date) so a long run doesn't repeat the same notice
/// on every poll, and broadcasts via `NotificationCenter` — the transport layer
/// has no handle on the agent session, so an app-layer observer turns the
/// broadcast into a `postSystemNotice`.
final class DeprecationMonitor: @unchecked Sendable {
    static let shared = DeprecationMonitor()

    /// Posted when a not-yet-seen deprecation warning arrives. `userInfo` carries
    /// `model`, `warning`, and (when present) `sunset`.
    static let didDetect = Notification.Name("VeniceModelDeprecationDetected")

    static let warningHeader = "x-venice-model-deprecation-warning"
    static let sunsetHeader = "x-venice-model-sunset-date"

    private let lock = NSLock()
    private var seen = Set<String>()

    /// Read the two Venice headers out of a response's header dictionary.
    static func parse(headers: [AnyHashable: Any]) -> (warning: String?, sunset: String?) {
        func value(_ name: String) -> String? {
            for (key, val) in headers where (key as? String)?.lowercased() == name {
                let s = (val as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (s?.isEmpty == false) ? s : nil
            }
            return nil
        }
        return (value(warningHeader), value(sunsetHeader))
    }

    /// True the FIRST time a given (model, sunset) pair is seen; false thereafter.
    /// Pure-ish (mutates the seen set) so the dedupe can be unit-tested.
    func shouldNotify(model: String, sunset: String?) -> Bool {
        let key = "\(model)|\(sunset ?? "")"
        lock.lock(); defer { lock.unlock() }
        return seen.insert(key).inserted
    }

    /// Inspect a response's headers and broadcast once if a deprecation warning is
    /// present and not already surfaced for this (model, date).
    func inspect(model: String, headers: [AnyHashable: Any]) {
        let (warning, sunset) = Self.parse(headers: headers)
        guard warning != nil || sunset != nil else { return }
        guard shouldNotify(model: model, sunset: sunset) else { return }
        var info: [String: String] = ["model": model]
        if let warning { info["warning"] = warning }
        if let sunset { info["sunset"] = sunset }
        NotificationCenter.default.post(name: Self.didDetect, object: nil, userInfo: info)
    }

    /// A user-facing one-liner from the broadcast payload.
    static func message(model: String, warning: String?, sunset: String?) -> String {
        let base = warning ?? "\(model) is deprecated on Venice"
        if let sunset, !base.localizedCaseInsensitiveContains(sunset) {
            return "\(base) (sunset: \(sunset))"
        }
        return base
    }

    /// Test seam: forget everything surfaced so far.
    func resetForTesting() {
        lock.lock(); seen.removeAll(); lock.unlock()
    }
}
