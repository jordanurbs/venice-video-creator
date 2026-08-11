import Foundation

extension ToolExecutor {
    // MARK: - qa_shot

    /// Reviews a shot's storyboard panel and/or generated video against the director's intent
    /// with a vision model, annotates the shot with the verdict, and returns the reviewed
    /// frames so the agent can see what QA saw. Prefers the generated video when available,
    /// otherwise the storyboard panel.
    func qaShot(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        let shotId = try args.requireString("shotId")
        guard let shot = plan.shot(id: shotId) else { throw ToolError("Shot not found: \(shotId)") }
        guard let api = VeniceAPI.fromKeychain() else {
            throw ToolError("QA requires a Venice API key. Tell the user to add it in Settings.")
        }
        guard let model = VisionQA.selectModel() else {
            throw ToolError(VisionQA.QAError.noVisionModel.localizedDescription)
        }

        let frameCount = min(6, max(1, args.int("frameCount") ?? 3))
        var images: [Data] = []
        var reviewed = ""

        if let ref = args.string("mediaRef") {
            let a = try asset(ref, editor: editor, label: "Media to QA")
            images = try await Self.frames(of: a, editor: editor, frameCount: frameCount)
            reviewed = "asset \(a.id)"
        } else if let videoId = shot.videoAssetId,
                  let video = editor.mediaAssets.first(where: { $0.id == videoId }),
                  Self.isReady(video, editor: editor) {
            images = try await Self.frames(of: video, editor: editor, frameCount: frameCount)
            reviewed = "generated video"
        } else if let panelId = shot.storyboardAssetId,
                  let panel = editor.mediaAssets.first(where: { $0.id == panelId }),
                  Self.isReady(panel, editor: editor) {
            images = try await Self.frames(of: panel, editor: editor, frameCount: 1)
            reviewed = "storyboard panel"
        }

        guard !images.isEmpty else {
            throw ToolError("Nothing ready to review for shot \(shot.slug ?? shotId). Storyboard or generate it first, then wait_for_media until the asset finishes.")
        }

        // Spatial drift guard (harness qa-storyboard): append the nearest earlier
        // same-location frame so the reviewer catches mirrored geography/side-swaps
        // against real prior coverage, not the stated layout alone.
        let priorFrame = (try? await priorSameLocationQAFrame(shot, plan: plan, editor: editor)) ?? nil
        if let priorFrame { images.append(priorFrame) }
        let rubric = Self.qaRubric(for: shot, plan: plan, comparePriorPanel: priorFrame != nil)
        // Errored QA is UNCHECKED, never a silent pass (harness rule 46b): a
        // failed vision call stamps the shot UNCHECKED and surfaces as an error,
        // so no auto-approve path reads the missing verdict as "all clear".
        let result: VisionQA.Result
        do {
            result = try await VisionQA.evaluate(images: images, rubric: rubric, api: api, model: model)
        } catch {
            editor.mutateShotPlan(actionName: "QA Shot") { plan in
                guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
                plan.shots[idx].qaSummary = "QA errored: \(error.localizedDescription) — shot is UNCHECKED"
            }
            throw ToolError("QA vision call failed for shot \(shot.slug ?? shotId): \(error.localizedDescription). The shot is marked UNCHECKED (not passing) — retry qa_shot or check the vision model in Settings → Models.")
        }

        // Annotate the shot with the verdict.
        editor.mutateShotPlan(actionName: "QA Shot") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            var summary = result.summary
            if !result.issues.isEmpty {
                summary += " Issues: " + result.issues.joined(separator: "; ")
            }
            plan.shots[idx].qaSummary = summary
            // Stamp the latest take's QA score if we reviewed a generated video.
            if reviewed == "generated video", let last = plan.shots[idx].takes.indices.last {
                plan.shots[idx].takes[last].qaScore = result.score
                plan.shots[idx].takes[last].qaSummary = result.summary
            }
            if result.pass, (args.bool("autoApprove") ?? false) {
                plan.shots[idx].status = .approved
            } else if plan.shots[idx].status == .generating {
                plan.shots[idx].status = .qa
            }
        }

        var body: [String: Any] = [
            "shotId": shotId,
            "reviewed": reviewed,
            "score": result.score,
            "pass": result.pass,
            "issues": result.issues,
            "summary": result.summary,
            "model": model,
        ]
        if result.pass {
            body["hint"] = "Passed QA. Approve with update_shots (status=approved) or proceed."
        } else {
            body["hint"] = "Failed QA. Use fix_panel to correct the storyboard, or regenerate_shot for a new video take."
        }

        var blocks: [ToolResult.Block] = [.text(Self.jsonString(body) ?? "{}")]
        for data in images.prefix(4) {
            blocks.append(.image(base64: data.base64EncodedString(), mediaType: "image/jpeg"))
        }
        return ToolResult(content: blocks, isError: false)
    }

    // MARK: - fix_panel

    /// Multi-edit correction of a shot's storyboard panel. Uses the shot's QA notes as the
    /// default instruction. The corrected panel replaces the shot's storyboard (async).
    func fixPanel(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        let shotId = try args.requireString("shotId")
        guard let shot = plan.shot(id: shotId) else { throw ToolError("Shot not found: \(shotId)") }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Fixing a panel requires a Venice API key. Tell the user to add it in Settings.")
        }
        guard let panelId = shot.storyboardAssetId,
              let panel = editor.mediaAssets.first(where: { $0.id == panelId }) else {
            throw ToolError("Shot \(shot.slug ?? shotId) has no storyboard panel. Run storyboard_shots first.")
        }
        guard panel.type == .image else {
            throw ToolError("The shot's storyboard asset is not an image.")
        }
        guard Self.isReady(panel, editor: editor) else {
            throw ToolError("The storyboard panel is still generating. Call wait_for_media with its id first.")
        }

        let baseInstruction = args.string("instructions")
            ?? shot.qaSummary.map { "Fix these problems while keeping the same shot: \($0)" }
            ?? "Improve overall quality and fix any artifacts or deformities."
        let modelId = args.string("model")

        // Gather the shot's ready character (then location) reference images so
        // multi-edit can correct LIKENESS, not just nudge pixels — a single
        // `/image/edit` has no identity anchor, so a "wrong face" QA failure was
        // uncorrectable (harness item #6 tail). The panel is always image 1; cap
        // the extras at 2 (3 total for /image/multi-edit). Any leftover slot is
        // filled by the prior same-location panel as a lighting anchor.
        var refs: [MediaAsset] = []
        var candidateIds: [String] = []
        for cid in shot.characterIds { candidateIds += plan.character(id: cid)?.activeReferenceAssetIds ?? [] }
        for lid in shot.locationIds { candidateIds += plan.location(id: lid)?.activeReferenceAssetIds ?? [] }
        for aid in candidateIds {
            if refs.count >= 2 { break }
            if aid == panel.id { continue }
            guard !refs.contains(where: { $0.id == aid }) else { continue }
            if let a = editor.mediaAssets.first(where: { $0.id == aid }),
               a.type == .image, Self.isReady(a, editor: editor) {
                refs.append(a)
            }
        }
        if refs.count < 2,
           let priorPanel = priorSameLocationPanel(for: shot, plan: plan, editor: editor),
           priorPanel.id != panel.id,
           !refs.contains(where: { $0.id == priorPanel.id }) {
            refs.append(priorPanel)
        }

        let instruction = Self.fixPanelInstruction(base: baseInstruction, refCount: refs.count)
        let placeholderId: String
        if refs.isEmpty {
            // No likeness/lighting anchor available — single-image edit (unchanged).
            guard let id = EditSubmitter.submitImageEdit(
                asset: panel, prompt: baseInstruction, modelId: modelId, editor: editor
            ) else {
                throw ToolError("Failed to start the panel correction.")
            }
            placeholderId = id
        } else {
            // Panel first, then the anchors — same shape as edit_image's multi-edit
            // branch. Aspect is threaded to ImageMultiEditParams so the returned
            // (often square) multi-edit output is restored to the plan's shape.
            let model = modelId ?? ModelCatalog.shared.editModels.first?.id ?? VeniceBuiltInModel.defaultEdit
            let allRefs = [panel] + refs
            let refAssetIds = allRefs.map(\.id)
            let aspect = plan.aspectRatio
            let genInput = GenerationInput(
                prompt: instruction, model: model, duration: 0, aspectRatio: "", resolution: nil
            )
            placeholderId = editor.generationService.generate(
                genInput: genInput,
                assetType: .image,
                placeholderDuration: Defaults.imageDurationSeconds,
                references: allRefs,
                name: "Fixed · \(shot.slug ?? shot.summary.prefix(20).description)",
                folderId: panel.folderId,
                buildParams: { uploaded in
                    .imageMultiEdit(ImageMultiEditParams(
                        sourceURLs: uploaded,
                        prompt: instruction,
                        aspectRatio: aspect.isEmpty ? nil : aspect
                    ))
                },
                snapshotRefs: { input, uploaded in
                    input.imageURLs = uploaded.isEmpty ? nil : uploaded
                    input.imageURLAssetIds = refAssetIds
                },
                fileExtension: "png",
                projectURL: editor.projectURL,
                editor: editor
            )
        }

        editor.mutateShotPlan(actionName: "Fix Panel") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].storyboardAssetId = placeholderId
            if plan.shots[idx].status == .qa { plan.shots[idx].status = .storyboarded }
        }

        // Multi-edit on a close-up tends to return a re-composed (often square)
        // frame that drifts from the plan's aspect and framing (anti-pattern 6).
        // Warn and point at a clean regeneration for those shots.
        let refNote = refs.isEmpty
            ? "no character references were ready, so this was a single-image edit with no likeness anchor"
            : "corrected against \(refs.count) reference image(s) for likeness"
        let hint: String
        if Self.isLikelyCloseUp(shot) {
            hint = "Correction started (\(refNote)), but this reads as a close-up — multi-edit (fix_panel) often re-crops close framing and can come back square or off-aspect. If the corrected panel drifts, regenerate this shot's panel cleanly with storyboard_shots(shotIds=[\"\(shotId)\"]) instead. wait_for_media on the new storyboardAssetId, then qa_shot again."
        } else {
            hint = "Correction started (\(refNote)). wait_for_media on the new storyboardAssetId, then qa_shot again."
        }
        let body: [String: Any] = [
            "shotId": shotId,
            "storyboardAssetId": placeholderId,
            "instruction": instruction,
            "referencesUsed": refs.count,
            "hint": hint,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    /// Composes the multi-edit correction instruction. When reference images are
    /// attached it names image 1 as the panel to preserve — so the edit corrects
    /// character likeness/setting against the refs instead of recomposing the frame.
    nonisolated static func fixPanelInstruction(base: String, refCount: Int) -> String {
        guard refCount > 0 else { return base }
        let refList = refCount == 1 ? "image 2" : "images 2–\(refCount + 1)"
        return "Keep the composition, framing and aspect ratio of image 1 (the storyboard panel). "
            + "Correct the character(s) and setting to exactly match their reference images (\(refList)). "
            + base
    }

    /// Heuristic close-up detector for the fix_panel warning (harness anti-pattern
    /// 6): scans the shot's authored text for close-framing language.
    nonisolated static func isLikelyCloseUp(_ shot: Shot) -> Bool {
        let haystack = "\(shot.prompt) \(shot.summary) \(shot.blocking ?? "")".lowercased()
        let cues = ["close-up", "close up", "closeup", "extreme close", "ecu ", "macro", "tight on", "tight shot", "detail shot"]
        return cues.contains { haystack.contains($0) }
    }

    // MARK: - Helpers

    private static func frames(of asset: MediaAsset, editor: EditorViewModel, frameCount: Int) async throws -> [Data] {
        guard let url = editor.mediaResolver.resolveURL(for: asset.id) else {
            throw ToolError("Could not read the file for '\(asset.name)'.")
        }
        switch asset.type {
        case .video:
            return await VisionQA.videoFrames(url: url, count: frameCount)
        case .image:
            return VisionQA.imageJPEG(url: url).map { [$0] } ?? []
        default:
            throw ToolError("QA supports image or video assets (got \(asset.type.rawValue)).")
        }
    }

    private static func qaRubric(for shot: Shot, plan: ShotPlan, comparePriorPanel: Bool = false) -> String {
        var lines = ["Director's intent for this shot:"]
        if !shot.summary.isEmpty { lines.append("- Summary: \(shot.summary)") }
        if !shot.prompt.isEmpty { lines.append("- Prompt: \(shot.prompt)") }
        lines.append("- Motion: \(shot.motionLevel.rawValue), transition: \(shot.transition.rawValue)")
        let names = shot.characterIds.compactMap { plan.character(id: $0)?.name }
        if !names.isEmpty {
            lines.append("- Characters that must be on-model and consistent: \(names.joined(separator: ", "))")
        }
        if let blocking = shot.blocking, !blocking.isEmpty {
            lines.append("- Blocking (stated geometry, must hold): \(blocking)")
        }
        let anchors = shot.locationIds.compactMap { plan.location(id: $0)?.spatialAnchors }.filter { !$0.isEmpty }
        if let layout = anchors.first {
            lines.append("- Fixed location layout (landmarks must not move or mirror): \(layout)")
        }
        let onScreen = shot.onScreenDialogue.map(\.text).filter { !$0.isEmpty }
        if !onScreen.isEmpty {
            lines.append("- On-screen dialogue/action cues: \(onScreen.joined(separator: " / "))")
        }
        if comparePriorPanel {
            lines.append("- The LAST image is an earlier frame of THIS SAME location. Compare against it: named landmarks must not move, swap sides, or mirror, and characters must keep the same screen sides. Treat any spatial flip as a CRITICAL failure.")
        }
        lines.append("Judge the frame(s) against this intent and return the JSON verdict.")
        return lines.joined(separator: "\n")
    }

    /// One JPEG frame of the nearest earlier same-location shot's panel/video, for
    /// the QA spatial comparison (harness qa-storyboard). Nil without prior coverage.
    private func priorSameLocationQAFrame(_ shot: Shot, plan: ShotPlan, editor: EditorViewModel) async throws -> Data? {
        guard let idx = plan.shots.firstIndex(where: { $0.id == shot.id }), idx > 0 else { return nil }
        let locs = Set(shot.locationIds)
        guard !locs.isEmpty else { return nil }
        for prior in plan.shots[..<idx].reversed() {
            guard !locs.isDisjoint(with: prior.locationIds) else { continue }
            guard let assetId = prior.storyboardAssetId ?? prior.videoAssetId,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
                  Self.isReady(asset, editor: editor) else { continue }
            return try await Self.frames(of: asset, editor: editor, frameCount: 1).first
        }
        return nil
    }
}
