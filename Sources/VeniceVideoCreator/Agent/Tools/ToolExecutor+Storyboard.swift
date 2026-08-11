import Foundation

extension ToolExecutor {
    // MARK: - storyboard_shots

    /// Generates a storyboard panel per shot via the image path. When a shot references
    /// characters with ready reference images, those are passed as image references so the
    /// panel keeps the character's likeness (reference-augmented). Panels are linked to their
    /// shot (`storyboardAssetId`) and the shot flips to `storyboarded`. Async — poll get_media.
    func storyboardShots(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let plan = editor.shotPlan else {
            throw ToolError("No shot plan yet. Call save_shot_plan first.")
        }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Storyboarding requires a Venice API key. Tell the user to add it in Settings.")
        }
        guard let model = try resolveImageModelForStoryboard(args, editor: editor) else {
            throw ToolError("Image model catalog not loaded yet. Try again in a moment.")
        }

        // Target shots: explicit ids, else every shot without a storyboard yet.
        let requestedIds = args.stringArray("shotIds")
        let targets: [Shot]
        if requestedIds.isEmpty {
            targets = plan.shots.filter { $0.storyboardAssetId == nil }
        } else {
            targets = try requestedIds.map { id in
                guard let shot = plan.shot(id: id) else { throw ToolError("Shot not found: \(id)") }
                return shot
            }
        }
        guard !targets.isEmpty else {
            return .ok(#"{"storyboarded": [], "hint": "Every shot already has a storyboard. Pass shotIds to regenerate specific panels."}"#)
        }

        let aspectRatio = args.string("aspectRatio") ?? plan.aspectRatio
        // Panels are tier-2 references the video anchors on — generate them at a
        // real resolution/quality, not the cheapest tier (harness quality floor).
        let resolution = args.string("resolution") ?? Self.referenceResolution(model)
        let quality = args.string("quality") ?? Self.referenceQuality(model)
        let useRefs = (args.bool("useCharacterRefs") ?? true) && model.supportsImageReference
        let folderArg = args.string("folderId")

        // HARD GATE: a character-bearing shot must not storyboard without its
        // characters' reference images READY — a panel without likeness refs
        // draws a stranger, and everything downstream (video generation
        // anchors on the panel) inherits the wrong face. Fail fast BEFORE
        // paying for any panel, naming what's missing.
        if useRefs {
            var notReady: [String] = []   // "Bruno (S3, S4)" style
            var missing: Set<String> = []
            for shot in targets {
                for cid in shot.characterIds {
                    guard let c = plan.character(id: cid) else { continue }
                    let anyReady = c.activeReferenceAssetIds.contains { aid in
                        guard let a = editor.mediaAssets.first(where: { $0.id == aid }) else { return false }
                        return a.type == .image && Self.isReady(a, editor: editor)
                    }
                    if !anyReady, !missing.contains(cid) {
                        missing.insert(cid)
                        notReady.append(c.referenceImageAssetIds.isEmpty
                            ? "\(c.name) — no reference images at all (create them first)"
                            : "\(c.name) — references not finished (wait_for_media on them)")
                    }
                }
            }
            if !notReady.isEmpty {
                throw ToolError(
                    "Storyboarding blocked: character reference images are not ready, so panels would be drawn WITHOUT the cast's likeness. Fix first: \(notReady.joined(separator: "; ")). "
                    + "Generate references (create_character / update_character), wait_for_media on them, have the user confirm the locked look, THEN storyboard. "
                    + "To deliberately storyboard without character likeness, pass useCharacterRefs=false."
                )
            }
        }

        var results: [[String: Any]] = []
        for shot in targets {
            let basePrompt = shot.prompt.isEmpty ? shot.summary : shot.prompt
            guard !basePrompt.isEmpty else {
                throw ToolError("Shot \(shot.slug ?? shot.id) has no prompt or summary to storyboard.")
            }

            // A ready panel from the nearest prior shot sharing this location:
            // its lighting/layout is the one this panel must match (anti-pattern 7).
            // Only used when references are on (we pass the panel as an extra ref).
            let priorPanel = useRefs ? priorSameLocationPanel(for: shot, plan: plan, editor: editor) : nil
            let panelPrompt = ShotPromptBuilder.storyboardPanelPrompt(
                for: shot, plan: plan, matchPreviousPanel: priorPanel != nil
            )

            // Gather ready reference images in likeness-protecting order
            // (harness reference-slots policy): character refs FIRST, then the
            // location, then the prior same-location panel LAST — so when the
            // budget is exceeded the lighting anchor drops before any character's
            // likeness (two characters + a location no longer silently evict a
            // face). Cap = the panel reference budget (Venice /image/multi-edit
            // tops out at 3 images). Dropped refs are reported in the result.
            var refs: [MediaAsset] = []
            var droppedRefs: [String] = []
            if useRefs {
                let budget = Self.panelReferenceBudget(model)
                var ordered: [(asset: MediaAsset, label: String)] = []
                var seen = Set<String>()
                func addReady(_ assetIds: [String], label: (MediaAsset) -> String) {
                    for aid in assetIds where !seen.contains(aid) {
                        guard aid != priorPanel?.id,
                              let a = editor.mediaAssets.first(where: { $0.id == aid }),
                              a.type == .image, Self.isReady(a, editor: editor) else { continue }
                        seen.insert(aid)
                        ordered.append((a, label(a)))
                    }
                }
                for cid in shot.characterIds {
                    guard let c = plan.character(id: cid) else { continue }
                    addReady(c.activeReferenceAssetIds) { _ in c.name.isEmpty ? "character" : c.name }
                }
                for lid in shot.locationIds {
                    guard let l = plan.location(id: lid) else { continue }
                    addReady(l.activeReferenceAssetIds) { _ in "location \(l.name)" }
                }
                if let priorPanel { ordered.append((priorPanel, "prior-panel lighting anchor")) }
                for entry in ordered {
                    if refs.count >= budget { droppedRefs.append(entry.label); continue }
                    refs.append(entry.asset)
                }
            }

            if let err = model.validate(
                aspectRatio: aspectRatio, resolution: resolution, quality: quality,
                imageRefCount: refs.count, numImages: 1
            ) {
                throw ToolError("Shot \(shot.slug ?? shot.id): \(err)")
            }

            var genInput = GenerationInput(
                prompt: panelPrompt, model: model.id, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality
            )
            genInput.hasFace = !refs.isEmpty
            Self.applyReferenceSeed(&genInput, model: model, plan: plan)
            let folderId = folderArg ?? refs.last?.folderId
            let placeholderId = ImageGenerationSubmission.make(
                genInput: genInput, model: model, references: refs,
                name: "Panel · \(shot.slug ?? shot.summary.prefix(20).description)", folderId: folderId
            ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)

            editor.mutateShotPlan(actionName: "Storyboard Shot") { plan in
                guard let idx = plan.shots.firstIndex(where: { $0.id == shot.id }) else { return }
                plan.shots[idx].storyboardAssetId = placeholderId
                if plan.shots[idx].status == .planned {
                    plan.shots[idx].status = .storyboarded
                }
            }

            var row: [String: Any] = [
                "shotId": shot.id,
                "slug": shot.slug ?? shot.id,
                "storyboardAssetId": placeholderId,
                "referencesUsed": refs.count,
            ]
            if !droppedRefs.isEmpty { row["referencesDropped"] = droppedRefs }
            results.append(row)
        }

        // Surface the run where it lives: the Production tab, panels per shot.
        editor.mediaPanelVisible = true
        editor.showMediaPanelProductionTab()

        let body: [String: Any] = [
            "model": model.id,
            "storyboarded": results,
            "hint": "Panels are generating. Call wait_for_media with the storyboardAssetIds, then inspect_media to review, then qa_shot / fix_panel or start production.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - Helpers

    /// The ready storyboard panel of the nearest earlier shot (in plan order) that
    /// shares a location with `shot`. Used to style-match consecutive same-location
    /// panels for lighting consistency (harness anti-pattern 7). Returns nil when no
    /// prior same-location shot has a finished panel yet — panels generate async, so
    /// within one batch earlier panels aren't ready and matching starts on reruns.
    func priorSameLocationPanel(
        for shot: Shot, plan: ShotPlan, editor: EditorViewModel
    ) -> MediaAsset? {
        guard let idx = plan.shots.firstIndex(where: { $0.id == shot.id }), idx > 0 else { return nil }
        let locs = Set(shot.locationIds)
        guard !locs.isEmpty else { return nil }
        for prior in plan.shots[..<idx].reversed() {
            guard !locs.isDisjoint(with: prior.locationIds) else { continue }
            guard let panelId = prior.storyboardAssetId,
                  let asset = editor.mediaAssets.first(where: { $0.id == panelId }),
                  asset.type == .image, Self.isReady(asset, editor: editor) else { continue }
            return asset
        }
        return nil
    }

    /// A generated asset is usable as a reference only once its file is on disk.
    static func isReady(_ asset: MediaAsset, editor: EditorViewModel) -> Bool {
        guard asset.generationStatus == .none else { return false }
        guard let url = editor.mediaResolver.resolveURL(for: asset.id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Panels are generated via `/image/multi-edit` when they carry references,
    /// which Venice caps at 3 images total — the effective per-panel reference
    /// budget. Kept as a helper so it tracks any future per-model exposure of a
    /// higher limit (there is none today).
    static func panelReferenceBudget(_ model: ImageModelConfig) -> Int {
        model.supportsImageReference ? 3 : 0
    }

    /// Resolution order for the storyboard image model (harness bakeoff parity):
    /// explicit model arg → the plan's bakeoff-locked `referenceImageModel` (the
    /// whole point of the bakeoff — ignoring it here defeated it) → the
    /// high-fidelity storyboard defaults (nano-banana-2 / nano-banana-pro) when
    /// enabled → first enabled model that supports image references → first
    /// enabled model.
    private func resolveImageModelForStoryboard(_ args: [String: Any], editor: EditorViewModel) throws -> ImageModelConfig? {
        if let id = args.string("model") {
            guard let model = ImageModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown image model '\(id)'.")
            }
            guard ModelPreferences.shared.isEnabled(id) else {
                throw ToolError("Image model '\(id)' is turned off in Settings → Models.")
            }
            return model
        }
        func enabledModel(_ id: String) -> ImageModelConfig? {
            ImageModelConfig.allModels.first { $0.id == id && ModelPreferences.shared.isEnabled($0.id) }
        }
        // The bakeoff winner locks the look for EVERY reference; panels must use
        // it too so they match the character/location sheets they anchor.
        if let locked = editor.shotPlan?.referenceImageModel, let model = enabledModel(locked) {
            return model
        }
        // High-fidelity storyboard defaults before "first enabled" (which could
        // be an arbitrary low-quality model).
        if let preferred = enabledModel("nano-banana-2") ?? enabledModel("nano-banana-pro") {
            return preferred
        }
        // Prefer an enabled model that supports image references (for character consistency).
        return ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) && $0.supportsImageReference }
            ?? ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) }
    }
}
