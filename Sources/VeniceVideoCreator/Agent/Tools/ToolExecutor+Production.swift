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

        // Money gate: refuse prompts that would render static footage (the
        // 2026-08-07 run generated 15s no-motion takes from storyboard-style
        // prompts). Override with allowThinPrompts=true only after the user
        // explicitly accepts the prompts as-is.
        if args.bool("allowThinPrompts") != true {
            let targetsForCheck = shotIds.isEmpty
                ? plan.shots.filter { $0.status != .placed }
                : plan.shots.filter { shotIds.contains($0.id) }
            let issues = targetsForCheck.compactMap { shot -> String? in
                guard let issue = Self.videoPromptIssue(shot, defaultModel: plan.defaultModel) else { return nil }
                return "\(shot.slug ?? String(shot.id.prefix(6))): \(issue)"
            }
            if !issues.isEmpty {
                throw ToolError(
                    "Refusing to spend credits on \(issues.count) shot(s) whose prompts would render static or undirected footage:\n"
                    + issues.joined(separator: "\n")
                    + "\nRewrite each as a VIDEO prompt — camera + framing, what moves, how it differs from adjacent shots — via update_shots, then re-run. "
                    + "(Storyboard prompts describe a frozen frame; video prompts direct motion.) "
                    + "If the user explicitly wants these prompts as-is, pass allowThinPrompts=true."
                )
            }
        }

        // Report exactly which shots this run covers so the agent doesn't
        // misdescribe it (placed shots are NEVER re-produced when shotIds is
        // omitted — an agent seeing 12 planned shots must not say "all 12").
        let targets = shotIds.isEmpty
            ? plan.shots.filter { $0.status != .placed }
            : plan.shots.filter { shotIds.contains($0.id) }

        // QA awareness (harness rule 46 / Phase 4.1): character-bearing shots
        // whose storyboard panel was never QA'd — or whose QA ERRORED (UNCHECKED,
        // rule 46b) — are the ones most likely to carry a wrong face into paid
        // video. Warn loudly and set autoQA so the produce loop vets each take.
        // Not a hard refusal (the user may have reviewed panels by eye); the
        // agent should qa_shot / fix_panel the flagged panels first.
        let qaCandidates = targets.filter { !$0.characterIds.isEmpty && $0.storyboardAssetId != nil }
        let neverQAd = qaCandidates.filter { ($0.qaSummary ?? "").isEmpty }
        let erroredQA = qaCandidates.filter { ($0.qaSummary ?? "").localizedCaseInsensitiveContains("UNCHECKED") }
        let qaWarning: String? = (neverQAd.isEmpty && erroredQA.isEmpty) ? nil : {
            var parts: [String] = []
            if !neverQAd.isEmpty {
                parts.append("never QA'd: \(neverQAd.map { $0.slug ?? String($0.id.prefix(6)) }.joined(separator: ", "))")
            }
            if !erroredQA.isEmpty {
                parts.append("QA errored/UNCHECKED: \(erroredQA.map { $0.slug ?? String($0.id.prefix(6)) }.joined(separator: ", "))")
            }
            return "Character-bearing panels not vetted (\(parts.joined(separator: "; "))). "
                + "A panel with a wrong face propagates into the paid video. Run qa_shot on each (fix_panel if it fails) before producing, or rely on autoQA (auto-enabled for this run) to reject bad takes."
        }()

        var options = ProductionOrchestrator.Options()
        options.videoBudget = try Self.videoBudget(args)
        // Default autoQA ON when panels are unvetted so the produce loop rejects
        // and retakes a bad shot instead of silently placing it; the agent can
        // still pass autoQA explicitly to override.
        options.autoQA = args.bool("autoQA") ?? (qaWarning != nil)
        if let retries = args.int("maxRetries") { options.maxRetries = max(0, min(5, retries)) }

        // Queues behind an active run rather than refusing; duplicates coalesce.
        let queued = editor.productionOrchestrator.isRunning
        guard editor.productionOrchestrator.produceShots(ids: shotIds, options: options) else {
            throw ToolError(editor.productionOrchestrator.lastError ?? "No shots were queued.")
        }
        let skippedPlaced = shotIds.isEmpty ? plan.shots.count - targets.count : 0
        var body: [String: Any] = [
            "started": true,
            "queued": queued,
            "shotCount": targets.count,
            "shots": targets.map { $0.slug ?? $0.id },
            "autoQA": options.autoQA,
            "hint": queued
                ? "A run was already active — these shots were queued behind it and generate after the in-flight shot. Poll production_status (queuedCount) / get_shot_plan."
                : "Production runs in the background. Progress posts into chat; poll get_shot_plan for per-shot status (generating → placed/failed) or production_status for run counters.",
        ]
        if skippedPlaced > 0 {
            body["skippedAlreadyPlaced"] = skippedPlaced
            body["hint"] = (body["hint"] as? String ?? "") + " \(skippedPlaced) already-placed shot(s) were skipped and will NOT be regenerated — describe this run to the user as producing only the remaining shots."
        }
        if let qaWarning {
            body["qaWarning"] = qaWarning
            body["hint"] = "⚠️ " + qaWarning + " " + (body["hint"] as? String ?? "")
        }
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
        let videoBudget = try Self.videoBudget(args)
        try VideoGenerationBudget.requireIfNeeded(
            model: args.string("model") ?? plan.shot(id: shotId)?.modelOverride ?? plan.defaultModel ?? "",
            resolution: plan.resolution, budget: videoBudget
        )
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
        options.videoBudget = videoBudget
        let queued = editor.productionOrchestrator.isRunning
        guard editor.productionOrchestrator.produceShots(ids: [shotId], options: options) else {
            throw ToolError(editor.productionOrchestrator.lastError ?? "No shot was queued.")
        }

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

    func resumeProduction(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let operationId = try args.requireString("operationId")
        let reason = args["approvalReason"] == nil ? nil : try args.requireString("approvalReason")
        let started = try editor.productionOrchestrator.resumeProduction(operationId: operationId, approvalReason: reason)
        return .ok(Self.jsonString(["operationId": operationId, "started": started, "hint": "Poll production_status for validation, review, and placement. No video generation is submitted."] as [String: Any]) ?? "{}")
    }

    func productionStatus(_ editor: EditorViewModel) -> ToolResult {
        let o = editor.productionOrchestrator
        var status = ProductionStatus(
            isRunning: o.isRunning, isPaused: o.isPaused, currentShotId: o.currentShotId,
            succeededCount: o.completedCount, failedCount: o.failedCount,
            cancelledCount: o.cancelledCount, totalCount: o.totalCount,
            queuedUnits: o.pendingQueue, generatingShotIds: o.generatingShotIds.sorted(),
            runningUSD: o.runningUSD, lastError: o.lastError
        )
        status.operationCount = editor.mediaManifest.productionOperations.count
        status.operations = editor.mediaManifest.productionOperations.suffix(50).map(ProductionStatus.OperationSummary.init)
        do {
            let data = try JSONEncoder().encode(status)
            return .ok(String(decoding: data, as: UTF8.self))
        } catch {
            return .error("Production status could not be encoded: \(error.localizedDescription)")
        }
    }
}
