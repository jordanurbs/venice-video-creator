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
    /// Shots waiting to produce, drained in order by the run loop. New
    /// `produceShots` calls append here instead of being refused, so requests made
    /// mid-run queue behind the active shot. Observable so the UI can show a shot
    /// as queued.
    private(set) var pendingQueue: [String] = []

    /// Whether a shot is currently generating or waiting in the queue.
    func isActive(_ shotId: String) -> Bool {
        currentShotId == shotId || pendingQueue.contains(shotId)
    }
    /// Resumes the continuation `submitAndAwait` is parked on — task cancellation
    /// can't reach it, so Stop must fire this or `isRunning` sticks true forever.
    @ObservationIgnored private var interruptAwait: (() -> Void)?

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
        interruptAwait?()
        interruptAwait = nil
        pendingQueue.removeAll()
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

    /// Stops the run NOW. The loop is usually parked awaiting a generation —
    /// task cancellation can't reach that continuation, so it's resumed
    /// explicitly and run state is reset immediately (not when the in-flight
    /// Venice job eventually settles). Shots left mid-flight revert from
    /// `generating` to their pre-run status so per-shot Generate stays usable.
    func cancel() {
        guard isRunning else { return }
        cancelRequested = true
        isPaused = false
        runTask?.cancel()
        runTask = nil
        interruptAwait?()
        interruptAwait = nil
        pendingQueue.removeAll()
        revertInFlightShots()
        currentShotId = nil
        isRunning = false
        postNotice("Production stopped.")
    }

    /// Flips any shot stuck in `generating` back to storyboarded/planned. Used
    /// on Stop; the abandoned asset keeps generating server-side and is
    /// reconciled by `resume()` if it lands.
    private func revertInFlightShots() {
        guard let editor, let plan = editor.shotPlan else { return }
        for shot in plan.shots where shot.status == .generating {
            editor.setShotStatus(id: shot.id, shot.storyboardAssetId != nil ? .storyboarded : .planned)
        }
    }

    /// Starts producing the given shots (in plan order), or — if a run is already
    /// active — appends them to the pending queue so they generate after the
    /// in-flight shot instead of being refused.
    func produceShots(ids requestedIds: [String], options: Options = Options()) {
        guard let editor, let plan = editor.shotPlan else { return }

        // Resolve to plan order; if none requested, produce everything not yet placed.
        let ordered = plan.shots.filter { shot in
            if requestedIds.isEmpty { return shot.status != .placed }
            return requestedIds.contains(shot.id)
        }.map(\.id)

        guard !ordered.isEmpty else {
            postNotice("Nothing to produce — all requested shots are already placed.")
            return
        }

        // Queue behind the active run. Skip the shot already generating and any
        // already queued so double-clicks and overlapping requests coalesce rather
        // than enqueue duplicate takes. Queued shots inherit the running options.
        if isRunning {
            let addable = ordered.filter { $0 != currentShotId && !pendingQueue.contains($0) }
            guard !addable.isEmpty else {
                postNotice("Those shots are already generating or queued.")
                return
            }
            pendingQueue.append(contentsOf: addable)
            totalCount += addable.count
            postNotice("Queued \(addable.count) shot\(addable.count == 1 ? "" : "s") behind the active run.")
            return
        }

        cancelRequested = false
        isRunning = true
        isPaused = false
        completedCount = 0
        totalCount = ordered.count
        lastError = nil
        pendingQueue = ordered
        postNotice("Starting production of \(ordered.count) shot\(ordered.count == 1 ? "" : "s").")

        runTask = Task { @MainActor in
            while !pendingQueue.isEmpty {
                if cancelRequested || Task.isCancelled { break }
                while isPaused && !cancelRequested { try? await Task.sleep(for: .milliseconds(300)) }
                if cancelRequested { break }
                let shotId = pendingQueue.removeFirst()
                currentShotId = shotId
                await produceOne(shotId: shotId, options: options)
                completedCount += 1
            }
            pendingQueue.removeAll()
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
        // Legacy overlong shot (planned before the cap): refuse to silently
        // truncate a paid generation — the user splits it, then re-runs.
        // Snapping to a nearby ladder rung (12s → 10s) is fine; exceeding the
        // model's longest clip is not.
        if let longest = route.model.durations.max(), shot.durationSeconds > Double(longest) {
            failShot(shotId, reason: "Planned \(Int(shot.durationSeconds))s but \(route.model.displayName) generates at most \(longest)s. Split the shot (shot inspector → Split) instead of truncating.")
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
            prompt: ShotPromptBuilder.videoPrompt(for: shot, plan: plan),
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

            // Interrupted by Stop — state was already reset; don't mark failed.
            if cancelRequested { return }

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
            interruptAwait = { if once.fire() { continuation.resume(returning: nil) } }
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
        let clipId: String?
        if let existingClipId {
            editor.replaceClipMediaRef(clipId: existingClipId, newAssetId: asset.id, resetTrim: true)
            clipId = existingClipId
        } else {
            clipId = editor.placeProductionShotClip(asset: asset, actionName: "Place Shot")?.clipId
        }
        // Audio is always generated; the shot's mix choice lands as clip volume
        // (keep=1, duck=0.3, mute=0) — recoverable in the timeline, unlike a
        // generation with no audio track.
        if let clipId, let shot = editor.shotPlan?.shot(id: shotId) {
            let volume = ShotPromptBuilder.placedClipVolume(for: shot)
            if volume < 1.0, let loc = editor.findClip(id: clipId) {
                editor.timeline.tracks[loc.trackIndex].clips[loc.clipIndex].volume = volume
                editor.notifyTimelineChanged()
            }
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

        // Ready character + location reference images route to reference-to-video
        // for consistency. A locked reference wins alone — never divergent takes.
        var refs: [MediaAsset] = []
        func appendReady(_ assetIds: [String]) {
            for aid in assetIds {
                if let a = editor.mediaAssets.first(where: { $0.id == aid }),
                   a.type == .image, ToolExecutor.isReady(a, editor: editor) {
                    refs.append(a)
                }
            }
        }
        for cid in shot.characterIds {
            guard let c = plan.character(id: cid) else { continue }
            appendReady(c.activeReferenceAssetIds)
        }
        for lid in shot.locationIds {
            guard let l = plan.location(id: lid) else { continue }
            appendReady(l.activeReferenceAssetIds)
        }

        // Explicit shot audio ref wins; else the first attached character with a
        // locked voice reference (when the shot hasn't opted out). Only attached
        // to models that accept audio input — never risks a queue rejection.
        let audioRef = voiceAudioReference(for: shot, plan: plan, editor: editor)
        func audioRefs(for model: VideoModelConfig) -> [MediaAsset] {
            guard let audioRef, model.maxReferenceAudios > 0 else { return [] }
            return [audioRef]
        }

        // Frame chaining takes priority when no character refs: seed an image-to-video model
        // from the previous shot's last frame.
        if refs.isEmpty, let chainFrame {
            let i2v = [override, defaultModel].compactMap { $0 }
                .first { $0.supportsFirstFrame && !$0.requiresSourceVideo }
                ?? enabled.first { $0.supportsFirstFrame && !$0.requiresSourceVideo }
            if let model = i2v {
                let ia = VideoGenerationSubmission.InputAssets(frames: [chainFrame], audioRefs: audioRefs(for: model))
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
                let audio = audioRefs(for: model)
                let ia = VideoGenerationSubmission.InputAssets(imageRefs: capped, audioRefs: audio)
                if ia.validate(for: model) == nil {
                    let audioNote = audio.isEmpty ? "" : " + voice ref"
                    return Route(model: model, inputAssets: ia, note: "reference-to-video (\(capped.count) ref\(capped.count == 1 ? "" : "s")\(audioNote))")
                }
            }
        }

        let t2v = [override, defaultModel].compactMap { $0 }
            .first { !$0.requiresReferenceImage && !$0.requiresSourceVideo }
            ?? enabled.first { !$0.requiresReferenceImage && !$0.requiresSourceVideo }
            ?? enabled.first
        guard let model = t2v else { return nil }
        let ia = VideoGenerationSubmission.InputAssets(audioRefs: audioRefs(for: model))
        return Route(model: model, inputAssets: ia.validate(for: model) == nil ? ia : VideoGenerationSubmission.InputAssets(), note: "text-to-video")
    }

    /// Resolves the audio reference to attach to a shot's generation: the shot's
    /// explicit audioReferenceAssetId, else (when attachCastVoiceReference) the
    /// locked voice reference of the first attached character that has one.
    /// Returns nil unless the asset exists, is audio, and is ready.
    private func voiceAudioReference(for shot: Shot, plan: ShotPlan, editor: EditorViewModel) -> MediaAsset? {
        func readyAudio(_ assetId: String?) -> MediaAsset? {
            guard let assetId,
                  let a = editor.mediaAssets.first(where: { $0.id == assetId }),
                  a.type == .audio, ToolExecutor.isReady(a, editor: editor) else { return nil }
            return a
        }
        if let explicit = readyAudio(shot.audioReferenceAssetId) { return explicit }
        guard shot.attachCastVoiceReference else { return nil }
        for cid in shot.characterIds {
            if let ref = readyAudio(plan.character(id: cid)?.voiceReferenceAssetId) { return ref }
        }
        return nil
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
        // Spatial continuity (harness rule 49): give the reviewer the authored
        // geometry so side-swaps and mirrored geography are caught against the
        // stated layout instead of prose alone.
        if let blocking = shot.blocking, !blocking.isEmpty {
            lines.append("- Blocking (stated geometry, must hold): \(blocking)")
        }
        let anchors = shot.locationIds.compactMap { plan.location(id: $0)?.spatialAnchors }.filter { !$0.isEmpty }
        if let layout = anchors.first {
            lines.append("- Fixed location layout (landmarks must not move or mirror): \(layout)")
        }
        lines.append("Judge the frames against this intent and return the JSON verdict.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Progress

    private func postNotice(_ text: String) {
        editor?.agentService.postSystemNotice(text)
    }
}
