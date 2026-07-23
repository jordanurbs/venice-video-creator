import Foundation

extension ToolExecutor {
    // MARK: - produce_shots

    /// Kicks off background production of shots (route → quote → generate → optional QA →
    /// place on the timeline). Returns immediately; progress posts into chat and shot statuses
    /// flip in get_shot_plan. Poll get_shot_plan / production_status to track it.
    func produceShots(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let plan = editor.shotPlan, !plan.shots.isEmpty else {
            throw ToolError("No shots to produce. Create a plan with save_shot_plan first.")
        }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Production requires a Venice API key. Tell the user to add it in Settings.")
        }

        let shotIds = args.stringArray("shotIds")
        for id in shotIds where plan.shot(id: id) == nil {
            throw ToolError("Shot not found: \(id)")
        }
        var options = ProductionOrchestrator.Options()
        options.autoQA = args.bool("autoQA") ?? false
        if let retries = args.int("maxRetries") { options.maxRetries = max(0, min(5, retries)) }

        // Queues behind an active run rather than refusing; duplicates coalesce.
        let queued = editor.productionOrchestrator.isRunning
        editor.productionOrchestrator.produceShots(ids: shotIds, options: options)

        let count = shotIds.isEmpty ? plan.shots.filter { $0.status != .placed }.count : shotIds.count
        let body: [String: Any] = [
            "started": true,
            "queued": queued,
            "shotCount": count,
            "autoQA": options.autoQA,
            "hint": queued
                ? "A run was already active — these shots were queued behind it and generate after the in-flight shot. Poll production_status (queuedCount) / get_shot_plan."
                : "Production runs in the background. Progress posts into chat; poll get_shot_plan for per-shot status (generating → placed/failed) or production_status for run counters.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - regenerate_shot

    /// Regenerates a single shot as a new take and replaces its timeline clip in place.
    /// Optionally overrides the prompt or model first. Runs through the orchestrator; if a
    /// run is already active the shot queues behind it.
    func regenerateShot(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        let shotId = try args.requireString("shotId")
        guard plan.shot(id: shotId) != nil else { throw ToolError("Shot not found: \(shotId)") }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Regeneration requires a Venice API key. Tell the user to add it in Settings.")
        }

        // Apply optional overrides before the run so routing/prompt use them.
        let newPrompt = args.string("prompt")
        let newModel = args.string("model")
        if newPrompt != nil || newModel != nil {
            editor.mutateShotPlan(actionName: "Edit Shot") { plan in
                guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
                if let newPrompt { plan.shots[idx].prompt = newPrompt }
                if let newModel { plan.shots[idx].modelOverride = newModel }
            }
        }

        var options = ProductionOrchestrator.Options()
        options.autoQA = args.bool("autoQA") ?? false
        let queued = editor.productionOrchestrator.isRunning
        editor.productionOrchestrator.produceShots(ids: [shotId], options: options)

        let body: [String: Any] = [
            "started": true,
            "queued": queued,
            "shotId": shotId,
            "hint": queued
                ? "A run was active — this shot was queued behind it and regenerates after the in-flight shot. It replaces the shot's timeline clip in place when done. Poll get_shot_plan / production_status."
                : "New take generating. It replaces the shot's timeline clip in place when done; earlier takes are kept in the shot's take history. Poll get_shot_plan.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - production_status

    func productionStatus(_ editor: EditorViewModel) -> ToolResult {
        let o = editor.productionOrchestrator
        let body: [String: Any] = [
            "isRunning": o.isRunning,
            "isPaused": o.isPaused,
            "currentShotId": o.currentShotId as Any,
            "completedCount": o.completedCount,
            "totalCount": o.totalCount,
            "queuedCount": o.pendingQueue.count,
            "queuedShotIds": o.pendingQueue,
            "runningUSD": o.runningUSD,
            "lastError": o.lastError as Any,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }
}
