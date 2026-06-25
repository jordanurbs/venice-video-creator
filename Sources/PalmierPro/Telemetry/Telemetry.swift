import Foundation

/// Telemetry / crash reporting has been removed from this build.
///
/// The original app reported crashes and traces to Sentry. This open-source,
/// local, BYO-key build sends nothing off the device: every method here is a
/// no-op. The API surface is preserved so the rest of the code compiles.
enum TelemetryLevel {
    case info, warning, error, fatal
}

enum Telemetry {
    typealias Payload = [String: Any]

    /// Always off — nothing is collected or transmitted.
    static var isEnabled: Bool {
        get { false }
        set { _ = newValue }
    }
    static let enabledForCurrentLaunch: Bool = false

    static func start() {}

    static func breadcrumb(
        _ message: String,
        category: String = "app",
        level: TelemetryLevel = .info,
        data: Payload? = nil
    ) {}

    static func shortId(_ id: String) -> String { String(id.prefix(8)) }

    static func setExtra(value: Any?, key: String) {}

    static func captureMessage(_ message: String, level: TelemetryLevel = .warning) {}

    static func captureError(_ error: Error) {}

    static func logWarning(_ message: String, category: String, data: Payload? = nil) {}

    static func logError(_ message: String, category: String, data: Payload? = nil) {}

    static func logFault(_ message: String, category: String, data: Payload? = nil) {}

    static func trace<T>(name: String, operation: String = "task", _ work: () throws -> T) rethrows -> T {
        try work()
    }

    static func trace<T>(name: String, operation: String = "task", _ work: () async throws -> T) async rethrows -> T {
        try await work()
    }
}
