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
            throw ToolError("Nothing ready to review for shot \(shot.slug ?? shotId). Storyboard or generate it first, then poll get_media until the asset finishes.")
        }

        let rubric = Self.qaRubric(for: shot, plan: plan)
        let result = try await VisionQA.evaluate(images: images, rubric: rubric, api: api, model: model)

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
            throw ToolError("The storyboard panel is still generating. Poll get_media until it finishes.")
        }

        let instruction = args.string("instructions")
            ?? shot.qaSummary.map { "Fix these problems while keeping the same shot: \($0)" }
            ?? "Improve overall quality and fix any artifacts or deformities."
        let modelId = args.string("model")

        guard let placeholderId = EditSubmitter.submitImageEdit(
            asset: panel, prompt: instruction, modelId: modelId, editor: editor
        ) else {
            throw ToolError("Failed to start the panel correction.")
        }

        editor.mutateShotPlan(actionName: "Fix Panel") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].storyboardAssetId = placeholderId
            if plan.shots[idx].status == .qa { plan.shots[idx].status = .storyboarded }
        }

        let body: [String: Any] = [
            "shotId": shotId,
            "storyboardAssetId": placeholderId,
            "instruction": instruction,
            "hint": "Correction started. Poll get_media until it finishes, then qa_shot again.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
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

    private static func qaRubric(for shot: Shot, plan: ShotPlan) -> String {
        var lines = ["Director's intent for this shot:"]
        if !shot.summary.isEmpty { lines.append("- Summary: \(shot.summary)") }
        if !shot.prompt.isEmpty { lines.append("- Prompt: \(shot.prompt)") }
        lines.append("- Motion: \(shot.motionLevel.rawValue), transition: \(shot.transition.rawValue)")
        let names = shot.characterIds.compactMap { plan.character(id: $0)?.name }
        if !names.isEmpty {
            lines.append("- Characters that must be on-model and consistent: \(names.joined(separator: ", "))")
        }
        let onScreen = shot.onScreenDialogue.map(\.text).filter { !$0.isEmpty }
        if !onScreen.isEmpty {
            lines.append("- On-screen dialogue/action cues: \(onScreen.joined(separator: " / "))")
        }
        lines.append("Judge the frame(s) against this intent and return the JSON verdict.")
        return lines.joined(separator: "\n")
    }
}
