import Foundation

/// Drives background video production from a `ShotPlan`: for each shot it routes a model,
/// quotes cost, submits via the existing generation pipeline, awaits completion, optionally
/// runs vision QA, and lays the finished clip onto the timeline — reporting progress into the
/// active chat and its own observable run state. Per-editor, mirroring `GenerationService`'s
/// lifecycle (detach on close, reconcile on reopen).
@MainActor
@Observable
final class ProductionOrchestrator {
    weak var editor: EditorViewModel?

    struct Options: Sendable {
        var autoQA: Bool = false
        var maxRetries: Int = 2
        /// Seconds to wait before retrying a failed shot (grows per attempt).
        var retryBaseDelay: Double = 3
    }

    // MARK: - Observable run state

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var currentShotId: String?
    private(set) var completedCount = 0
    private(set) var totalCount = 0
    private(set) var runningUSD: Double = 0
    private(set) var lastError: String?

    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var cancelRequested = false

    var progressText: String {
        guard isRunning else { return "Idle" }
        let base = "Shot \(min(completedCount + 1, max(totalCount, 1))) of \(totalCount)"
        return isPaused ? "\(base) · paused" : base
    }

    // MARK: - Lifecycle

    /// Cancels the in-memory loop (Venice jobs already queued keep running server-side).
    func detachAll() {
        cancelRequested = true
        runTask?.cancel()
        runTask = nil
        isRunning = false
        isPaused = false
        currentShotId = nil
    }

    /// On reopen: place any shot whose generated video finished while closed and reconcile
    /// statuses — a shot stuck `generating`/`qa` with no recoverable asset flips to `failed`
    /// instead of shimmering forever; one still generating server-side gets a watcher that
    /// places it on completion. Does not auto-resume the loop — the user restarts it from
    /// the panel/agent.
    func resume(editor: EditorViewModel) {
        guard let plan = editor.shotPlan else { return }
        for shot in plan.shots {
            guard shot.status == .generating || shot.status == .qa else { continue }
            guard let assetId = shot.videoAssetId,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
                failShot(shot.id, reason: "Generation was interrupted before it could be recovered. Regenerate the shot.")
                continue
            }
            if ToolExecutor.isReady(asset, editor: editor) {
                if editor.productionClipId(forAsset: assetId) == nil {
                    _ = editor.placeProductionShotClip(asset: asset, actionName: "Place Shot")
                }
                editor.setShotStatus(id: shot.id, .placed)
            } else if asset.isGenerating || asset.isRecoveringGeneration {
                watchAndPlace(shotId: shot.id, assetId: assetId)
            } else {
                failShot(shot.id, reason: "Generation did not finish. Regenerate the shot.")
            }
        }
    }

    /// Polls a recovering generation and places the shot when its asset becomes ready
    /// (or marks the shot failed when the generation settles without a usable file).
    private func watchAndPlace(shotId: String, assetId: String) {
        Task { @MainActor [weak self] in
            while let self, let editor = self.editor {
                guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
                    self.failShot(shotId, reason: "Generated asset disappeared. Regenerate the shot.")
                    return
                }
                if ToolExecutor.isReady(asset, editor: editor) {
                    if editor.productionClipId(forAsset: assetId) == nil {
                        _ = editor.placeProductionShotClip(asset: asset, actionName: "Place Shot")
                    }
                    editor.setShotStatus(id: shotId, .placed)
                    return
                }
                if !asset.isGenerating && !asset.isRecoveringGeneration {
                    self.failShot(shotId, reason: "Generation did not finish. Regenerate the shot.")
                    return
                }
                try? await Task.sleep(for: .seconds(3))
                if self.cancelRequested { return }
            }
        }
    }

    // MARK: - Controls

    func pause() { isPaused = true }
    func unpause() { isPaused = false }
    func cancel() {
        cancelRequested = true
        runTask?.cancel()
        postNotice("Production cancelled.")
    }

    /// Starts producing the given shots (in plan order). Ignored if already running.
    func produceShots(ids requestedIds: [String], options: Options = Options()) {
        guard !isRunning, let editor, let plan = editor.shotPlan else { return }

        // Resolve to plan order; if none requested, produce everything not yet placed.
        let ordered = plan.shots.filter { shot in
            if requestedIds.isEmpty { return shot.status != .placed }
            return requestedIds.contains(shot.id)
        }.map(\.id)

        guard !ordered.isEmpty else {
            postNotice("Nothing to produce — all requested shots are already placed.")
            return
        }

        cancelRequested = false
        isRunning = true
        isPaused = false
        completedCount = 0
        totalCount = ordered.count
        lastError = nil
        postNotice("Starting production of \(ordered.count) shot\(ordered.count == 1 ? "" : "s").")

        runTask = Task { @MainActor in
            for shotId in ordered {
                if cancelRequested || Task.isCancelled { break }
                while isPaused && !cancelRequested { try? await Task.sleep(for: .milliseconds(300)) }
                if cancelRequested { break }
                currentShotId = shotId
                await produceOne(shotId: shotId, options: options)
                completedCount += 1
            }
            currentShotId = nil
            isRunning = false
            if !cancelRequested {
                postNotice("Production run finished (\(completedCount)/\(totalCount) shots).")
            }
        }
    }

    // MARK: - Per-shot production

    private func produceOne(shotId: String, options: Options) async {
        guard let editor, let plan = editor.shotPlan, let shot = plan.shot(id: shotId) else { return }
        let label = shot.slug ?? "shot \(shotId.prefix(6))"

        // Frame chaining: if the previous shot transitions by dissolve/match-cut, seed this
        // shot from its last frame for visual continuity (needs an image-to-video model).
        let chainFrame = await chainStartFrame(for: shotId, plan: plan, editor: editor)

        guard let route = route(shot, plan: plan, editor: editor, chainFrame: chainFrame) else {
            failShot(shotId, reason: "No enabled video model available.")
            return
        }

        // Seedance requires explicit user consent before a paid face-bearing job.
        if route.model.id.lowercased().contains("seedance"),
           !ModelPreferences.shared.seedanceConsentGranted {
            failShot(shotId, reason: "Seedance requires consent — enable it in Settings → Models, then re-run.")
            return
        }

        let (duration, aspect, resolution) = reconcile(shot: shot, model: route.model, plan: plan)
        if let err = route.model.validate(duration: duration, aspectRatio: aspect, resolution: resolution) {
            failShot(shotId, reason: err)
            return
        }

        // Clip currently backing this shot (non-nil only when regenerating) — captured before
        // recordTake rewrites the shot's videoAssetId, so we can replace it in place.
        let existingClipId = shot.videoAssetId.flatMap { editor.productionClipId(forAsset: $0) }

        editor.setShotStatus(id: shotId, .generating)
        let quoted = await VeniceAPI.fromKeychain()?.videoQuote(
            model: route.model.id, duration: duration, resolution: resolution, aspectRatio: aspect
        )
        let costNote = quoted.map { String(format: " (~$%.2f)", $0) } ?? ""
        postNotice("Generating \(label): \(route.note), \(duration)s\(costNote).")

        var genInput = GenerationInput(
            prompt: ShotPromptBuilder.videoPrompt(for: shot),
            model: route.model.id, duration: duration,
            aspectRatio: aspect, resolution: resolution
        )
        genInput.createdAt = Date()
        let generateAudio = ShotPromptBuilder.generateNativeAudio(for: shot)

        var lastFailure = "generation failed"
        for attempt in 0...max(0, options.maxRetries) {
            if cancelRequested { return }
            let asset = await submitAndAwait(
                genInput: genInput, model: route.model, inputAssets: route.inputAssets,
                placeholderDuration: Double(duration), generateAudio: generateAudio, editor: editor
            )

            guard let asset else {
                lastFailure = "generation failed"
                if attempt < options.maxRetries {
                    let delay = options.retryBaseDelay * Double(attempt + 1)
                    postNotice("\(label) failed — retrying in \(Int(delay))s (attempt \(attempt + 2)).")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                break
            }

            // Record the take + link the asset to the shot.
            recordTake(shotId: shotId, asset: asset, model: route.model.id)

            // Optional auto-QA: a hard fail with retries left triggers another take.
            if options.autoQA {
                if let result = await runAutoQA(shotId: shotId, asset: asset, plan: plan) {
                    if !result.pass && attempt < options.maxRetries {
                        postNotice("\(label) failed QA (score \(String(format: "%.2f", result.score))) — regenerating.")
                        try? await Task.sleep(for: .seconds(options.retryBaseDelay))
                        continue
                    }
                }
            }

            place(asset: asset, shotId: shotId, existingClipId: existingClipId, editor: editor)
            if let quoted { runningUSD += quoted }
            postNotice("Placed \(label) on the timeline.")
            return
        }

        failShot(shotId, reason: lastFailure)
    }

    /// Submits one video generation and suspends until it completes or fails.
    private func submitAndAwait(
        genInput: GenerationInput,
        model: VideoModelConfig,
        inputAssets: VideoGenerationSubmission.InputAssets,
        placeholderDuration: Double,
        generateAudio: Bool,
        editor: EditorViewModel
    ) async -> MediaAsset? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MediaAsset?, Never>) in
            let once = FirstOnlyFlag()
            let submission = VideoGenerationSubmission.make(
                genInput: genInput,
                model: model,
                inputAssets: inputAssets,
                placeholderDuration: placeholderDuration,
                folderId: nil,
                generateAudio: generateAudio
            )
            _ = submission.submit(
                service: editor.generationService,
                projectURL: editor.projectURL,
                editor: editor,
                onComplete: { asset in if once.fire() { continuation.resume(returning: asset) } },
                onFailure: { if once.fire() { continuation.resume(returning: nil) } }
            )
        }
    }

    private func runAutoQA(shotId: String, asset: MediaAsset, plan: ShotPlan) async -> VisionQA.Result? {
        guard let editor,
              let api = VeniceAPI.fromKeychain(),
              let model = VisionQA.selectModel(),
              let url = editor.mediaResolver.resolveURL(for: asset.id),
              let shot = editor.shotPlan?.shot(id: shotId) else { return nil }
        let frames = await VisionQA.videoFrames(url: url, count: 3)
        guard !frames.isEmpty else { return nil }
        let rubric = ProductionOrchestrator.qaRubric(for: shot, plan: plan)
        guard let result = try? await VisionQA.evaluate(images: frames, rubric: rubric, api: api, model: model) else {
            return nil
        }
        editor.mutateShotPlan(actionName: "QA Shot") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].qaSummary = result.summary
            if let last = plan.shots[idx].takes.indices.last {
                plan.shots[idx].takes[last].qaScore = result.score
                plan.shots[idx].takes[last].qaSummary = result.summary
            }
        }
        return result
    }

    // MARK: - Plan mutations

    private func recordTake(shotId: String, asset: MediaAsset, model: String) {
        editor?.mutateShotPlan(actionName: "Shot Take") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].videoAssetId = asset.id
            plan.shots[idx].takes.append(ShotTake(videoAssetId: asset.id, model: model))
            plan.shots[idx].failureReason = nil
        }
    }

    private func place(asset: MediaAsset, shotId: String, existingClipId: String?, editor: EditorViewModel) {
        // Replace an existing placed clip in-place (regeneration), else append in shot order.
        if let existingClipId {
            editor.replaceClipMediaRef(clipId: existingClipId, newAssetId: asset.id, resetTrim: true)
        } else {
            _ = editor.placeProductionShotClip(asset: asset, actionName: "Place Shot")
        }
        editor.setShotStatus(id: shotId, .placed)
    }

    private func failShot(_ shotId: String, reason: String) {
        lastError = reason
        editor?.mutateShotPlan(actionName: "Shot Failed") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].status = .failed
            plan.shots[idx].failureReason = reason
        }
        let label = editor?.shotPlan?.shot(id: shotId)?.slug ?? "shot"
        postNotice("\(label) failed: \(reason)")
    }

    // MARK: - Routing

    private struct Route {
        let model: VideoModelConfig
        let inputAssets: VideoGenerationSubmission.InputAssets
        let note: String
    }

    private func route(_ shot: Shot, plan: ShotPlan, editor: EditorViewModel, chainFrame: MediaAsset? = nil) -> Route? {
        let enabled = VideoModelConfig.allModels.filter { ModelPreferences.shared.isEnabled($0.id) }
        guard !enabled.isEmpty else { return nil }
        func find(_ id: String?) -> VideoModelConfig? { id.flatMap { wanted in enabled.first { $0.id == wanted } } }
        let override = find(shot.modelOverride)
        let defaultModel = find(plan.defaultModel)

        // Ready character reference images route to reference-to-video for consistency.
        var refs: [MediaAsset] = []
        for cid in shot.characterIds {
            guard let c = plan.character(id: cid) else { continue }
            for aid in c.referenceImageAssetIds {
                if let a = editor.mediaAssets.first(where: { $0.id == aid }),
                   a.type == .image, ToolExecutor.isReady(a, editor: editor) {
                    refs.append(a)
                }
            }
        }

        // Frame chaining takes priority when no character refs: seed an image-to-video model
        // from the previous shot's last frame.
        if refs.isEmpty, let chainFrame {
            let i2v = [override, defaultModel].compactMap { $0 }
                .first { $0.supportsFirstFrame && !$0.requiresSourceVideo }
                ?? enabled.first { $0.supportsFirstFrame && !$0.requiresSourceVideo }
            if let model = i2v {
                let ia = VideoGenerationSubmission.InputAssets(frames: [chainFrame])
                if ia.validate(for: model) == nil {
                    return Route(model: model, inputAssets: ia, note: "image-to-video (chained from previous shot)")
                }
            }
        }

        if !refs.isEmpty {
            let r2v = [override, defaultModel].compactMap { $0 }
                .first { $0.requiresReferenceImage && !$0.requiresSourceVideo && $0.maxReferenceImages > 0 }
                ?? enabled.first { $0.requiresReferenceImage && !$0.requiresSourceVideo && $0.maxReferenceImages > 0 }
            if let model = r2v {
                let capped = Array(refs.prefix(max(1, model.maxReferenceImages)))
                let ia = VideoGenerationSubmission.InputAssets(imageRefs: capped)
                if ia.validate(for: model) == nil {
                    return Route(model: model, inputAssets: ia, note: "reference-to-video (\(capped.count) ref\(capped.count == 1 ? "" : "s"))")
                }
            }
        }

        let t2v = [override, defaultModel].compactMap { $0 }
            .first { !$0.requiresReferenceImage && !$0.requiresSourceVideo }
            ?? enabled.first { !$0.requiresReferenceImage && !$0.requiresSourceVideo }
            ?? enabled.first
        guard let model = t2v else { return nil }
        return Route(model: model, inputAssets: VideoGenerationSubmission.InputAssets(), note: "text-to-video")
    }

    /// Extracts the previous shot's last frame when that shot transitions by dissolve or
    /// match-cut, to seed the current shot for continuity. Returns nil otherwise.
    private func chainStartFrame(for shotId: String, plan: ShotPlan, editor: EditorViewModel) async -> MediaAsset? {
        guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }), idx > 0 else { return nil }
        let prev = plan.shots[idx - 1]
        guard prev.transition == .dissolve || prev.transition == .matchCut else { return nil }
        guard let prevAssetId = prev.videoAssetId,
              let prevAsset = editor.mediaAssets.first(where: { $0.id == prevAssetId }),
              ToolExecutor.isReady(prevAsset, editor: editor),
              let url = editor.mediaResolver.resolveURL(for: prevAsset.id) else { return nil }
        guard let data = await LastFrameExtractor.pngData(url: url, atSeconds: max(0, prevAsset.duration - 0.05)),
              let frame = await editor.importPastedImageData(data, fileExtension: "png") else { return nil }
        frame.name = "Chain · \(prev.slug ?? "prev")"
        return frame
    }

    /// Snaps the shot's requested settings to what the model actually accepts.
    private func reconcile(shot: Shot, model: VideoModelConfig, plan: ShotPlan) -> (Int, String, String?) {
        let requested = Int(shot.durationSeconds.rounded())
        let duration: Int
        if model.durations.isEmpty {
            duration = max(1, requested)
        } else if model.durations.contains(requested) {
            duration = requested
        } else {
            duration = model.durations.min { abs($0 - requested) < abs($1 - requested) } ?? model.durations[0]
        }
        let aspect = model.aspectRatios.contains(plan.aspectRatio) ? plan.aspectRatio : (model.aspectRatios.first ?? plan.aspectRatio)
        let resolution: String?
        if let allowed = model.resolutions, !allowed.isEmpty {
            resolution = allowed.contains(plan.resolution) ? plan.resolution : allowed.first
        } else {
            resolution = nil
        }
        return (duration, aspect, resolution)
    }

    // MARK: - QA rubric (shared with qa_shot)

    static func qaRubric(for shot: Shot, plan: ShotPlan) -> String {
        var lines = ["Director's intent for this shot:"]
        if !shot.summary.isEmpty { lines.append("- Summary: \(shot.summary)") }
        if !shot.prompt.isEmpty { lines.append("- Prompt: \(shot.prompt)") }
        let names = shot.characterIds.compactMap { plan.character(id: $0)?.name }
        if !names.isEmpty { lines.append("- Characters that must be on-model: \(names.joined(separator: ", "))") }
        lines.append("Judge the frames against this intent and return the JSON verdict.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Progress

    private func postNotice(_ text: String) {
        editor?.agentService.postSystemNotice(text)
    }
}
