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
        guard let model = try resolveImageModelForStoryboard(args) else {
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
        let resolution = args.string("resolution") ?? Self.cheapestResolution(model)
        let quality = model.qualities?.last
        let useRefs = (args.bool("useCharacterRefs") ?? true) && model.supportsImageReference
        let folderArg = args.string("folderId")

        var results: [[String: Any]] = []
        for shot in targets {
            let basePrompt = shot.prompt.isEmpty ? shot.summary : shot.prompt
            guard !basePrompt.isEmpty else {
                throw ToolError("Shot \(shot.slug ?? shot.id) has no prompt or summary to storyboard.")
            }
            let panelPrompt = "\(basePrompt), cinematic storyboard frame, \(shot.motionLevel.rawValue) motion"

            // Gather ready character reference images (up to 3 total for multi-edit).
            var refs: [MediaAsset] = []
            if useRefs {
                for cid in shot.characterIds {
                    guard let character = plan.character(id: cid) else { continue }
                    for aid in character.referenceImageAssetIds {
                        if refs.count >= 3 { break }
                        if let a = editor.mediaAssets.first(where: { $0.id == aid }),
                           a.type == .image, Self.isReady(a, editor: editor) {
                            refs.append(a)
                        }
                    }
                    if refs.count >= 3 { break }
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

            results.append([
                "shotId": shot.id,
                "slug": shot.slug ?? shot.id,
                "storyboardAssetId": placeholderId,
                "referencesUsed": refs.count,
            ])
        }

        let body: [String: Any] = [
            "model": model.id,
            "storyboarded": results,
            "hint": "Panels are generating. Poll get_media until they finish, inspect_media to review, then qa_shot / fix_panel or start production.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - Helpers

    /// A generated asset is usable as a reference only once its file is on disk.
    static func isReady(_ asset: MediaAsset, editor: EditorViewModel) -> Bool {
        guard asset.generationStatus == .none else { return false }
        guard let url = editor.mediaResolver.resolveURL(for: asset.id) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func resolveImageModelForStoryboard(_ args: [String: Any]) throws -> ImageModelConfig? {
        if let id = args.string("model") {
            guard let model = ImageModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown image model '\(id)'.")
            }
            guard ModelPreferences.shared.isEnabled(id) else {
                throw ToolError("Image model '\(id)' is turned off in Settings → Models.")
            }
            return model
        }
        // Prefer an enabled model that supports image references (for character consistency).
        return ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) && $0.supportsImageReference }
            ?? ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) }
    }
}
