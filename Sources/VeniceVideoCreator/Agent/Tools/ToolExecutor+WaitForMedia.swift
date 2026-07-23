import Foundation

extension ToolExecutor {
    // MARK: - wait_for_media

    /// Suspends until every requested asset settles (file on disk, failed, or
    /// cancelled) or the timeout elapses. The chat turn stays alive, so the
    /// agent can truthfully report results instead of promising to "check later".
    func waitForMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        let refs = args.stringArray("mediaRefs")
        guard !refs.isEmpty else { throw ToolError("wait_for_media requires at least one mediaRef.") }
        for ref in refs {
            _ = try asset(ref, editor: editor, label: "Asset to wait for")
        }

        let timeout = Double(clampInt(Double(args.int("timeoutSeconds") ?? 120), min: 5, max: 300))
        let deadline = ContinuousClock.now + .seconds(timeout)

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if refs.allSatisfy({ Self.isSettled($0, editor: editor) }) { break }
            try await Task.sleep(for: .seconds(1))
        }

        var statuses: [[String: Any]] = []
        var pendingCount = 0
        for ref in refs {
            guard let a = editor.mediaAssets.first(where: { $0.id == ref }) else {
                statuses.append(["mediaRef": ref, "status": "deleted"])
                continue
            }
            var entry: [String: Any] = ["mediaRef": ref, "name": a.name]
            switch a.generationStatus {
            case .none:
                entry["status"] = Self.isReady(a, editor: editor) ? "ready" : "missing_file"
            case .failed(let msg):
                entry["status"] = "failed"
                entry["error"] = msg
            case .cancelled:
                entry["status"] = "cancelled"
            default:
                entry["status"] = "pending"
                pendingCount += 1
            }
            statuses.append(entry)
        }

        var body: [String: Any] = ["assets": statuses]
        if pendingCount > 0 {
            body["hint"] = "\(pendingCount) asset(s) still in flight after \(Int(timeout))s. Call wait_for_media again to keep waiting, or report progress to the user."
        } else {
            body["hint"] = "All assets settled. inspect_media to review, or continue the workflow."
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    /// An asset is settled once it is no longer in an in-flight generation state
    /// (deleted assets count as settled so a wait can't hang on them).
    private static func isSettled(_ id: String, editor: EditorViewModel) -> Bool {
        guard let a = editor.mediaAssets.first(where: { $0.id == id }) else { return true }
        switch a.generationStatus {
        case .preparing, .generating, .downloading, .rendering: return false
        case .none, .failed, .cancelled: return true
        }
    }
}
