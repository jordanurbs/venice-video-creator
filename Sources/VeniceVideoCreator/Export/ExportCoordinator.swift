import Foundation

@MainActor
enum ExportCoordinator {
    private static var exportActive = false
    /// Suspended `waitWhileExportActive` callers, resumed the instant export ends.
    private static var idleWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    static var isExportActive: Bool { exportActive }

    static func beginExportIfIdle() -> Bool {
        guard !exportActive else { return false }
        exportActive = true
        return true
    }

    static func acquireExport() async throws {
        while exportActive {
            try await Task.sleep(for: .milliseconds(50))
        }
        exportActive = true
    }

    static func endExport() {
        exportActive = false
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for (_, continuation) in waiters { continuation.resume() }
    }

    /// Suspends until no export is active. Wakes immediately when `endExport()`
    /// runs (every export path defers it), so there's no polling latency.
    static func waitWhileExportActive() async throws {
        guard exportActive else { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Runs synchronously on the MainActor before any suspension, so this
                // recheck-or-store is race-free against endExport().
                if exportActive {
                    idleWaiters[id] = continuation
                } else {
                    continuation.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in
                idleWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }
}
