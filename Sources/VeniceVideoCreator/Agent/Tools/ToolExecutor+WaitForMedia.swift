import Foundation

extension ToolExecutor {
    // MARK: - wait_for_media

    /// Suspends until every requested asset settles (file on disk, failed, or
    /// cancelled) or the timeout elapses. The chat turn stays alive, so the
    /// agent can truthfully report results instead of promising to "check later".
    func waitForMedia(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        var refs = args.stringArray("mediaRefs")
        guard !refs.isEmpty else { throw ToolError("wait_for_media requires at least one mediaRef.") }

        let timeout = Double(clampInt(Double(args.int("timeoutSeconds") ?? 120), min: 5, max: 300))
        let deadline = ContinuousClock.now + .seconds(timeout)

        // Two tolerances before declaring an id missing:
        // 1. Prefix resolution — models sometimes pass a truncated id (e.g. the
        //    8-char prefix that appears in generated filenames). A unique
        //    case-insensitive prefix match resolves to the full asset id.
        // 2. Grace window — an id handed out by a generation tool may race its
        //    placeholder registration; poll briefly instead of failing up front.
        func resolve(_ id: String) -> String? {
            if editor.mediaAssets.contains(where: { $0.id == id }) { return id }
            let matches = editor.mediaAssets.filter { $0.id.lowercased().hasPrefix(id.lowercased()) }
            return matches.count == 1 ? matches[0].id : nil
        }
        let graceDeadline = ContinuousClock.now + .seconds(min(10, timeout))
        var unresolved = refs.filter { resolve($0) == nil }
        while !unresolved.isEmpty, ContinuousClock.now < graceDeadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(250))
            unresolved = refs.filter { resolve($0) == nil }
        }
        if !unresolved.isEmpty {
            throw ToolError("Asset to wait for not found: \(unresolved.joined(separator: ", ")). The id may be wrong or truncated — call get_media to list registered assets.")
        }
        refs = refs.compactMap(resolve)

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
