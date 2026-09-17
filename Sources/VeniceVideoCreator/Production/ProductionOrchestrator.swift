import AVFoundation
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
        var videoBudget: VideoGenerationBudget?
        var autoQA: Bool = false
        var maxRetries: Int = 2
        /// Seconds to wait before retrying a failed shot (grows per attempt).
        var retryBaseDelay: Double = 3
        /// Units generating at once. Venice queues jobs server-side, so
        /// producing shots one at a time was pure waiting; frame-chained
        /// shots (dissolve/matchCut from the previous shot) still serialize
        /// on their dependency.
        var maxParallel: Int = 3
    }

    // MARK: - Observable run state

    private(set) var isRunning = false
    private(set) var isPaused = false
    private(set) var currentShotId: String?
    private(set) var completedCount = 0
    private(set) var failedCount = 0
    private(set) var cancelledCount = 0
    var settledCount: Int { completedCount + failedCount + cancelledCount }
    private(set) var totalCount = 0
    private(set) var runningUSD: Double = 0
    private(set) var lastError: String?

    @ObservationIgnored var executeUnit: ((MultiShotPlanner.Unit, Options) async -> Void)?
    @ObservationIgnored var availableModels: (() -> [VideoModelConfig])?
    @ObservationIgnored var quoteVideo: ((String, Int, String?, String) async -> Double?)?
    @ObservationIgnored var generateVideo: ((GenerationInput) async -> MediaAsset?)?
    @ObservationIgnored var validateVideo: ((MediaAsset, Double, String) async -> OutputValidator.Result)?
    @ObservationIgnored var evaluateVideoQA: ((String, MediaAsset, ShotPlan, ShotSourceRange) async -> VisionQA.Result?)?
    @ObservationIgnored var digestVideo: ((MediaAsset) async throws -> String)?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var unitTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var finalizingAttemptIds: Set<String> = []
    @ObservationIgnored private var recoveryOperationId: String?
    @ObservationIgnored private var cancelRequested = false
    /// Generation units waiting to produce, drained in order by the run loop.
    /// A unit is one shot (normal) or a grouped multi-shot window (opt-in).
    /// New `produceShots` calls append here instead of being refused, so
    /// requests made mid-run queue behind the active unit. Observable so the
    /// UI can show a shot as queued.
    private(set) var pendingQueue: [MultiShotPlanner.Unit] = []

    /// Shot ids of the unit currently generating (one for singles).
    @ObservationIgnored private var currentUnitShotIds: [String] = []
    /// All shot ids generating right now (parallel units).
    private(set) var generatingShotIds: Set<String> = []

    /// Whether a shot is waiting in the pending queue (not yet generating).
    func isQueued(_ shotId: String) -> Bool {
        pendingQueue.contains { $0.shotIds.contains(shotId) }
    }

    /// Whether a shot is currently generating or waiting in the queue.
    func isActive(_ shotId: String) -> Bool {
        currentShotId == shotId
            || currentUnitShotIds.contains(shotId)
            || generatingShotIds.contains(shotId)
            || pendingQueue.contains(where: { $0.shotIds.contains(shotId) })
    }
    /// Resumes the continuations `submitAndAwait` is parked on — task cancellation
    /// can't reach them, so Stop must fire these or `isRunning` sticks true
    /// forever. Keyed per await because parallel units park several at once.
    @ObservationIgnored private var interruptAwaits: [UUID: () -> Void] = [:]

    private func fireInterrupts() {
        for resume in interruptAwaits.values { resume() }
        interruptAwaits.removeAll()
    }

    func acceptsSubmissions(runId: UUID) -> Bool { isRunning && !cancelRequested && runID == runId }
    var currentRunId: UUID { runID }
    var isFinalizingExistingTake: Bool { recoveryOperationId != nil }

    private func cancelUnitTasks() {
        for task in unitTasks.values { task.cancel() }
        unitTasks.removeAll()
    }

    private func startOperation(shotIds: [String], options: Options, runId: UUID) async -> String? {
        guard acceptsSubmissions(runId: runId), let editor else { return nil }
        var operationId: String?
        do {
            let id = try editor.beginProductionOperation(shotIds: shotIds, runId: runId, autoQA: options.autoQA)
            operationId = id
            try await editor.checkpointProductionState()
            guard operationIsCurrent(id) else { return nil }
            return id
        } catch {
            if let operationId, editor.productionOperation(id: operationId)?.stage.isTerminal == false {
                editor.mutateProductionOperation(operationId) { $0.stage = .failed; $0.failureReason = error.localizedDescription }
            }
            if acceptsSubmissions(runId: runId) {
                for shotId in shotIds { failShot(shotId, reason: error.localizedDescription) }
            }
            return nil
        }
    }

    private func operationIsCurrent(_ id: String) -> Bool {
        guard let editor else { return false }
        do { _ = try editor.requireCurrentProductionOperation(id); return !Task.isCancelled }
        catch {
            guard let operation = editor.productionOperation(id: id), !operation.stage.isTerminal else { return false }
            editor.mutateProductionOperation(id) { $0.stage = .failed; $0.failureReason = error.localizedDescription }
            if acceptsSubmissions(runId: operation.runId) {
                for destination in operation.destinations where editor.shot(id: destination.shotId)?.activeProductionOperationId == id {
                    failShot(destination.shotId, reason: error.localizedDescription)
                }
            }
            return false
        }
    }

    private func settleUnfinishedOperation(_ id: String) {
        guard let editor, let operation = editor.productionOperation(id: id), !operation.stage.isTerminal else { return }
        let reason = operation.destinations.compactMap { editor.shot(id: $0.shotId)?.failureReason }.first ?? "Production did not finish. Review the operation before retrying."
        editor.mutateProductionOperation(id) { $0.stage = .failed; $0.failureReason = reason }
    }

    private func quote(model: String, duration: Int, resolution: String?, aspect: String) async -> Double? {
        if let quoteVideo { return await quoteVideo(model, duration, resolution, aspect) }
        return await VeniceAPI.fromKeychain()?.videoQuote(model: model, duration: duration, resolution: resolution, aspectRatio: aspect)
    }

    func validate(asset: MediaAsset, duration: Double, aspect: String) async -> OutputValidator.Result {
        if let validateVideo { return await validateVideo(asset, duration, aspect) }
        guard let url = editor?.mediaResolver.resolveURL(for: asset.id) else { return .fail("Generated video cannot be resolved.") }
        let result = await OutputValidator.validate(url: url, requestedDurationSeconds: duration, targetAspectRatio: aspect)
        guard result.ok else { return result }
        guard let measured = try? await AVURLAsset(url: url).load(.duration), measured.seconds.isFinite, measured.seconds > 0 else {
            return .fail("Could not measure the retained video's duration.")
        }
        asset.duration = measured.seconds
        editor?.updateManifestMetadata(for: asset)
        return result
    }

    var progressText: String {
        guard isRunning else { return "Idle" }
        let base = "Shot \(min(settledCount + 1, max(totalCount, 1))) of \(totalCount)"
        return isPaused ? "\(base) · paused" : base
    }

    // MARK: - Lifecycle

    /// Cancels the in-memory loop (Venice jobs already queued keep running server-side).
    func detachAll() {
        if let recoveryOperationId { editor?.mutateProductionOperation(recoveryOperationId) { if !$0.stage.isTerminal { $0.stage = .interrupted } } }
        recoveryOperationId = nil
        editor?.settleProductionOperations(runId: runID, stage: .interrupted)
        cancelledCount += max(0, totalCount - settledCount)
        runID = UUID()
        cancelRequested = true
        runTask?.cancel()
        runTask = nil
        cancelUnitTasks()
        fireInterrupts()
        pendingQueue.removeAll()
        generatingShotIds.removeAll()
        currentUnitShotIds = []
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
        guard !isRunning else { return }
        editor.reconcileLegacyProductionPlacements()
        guard let plan = editor.shotPlan else { return }
        for shot in plan.shots {
            guard shot.status == .generating || shot.status == .qa else { continue }
            if let operationId = shot.activeProductionOperationId {
                if let operation = editor.productionOperation(id: operationId), operation.stage == .placed { continue }
                if let operation = editor.productionOperation(id: operationId), !operation.stage.isTerminal {
                    editor.mutateProductionOperation(operationId) { $0.stage = .interrupted }
                }
                failShot(shot.id, reason: "Production was interrupted. Its operation and generated assets are retained; review them before starting another take.")
                continue
            }
            guard let assetId = shot.takes.last?.videoAssetId ?? shot.videoAssetId,
                  let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
                failShot(shot.id, reason: "Generation was interrupted before it could be recovered. Regenerate the shot.")
                continue
            }
            if ToolExecutor.isReady(asset, editor: editor) {
                recoverPlacement(shotId: shot.id, asset: asset, editor: editor)
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
                guard let shot = editor.shot(id: shotId), shot.status == .generating || shot.status == .qa,
                      shot.activeProductionOperationId == nil,
                      (shot.takes.last?.videoAssetId ?? shot.videoAssetId) == assetId else { return }
                guard let asset = editor.mediaAssets.first(where: { $0.id == assetId }) else {
                    self.failShot(shotId, reason: "Generated asset disappeared. Regenerate the shot.")
                    return
                }
                if ToolExecutor.isReady(asset, editor: editor) {
                    self.recoverPlacement(shotId: shotId, asset: asset, editor: editor)
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

    private func recoverPlacement(shotId: String, asset: MediaAsset, editor: EditorViewModel) {
        guard let shot = editor.shot(id: shotId) else { return }
        do {
            if shot.placement?.assetId == asset.id, try editor.productionClip(for: shot) != nil {
                editor.setShotStatus(id: shotId, .placed)
                return
            }
            let take = shot.takes.last { $0.videoAssetId == asset.id }
            let shared = editor.shotPlan?.shots.filter { ($0.takes.last?.videoAssetId ?? $0.videoAssetId) == asset.id }.count ?? 0
            guard shared <= 1 || take?.sourceRange != nil else {
                throw ToolError("Shared legacy take has no per-shot source range. Bind each beat's timeline clip before recovery.")
            }
            let segment: ClosedRange<Double>?
            if let range = take?.sourceRange {
                guard range.startSeconds.isFinite, range.endSeconds.isFinite, range.endSeconds > range.startSeconds else {
                    throw ToolError("Recovered shot has an invalid source range. Reconcile its placement before recovery.")
                }
                segment = range.startSeconds...range.endSeconds
            } else { segment = nil }
            try editor.placeProductionShot(asset: asset, shotId: shotId, sourceSegment: segment)
            editor.reorderProductionClipsToPlanOrder()
        } catch { failShot(shotId, reason: error.localizedDescription) }
    }

    func pause() { isPaused = true }
    func unpause() { isPaused = false }

    @discardableResult
    func resumeProduction(operationId: String, approvalReason: String? = nil) throws -> Bool {
        guard !isRunning, let editor else { throw ToolError("Wait for the current production to finish.") }
        guard let operation = editor.productionOperation(id: operationId), let attempt = operation.attempts.last,
              let assetId = attempt.placeholderId, editor.mediaAssets.contains(where: { $0.id == assetId }) else {
            throw ToolError("Operation has no retained video attempt to finalize.")
        }
        guard !finalizingAttemptIds.contains(attempt.id) else { throw ToolError("The previous finalization is still settling. Retry when it finishes.") }
        if operation.stage == .placed {
            guard hasCurrentFinalizedPlacement(operation) else { throw ToolError("The finalized placement was edited or removed. Reconcile the shot before restoring this take.") }
            if operation.failureReason == nil { return false }
        } else {
            _ = try editor.requireProductionDestination(operationId)
        }
        if let approvalReason, approvalReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolError("Record a reason for approving this take.")
        }
        runID = UUID()
        let id = runID
        recoveryOperationId = operationId
        cancelRequested = false
        isRunning = true
        isPaused = false
        currentShotId = operation.destinations.first?.shotId
        totalCount = operation.destinations.count
        completedCount = 0
        failedCount = 0
        cancelledCount = 0
        runningUSD = 0
        lastError = nil
        editor.mutateProductionOperation(operationId) { if $0.stage != .placed { $0.stage = .validating }; $0.failureReason = nil }
        editor.generationService.resumePendingGenerations(editor: editor, assetIds: [assetId])
        runTask = Task { @MainActor in
            while acceptsSubmissions(runId: id), let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
                  asset.isGenerating {
                try? await Task.sleep(for: .seconds(1))
            }
            guard acceptsSubmissions(runId: id) else { return }
            let outcome = await finalizeAttempt(operationId: operationId, runId: id, approvalReason: approvalReason)
            guard acceptsSubmissions(runId: id) else { return }
            if outcome == .placed {
                completedCount = totalCount
                postNotice("Finished the retained take. No video generation was submitted.")
            } else {
                failedCount = totalCount
                let reason = outcome == .stopped ? "Shot settings or destination changed during finalization." : finalizationFailure(operationId)
                lastError = reason
                if editor.productionOperation(id: operationId)?.stage != .placed {
                    editor.mutateProductionOperation(operationId) { $0.stage = .failed; $0.failureReason = reason }
                    for destination in operation.destinations where editor.shot(id: destination.shotId)?.activeProductionOperationId == operationId {
                        failShot(destination.shotId, reason: reason)
                    }
                }
            }
            recoveryOperationId = nil
            currentShotId = nil
            isRunning = false
        }
        return true
    }

    /// Stops the run NOW. The loop is usually parked awaiting a generation —
    /// task cancellation can't reach that continuation, so it's resumed
    /// explicitly and run state is reset immediately (not when the in-flight
    /// Venice job eventually settles). Shots left mid-flight revert from
    /// `generating` to their pre-run status so per-shot Generate stays usable.
    func cancel() {
        guard isRunning else { return }
        if let recoveryOperationId { editor?.mutateProductionOperation(recoveryOperationId) { if !$0.stage.isTerminal { $0.stage = .cancelled } } }
        recoveryOperationId = nil
        editor?.settleProductionOperations(runId: runID, stage: .cancelled)
        cancelledCount += max(0, totalCount - settledCount)
        runID = UUID()
        cancelRequested = true
        isPaused = false
        runTask?.cancel()
        runTask = nil
        cancelUnitTasks()
        fireInterrupts()
        pendingQueue.removeAll()
        generatingShotIds.removeAll()
        currentUnitShotIds = []
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
    @discardableResult
    func produceShots(ids requestedIds: [String], options: Options = Options()) -> Bool {
        guard recoveryOperationId == nil else { lastError = "Wait for take finalization to finish before starting another production."; return false }
        guard let editor, let plan = editor.shotPlan else { return false }

        // Resolve to plan order; if none requested, produce everything not yet placed.
        let orderedShots = plan.shots.filter { shot in
            if requestedIds.isEmpty { return shot.status != .placed }
            return requestedIds.contains(shot.id)
        }

        guard !orderedShots.isEmpty else {
            postNotice("Nothing to produce — all requested shots are already placed.")
            return false
        }

        do {
            for shot in orderedShots {
                _ = try editor.productionClip(for: shot)
                _ = try editor.requireApprovedStoryboard(for: shot, plan: plan)
            }
        } catch {
            lastError = error.localizedDescription
            postNotice(lastError!)
            return false
        }

        let requiresBudget = orderedShots.contains {
            VideoGenerationBudget.isRequired(model: $0.modelOverride ?? plan.defaultModel ?? "", resolution: plan.resolution)
        }
        if requiresBudget && (options.videoBudget == nil || isRunning) {
            lastError = isRunning
                ? "Wait for the current production run to finish before submitting a new 1080P budget."
                : "Set a 1080P spending cap in the Production panel or pass maxCostUSD with user approval."
            postNotice(lastError!)
            return false
        }

        // Group consecutive same-scene shots into multi-shot units when the
        // user opted in (Settings → Models). Single-shot regenerations
        // (one requested id) never group — a retake must not re-render
        // neighbors that are already placed.
        let groupingEnabled = ModelPreferences.shared.multiShotGroupingEnabled && orderedShots.count > 1
        // Size the window to the routed family: Seedance 2.5 renders a single
        // pass up to 30s, so it can absorb a longer same-scene run in one take.
        let budget = windowBudget(plan: plan)
        let ordered = MultiShotPlanner.plan(shots: orderedShots, plan: plan, groupingEnabled: groupingEnabled, budget: budget)
        let grouped = ordered.filter(\.isMultiShot)
        if !grouped.isEmpty {
            let shotsInGroups = grouped.reduce(0) { $0 + $1.shotIds.count }
            postNotice("Multi-shot grouping: \(shotsInGroups) shots render as \(grouped.count) grouped generation\(grouped.count == 1 ? "" : "s") for continuity.")
        }

        // Queue behind the active run. Skip units whose shots are already
        // generating or queued so double-clicks and overlapping requests
        // coalesce rather than enqueue duplicate takes. Queued units inherit
        // the running options.
        if isRunning {
            let busy = Set([currentShotId].compactMap { $0 } + currentUnitShotIds
                + generatingShotIds
                + pendingQueue.flatMap(\.shotIds))
            let addable = ordered.filter { $0.shotIds.allSatisfy { !busy.contains($0) } }
            guard !addable.isEmpty else {
                postNotice("Those shots are already generating or queued.")
                return false
            }
            pendingQueue.append(contentsOf: addable)
            let addedShots = addable.reduce(0) { $0 + $1.shotIds.count }
            totalCount += addedShots
            postNotice("Queued \(addedShots) shot\(addedShots == 1 ? "" : "s") behind the active run.")
            return true
        }

        let totalShots = ordered.reduce(0) { $0 + $1.shotIds.count }
        cancelRequested = false
        isRunning = true
        isPaused = false
        completedCount = 0
        failedCount = 0
        cancelledCount = 0
        runningUSD = 0
        runID = UUID()
        let id = runID
        totalCount = totalShots
        lastError = nil
        pendingQueue = ordered
        postNotice("Starting production of \(totalShots) shot\(totalShots == 1 ? "" : "s") (\(ordered.count) generation\(ordered.count == 1 ? "" : "s")).")

        runTask = Task { @MainActor in
            await runLoop(options: options, id: id)
            guard runID == id else { return }
            pendingQueue.removeAll()
            currentShotId = nil
            currentUnitShotIds = []
            generatingShotIds.removeAll()
            isRunning = false
            if !cancelRequested {
                postNotice("Production finished: \(completedCount) succeeded, \(failedCount) failed, \(cancelledCount) cancelled (\(totalCount) shots).")
            }
        }
        return true
    }

    /// Drains the queue with up to `maxParallel` units generating at once.
    /// Venice runs jobs server-side, so serializing them was pure waiting.
    /// A shot whose PREVIOUS plan shot transitions by dissolve/matchCut is
    /// seeded from that shot's last frame, so it only starts after the
    /// previous shot has settled (not merely started).
    private func runLoop(options: Options, id: UUID) async {
        var inFlight = 0
        var settled: Set<String> = []

        func chainDependency(of unit: MultiShotPlanner.Unit) -> String? {
            guard let plan = editor?.shotPlan,
                  let firstId = unit.shotIds.first,
                  let idx = plan.shots.firstIndex(where: { $0.id == firstId }), idx > 0
            else { return nil }
            let prev = plan.shots[idx - 1]
            guard prev.transition == .dissolve || prev.transition == .matchCut else { return nil }
            return prev.id
        }

        // Completion channel: each launched unit reports its shot ids here when
        // done. (AsyncStream instead of a task group — the class is @MainActor
        // and the region-isolation checker rejects main-actor task-group children.)
        var reportCompletion: (([String]) -> Void)!
        let completions = AsyncStream<[String]> { continuation in
            reportCompletion = { continuation.yield($0) }
        }
        var completionIterator = completions.makeAsyncIterator()
        let report = reportCompletion!

        while !pendingQueue.isEmpty || inFlight > 0 {
            if cancelRequested || runID != id { break }
            while isPaused && !cancelRequested && runID == id { try? await Task.sleep(for: .milliseconds(300)) }
            if cancelRequested || runID != id { break }

            // Launch every startable unit up to the parallelism cap.
            while inFlight < max(1, options.maxParallel), !pendingQueue.isEmpty {
                // First unit whose chain dependency (if any) has settled or
                // isn't part of this run at all.
                let startableIndex = pendingQueue.firstIndex { unit in
                    guard let dep = chainDependency(of: unit) else { return true }
                    let depPending = pendingQueue.contains { $0.shotIds.contains(dep) }
                    let depGenerating = generatingShotIds.contains(dep)
                    return settled.contains(dep) || (!depPending && !depGenerating)
                }
                guard let startableIndex else { break }  // everything waits on a dependency
                let unit = pendingQueue.remove(at: startableIndex)
                generatingShotIds.formUnion(unit.shotIds)
                currentShotId = unit.shotIds.first
                if unit.isMultiShot { currentUnitShotIds = unit.shotIds }
                inFlight += 1
                let taskId = UUID()
                unitTasks[taskId] = Task { @MainActor [weak self] in
                    if let self, self.runID == id {
                        if let executeUnit = self.executeUnit {
                            await executeUnit(unit, options)
                        } else if unit.isMultiShot {
                            await self.produceUnit(unit, options: options, runId: id)
                        } else if let shotId = unit.shotIds.first {
                            await self.produceOne(shotId: shotId, options: options, runId: id)
                        }
                    }
                    report(unit.shotIds)
                    self?.unitTasks[taskId] = nil
                }
            }

            guard inFlight > 0 else { break }  // nothing startable and nothing running
            if let finishedIds = await completionIterator.next() {
                inFlight -= 1
                guard runID == id else { continue }
                settled.formUnion(finishedIds)
                generatingShotIds.subtract(finishedIds)
                if finishedIds.contains(currentUnitShotIds.first ?? "") { currentUnitShotIds = [] }
                for shotId in finishedIds {
                    let shot = editor?.shotPlan?.shot(id: shotId)
                    let operation = shot?.activeProductionOperationId.flatMap { editor?.productionOperation(id: $0) }
                    if shot?.status == .placed && (operation == nil || (operation?.stage == .placed && operation?.failureReason == nil)) {
                        completedCount += 1
                    } else {
                        failedCount += 1
                    }
                }
            }
        }
        // Drain in-flight units after a cancel/pause-break so state stays consistent.
        while inFlight > 0 {
            guard let finishedIds = await completionIterator.next() else { break }
            inFlight -= 1
            if runID == id { generatingShotIds.subtract(finishedIds) }
        }
    }

    // MARK: - Multi-shot unit production

    /// Generates a grouped window as ONE video (Seedance native multi-shot,
    /// `Lens switch.` beats), then places one timeline clip PER SHOT, each
    /// trimmed to its beat's slice of the single asset — the editor still
    /// shows and manages individual shots.
    private func produceUnit(_ unit: MultiShotPlanner.Unit, options: Options, runId: UUID) async {
        guard acceptsSubmissions(runId: runId) else { return }
        guard let editor, let plan = editor.shotPlan else { return }
        let window = unit.shotIds.compactMap { plan.shot(id: $0) }
        guard window.count == unit.shotIds.count, window.count >= 2 else {
            // Plan changed since queuing — fall back to singles.
            for id in unit.shotIds { await produceOne(shotId: id, options: options, runId: runId) }
            return
        }
        let label = "\(window.first?.slug ?? "S?")–\(window.last?.slug ?? "S?")"

        guard let route = routeUnit(window, plan: plan, editor: editor) else {
            postNotice("\(label): no reference-capable model available for a grouped generation — rendering shots individually.")
            for id in unit.shotIds { await produceOne(shotId: id, options: options, runId: runId) }
            return
        }

        if route.model.id.lowercased().contains("seedance"),
           !ModelPreferences.shared.seedanceConsentGranted {
            postNotice("\(label): Seedance requires consent (Settings → Models) — rendering shots individually.")
            for id in unit.shotIds { await produceOne(shotId: id, options: options, runId: runId) }
            return
        }

        // Snap the summed duration to the model's ladder. Snapping DOWN would
        // cut off the last beat, so require a rung >= the sum; bail to singles
        // when the ladder can't hold the window.
        let plannedSeconds = window.reduce(0.0) { $0 + $1.durationSeconds }
        let requested = Int(plannedSeconds.rounded(.up))
        let duration: Int
        if route.model.durations.isEmpty {
            duration = max(1, requested)
        } else if let rung = route.model.durations.sorted().first(where: { $0 >= requested }) {
            duration = rung
        } else {
            postNotice("\(label): \(requested)s window exceeds \(route.model.displayName)'s ladder — rendering shots individually.")
            for id in unit.shotIds { await produceOne(shotId: id, options: options, runId: runId) }
            return
        }

        // Snap the plan aspect to the model's list the same way produceOne's
        // reconcile() does — but never silently: the swap is announced below.
        let aspect = route.model.aspectRatios.contains(plan.aspectRatio)
            ? plan.aspectRatio
            : (route.model.aspectRatios.first ?? plan.aspectRatio)
        let resolution = route.model.resolutions?.contains(plan.resolution) == true ? plan.resolution : route.model.resolutions?.first
        if let err = route.model.validate(duration: duration, aspectRatio: aspect, resolution: resolution) {
            postNotice("\(label): \(err) — rendering shots individually.")
            for id in unit.shotIds { await produceOne(shotId: id, options: options, runId: runId) }
            return
        }
        if aspect != plan.aspectRatio {
            postNotice("⚠️ \(label): \(route.model.displayName) doesn't offer \(plan.aspectRatio) — generating \(aspect) instead.")
        }

        guard let operationId = await startOperation(shotIds: unit.shotIds, options: options, runId: runId) else { return }
        defer { settleUnfinishedOperation(operationId) }
        for shot in window { editor.setShotStatus(id: shot.id, .generating) }
        let quoted = await quote(model: route.model.id, duration: duration, resolution: resolution, aspect: aspect)
        guard operationIsCurrent(operationId) else { return }
        let costNote = quoted.map { String(format: " (~$%.2f)", $0) } ?? ""
        postNotice("Generating \(label) with \(route.model.displayName) as one multi-shot take: \(unit.reason), \(duration)s @ \(aspect)\(costNote).")

        var genInput = GenerationInput(
            prompt: MultiShotPlanner.multiShotPrompt(window: window, plan: plan, slotPlan: route.slotPlan),
            model: route.model.id, duration: duration,
            aspectRatio: aspect, resolution: resolution
        )
        do {
            genInput.storyboardBindings = try editor.storyboardBindings(for: window, plan: plan)
        } catch {
            for shot in window { failShot(shot.id, reason: error.localizedDescription) }
            return
        }
        genInput.createdAt = Date()
        if VideoModelCapabilities.supportsNegativePrompt(id: route.model.id) {
            genInput.negativePrompt = ShotPromptBuilder.negativePrompt(forWindow: window)
        }
        if let seed = plan.seed, VideoModelCapabilities.supportsSeed(id: route.model.id) {
            genInput.seed = seed
        }

        var lastFailure = "generation failed"
        for attempt in 0...max(0, options.maxRetries) {
            guard operationIsCurrent(operationId) else { return }
            let asset = await submitAndAwait(
                genInput: genInput, model: route.model, inputAssets: route.inputAssets,
                placeholderDuration: Double(duration), generateAudio: true, editor: editor, operationId: operationId
            )
            guard operationIsCurrent(operationId) else { return }

            guard let asset, asset.id == editor.productionOperation(id: operationId)?.attempts.last?.placeholderId else {
                lastFailure = editor.productionOperation(id: operationId)?.attempts.last?.failureReason ?? "generation failed"
                editor.recordProductionAttemptFailure(operationId, reason: lastFailure)
                if attempt < options.maxRetries {
                    let delay = options.retryBaseDelay * Double(attempt + 1)
                    postNotice("\(label) failed — retrying in \(Int(delay))s (attempt \(attempt + 2)).")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                break
            }

            let outcome = await finalizeAttempt(operationId: operationId, runId: runId)
            guard acceptsSubmissions(runId: runId) else { return }
            if outcome == .placed {
                if let quoted { runningUSD += quoted }
                postNotice("Placed \(label) on the timeline as \(window.count) clips from one take.")
                return
            }
            lastFailure = finalizationFailure(operationId)
            lastError = lastFailure
            guard operationIsCurrent(operationId) else { return }
            editor.recordProductionAttemptFailure(operationId, reason: lastFailure)
            if outcome == .rejected && attempt < options.maxRetries {
                try? await Task.sleep(for: .seconds(options.retryBaseDelay))
                continue
            }
            break
        }

        for shot in window { failShot(shot.id, reason: lastFailure) }
    }

    /// Routes a grouped window: pure reference mode on a reference-capable
    /// model (union of the window's character + location references, capped
    /// to the model's budget), never frames. Voice refs are per-shot audio
    /// and don't attach to grouped units.
    private func routeUnit(_ window: [Shot], plan: ShotPlan, editor: EditorViewModel) -> Route? {
        let enabled = VideoModelConfig.allModels.filter { ModelPreferences.shared.isEnabled($0.id) }
        guard !enabled.isEmpty else { return nil }

        // Same tiered stack as single-shot route(): identity (one primary per
        // character) → the window's first storyboard panel → location angle
        // ladder → extra character angles, deduped, overflow dropping from the
        // bottom tier up (harness reference-slots policy).
        var seen = Set<String>()
        func ready(_ assetIds: [String]) -> [MediaAsset] {
            assetIds.compactMap { aid in
                guard !seen.contains(aid),
                      let a = editor.mediaAssets.first(where: { $0.id == aid }),
                      a.type == .image, ToolExecutor.isReady(a, editor: editor) else { return nil }
                seen.insert(aid)
                return a
            }
        }
        var identityRefs: [MediaAsset] = []
        var extraCharRefs: [MediaAsset] = []
        for cid in MultiShotPlanner.orderedUniqueCharacterIds(window) {
            guard let c = plan.character(id: cid) else { continue }
            let charRefs = ready(c.activeReferenceAssetIds)
            if let primary = charRefs.first { identityRefs.append(primary) }
            extraCharRefs.append(contentsOf: charRefs.dropFirst())
        }
        var panelRef: MediaAsset?
        if let sbId = window.first(where: { $0.storyboardAssetId != nil })?.storyboardAssetId,
           !seen.contains(sbId),
           let panel = editor.mediaAssets.first(where: { $0.id == sbId }),
           panel.type == .image, ToolExecutor.isReady(panel, editor: editor) {
            panelRef = panel
            seen.insert(sbId)
        }
        var locationRefs: [MediaAsset] = []
        if let lid = window.first?.locationIds.first, let l = plan.location(id: lid) {
            locationRefs = ready(l.activeReferenceAssetIds)
        }
        guard !identityRefs.isEmpty || panelRef != nil || !locationRefs.isEmpty else { return nil }

        let defaultModel = plan.defaultModel.flatMap { id in enabled.first { $0.id == id } }
        if plan.defaultModel != nil, defaultModel == nil { return nil }
        if let defaultModel, defaultModel.supportsFirstFrame || VideoModelCapabilities.wantsSimplePrompt(id: defaultModel.id) { return nil }
        let r2v = defaultModel ?? Self.preferredModel(in: enabled) {
            $0.requiresReferenceImage && !$0.requiresSourceVideo && $0.maxReferenceImages > 0
        }
        guard let model = r2v, model.requiresReferenceImage, !model.requiresSourceVideo, model.maxReferenceImages > 0,
              !VideoModelCapabilities.wantsSimplePrompt(id: model.id) else { return nil }

        let budget = max(1, model.maxReferenceImages)
        // @Image-tag models (Seedance R2V): bind refs to @ImageN slots so every
        // beat's identity/blocking/location resolves to a known slot.
        if imageTagBindingActive(model) {
            let sp = buildSlotPlan(forUnit: window, plan: plan, editor: editor, budget: budget)
            if !sp.isEmpty {
                let ia = VideoGenerationSubmission.InputAssets(imageRefs: sp.imageRefs)
                if ia.validate(for: model) == nil {
                    let plates = sp.slots.filter { $0.kind == .storyboard }.count
                    let plateNote = plates > 1 ? ", \(plates) beat plates" : ""
                    return Route(model: model, inputAssets: ia,
                                 note: "multi-shot reference-to-video (@ImageN slots ×\(sp.slots.count)\(plateNote))",
                                 slotPlan: sp)
                }
            }
        }
        var capped = identityRefs
        if let panelRef { capped.append(panelRef) }
        if capped.count > budget {
            capped = Array(capped.prefix(budget))
        } else {
            capped.append(contentsOf: locationRefs.prefix(max(0, budget - capped.count)))
            capped.append(contentsOf: extraCharRefs.prefix(max(0, budget - capped.count)))
        }
        let ia = VideoGenerationSubmission.InputAssets(imageRefs: capped)
        guard ia.validate(for: model) == nil else { return nil }
        return Route(model: model, inputAssets: ia, note: "multi-shot reference-to-video (\(capped.count) refs\(panelRef != nil ? " incl. storyboard framing" : ""))")
    }

    // MARK: - Per-shot production

    private func produceOne(shotId: String, options: Options, runId: UUID) async {
        guard acceptsSubmissions(runId: runId) else { return }
        guard let editor, let plan = editor.shotPlan, let shot = plan.shot(id: shotId) else { return }
        let label = shot.slug ?? "shot \(shotId.prefix(6))"
        guard let operationId = await startOperation(shotIds: [shotId], options: options, runId: runId) else { return }
        defer { settleUnfinishedOperation(operationId) }

        // Frame chaining: if the previous shot transitions by dissolve/match-cut, seed this
        // shot from its last frame for visual continuity (needs an image-to-video model).
        let chainFrame = await chainStartFrame(for: shotId, plan: plan, editor: editor)
        guard operationIsCurrent(operationId) else { return }

        let route: Route
        do {
            route = try self.route(shot, plan: plan, editor: editor, chainFrame: chainFrame, availableModels: availableModels?())
        } catch {
            failShot(shotId, reason: error.localizedDescription)
            return
        }

        // Seedance requires explicit user consent before a paid face-bearing job.
        if route.model.id.lowercased().contains("seedance"),
           !ModelPreferences.shared.seedanceConsentGranted {
            failShot(shotId, reason: "Seedance requires consent — enable it in Settings → Models, then re-run.")
            return
        }

        if let error = CameraTrajectory.validate(shot.cameraTrajectory, modelID: route.model.id) {
            failShot(shotId, reason: error)
            return
        }
        let (duration, aspect, resolution) = reconcile(shot: shot, model: route.model, plan: plan)
        if let err = route.model.validate(duration: duration, aspectRatio: aspect, resolution: resolution) {
            failShot(shotId, reason: err)
            return
        }
        // A silent aspect swap was invisible (21:9 plans rendered 16:9 with no
        // trace, 2026-08-07) — say it loudly before money is spent.
        if aspect != plan.aspectRatio {
            postNotice("⚠️ \(label): \(route.model.displayName) doesn't offer \(plan.aspectRatio) — generating \(aspect) instead. To keep \(plan.aspectRatio), set a modelOverride that supports it (check list_models).")
        }
        // Never shorten picture timing to fit a provider duration ladder.
        if let longest = route.model.durations.max(), shot.durationSeconds > Double(longest) {
            failShot(shotId, reason: "Planned \(Int(shot.durationSeconds))s but \(route.model.displayName) generates at most \(longest)s. Split the shot (shot inspector → Split) instead of truncating.")
            return
        }

        do { _ = try editor.productionClip(for: shot) }
        catch { failShot(shotId, reason: error.localizedDescription); return }

        editor.setShotStatus(id: shotId, .generating)
        let quoted = await quote(model: route.model.id, duration: duration, resolution: resolution, aspect: aspect)
        guard operationIsCurrent(operationId) else { return }
        let costNote = quoted.map { String(format: " (~$%.2f)", $0) } ?? ""
        // Always name the model — "is Seedance even being used?" must be
        // answerable from the chat transcript alone.
        postNotice("Generating \(label) with \(route.model.displayName): \(route.note), \(duration)s @ \(aspect)\(costNote).")

        var genInput = GenerationInput(
            prompt: ShotPromptBuilder.videoPrompt(for: shot, plan: plan, slotPlan: route.slotPlan, model: route.model.id),
            model: route.model.id, duration: duration,
            aspectRatio: aspect, resolution: resolution
        )
        genInput.createdAt = Date()
        // Rule-33: suppress baked-in music/speech on non-full shots, only on
        // models that accept a negative_prompt.
        if VideoModelCapabilities.supportsNegativePrompt(id: route.model.id) {
            genInput.negativePrompt = ShotPromptBuilder.negativePrompt(for: shot)
        }
        genInput.cameraTrajectory = shot.cameraTrajectory
        do {
            genInput.storyboardBindings = try editor.storyboardBindings(for: [shot], plan: plan)
        } catch {
            failShot(shotId, reason: error.localizedDescription)
            return
        }
        // Reproducibility: lock the series seed onto seed-capable families so the
        // recipe replays; nil leaves the queue to pick one (current behavior).
        if let seed = plan.seed, VideoModelCapabilities.supportsSeed(id: route.model.id) {
            genInput.seed = seed
        }
        let generateAudio = ShotPromptBuilder.generateNativeAudio(for: shot)

        var lastFailure = "generation failed"
        for attempt in 0...max(0, options.maxRetries) {
            guard operationIsCurrent(operationId) else { return }
            let asset = await submitAndAwait(
                genInput: genInput, model: route.model, inputAssets: route.inputAssets,
                placeholderDuration: Double(duration), generateAudio: generateAudio, editor: editor, operationId: operationId,
                videoBudget: options.videoBudget
            )

            guard operationIsCurrent(operationId) else { return }

            guard let asset, asset.id == editor.productionOperation(id: operationId)?.attempts.last?.placeholderId else {
                lastFailure = editor.productionOperation(id: operationId)?.attempts.last?.failureReason ?? "generation failed"
                editor.recordProductionAttemptFailure(operationId, reason: lastFailure)
                if attempt < options.maxRetries {
                    let delay = options.retryBaseDelay * Double(attempt + 1)
                    postNotice("\(label) failed — retrying in \(Int(delay))s (attempt \(attempt + 2)).")
                    try? await Task.sleep(for: .seconds(delay))
                    continue
                }
                break
            }

            let outcome = await finalizeAttempt(operationId: operationId, runId: runId)
            guard acceptsSubmissions(runId: runId) else { return }
            if outcome == .placed {
                if let quoted { runningUSD += quoted }
                postNotice("Placed \(label) on the timeline.")
                return
            }
            lastFailure = finalizationFailure(operationId)
            lastError = lastFailure
            guard operationIsCurrent(operationId) else { return }
            editor.recordProductionAttemptFailure(operationId, reason: lastFailure)
            if outcome == .rejected && attempt < options.maxRetries {
                try? await Task.sleep(for: .seconds(options.retryBaseDelay))
                continue
            }
            break
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
        editor: EditorViewModel,
        operationId: String,
        videoBudget: VideoGenerationBudget? = nil
    ) async -> MediaAsset? {
        let input: GenerationInput
        do {
            let recipe = VideoGenerationSubmission.make(genInput: genInput, model: model, inputAssets: inputAssets,
                                                       placeholderDuration: placeholderDuration, generateAudio: generateAudio).genInput
            input = try editor.beginProductionAttempt(operationId: operationId, recipe: recipe)
            try await editor.checkpointProductionState()
            try editor.validateProductionAttempt(input)
        } catch {
            if operationIsCurrent(operationId) {
                editor.mutateProductionOperation(operationId) { $0.stage = .failed; $0.failureReason = error.localizedDescription }
                for destination in editor.productionOperation(id: operationId)?.destinations ?? [] {
                    failShot(destination.shotId, reason: error.localizedDescription)
                }
            }
            return nil
        }
        if let generateVideo { return await generateVideo(input) }
        let awaitKey = UUID()
        defer { interruptAwaits[awaitKey] = nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<MediaAsset?, Never>) in
            let once = FirstOnlyFlag()
            interruptAwaits[awaitKey] = { if once.fire() { continuation.resume(returning: nil) } }
            let submission = VideoGenerationSubmission.make(
                genInput: input,
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
                videoBudget: videoBudget,
                onComplete: { asset in if once.fire() { continuation.resume(returning: asset) } },
                onFailure: { if once.fire() { continuation.resume(returning: nil) } }
            )
        }
    }

    func runAutoQA(shotId: String, asset: MediaAsset, plan: ShotPlan, operationId: String, runId: UUID, sourceRange: ShotSourceRange, qaModel: String?) async -> VisionQA.Result? {
        guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
        if let evaluateVideoQA {
            editor?.mutateProductionOperation(operationId) { $0.stage = .reviewing }
            let result = await evaluateVideoQA(shotId, asset, plan, sourceRange)
            guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
            if let result { recordQAResult(result, shotId: shotId) }
            return result
        }
        guard let editor,
              let api = VeniceAPI.fromKeychain(),
              let model = qaModel,
              let url = editor.mediaResolver.resolveURL(for: asset.id),
              let shot = editor.shotPlan?.shot(id: shotId) else { return nil }
        var frames = await VisionQA.videoFrames(url: url, count: 3, sourceRange: sourceRange)
        guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
        guard !frames.isEmpty else { return nil }
        // Spatial drift guard (harness qa-storyboard): append the nearest earlier
        // same-location frame so the reviewer can catch mirrored geography /
        // side-swaps against real prior coverage, not the stated layout alone.
        let priorFrame = await priorSameLocationQAFrame(for: shot, plan: plan, editor: editor)
        guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
        if let priorFrame { frames.append(priorFrame) }
        let rubric = ProductionOrchestrator.qaRubric(for: shot, plan: plan, comparePriorPanel: priorFrame != nil)
        let result: VisionQA.Result
        editor.mutateProductionOperation(operationId) { $0.stage = .reviewing }
        do {
            result = try await VisionQA.evaluate(images: frames, rubric: rubric, api: api, model: model)
        } catch {
            guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
            // Errored QA is NOT a silent pass (harness rule 46b): stamp the shot
            // UNCHECKED so no auto-approve path reads the missing verdict as "all
            // clear". Returning nil keeps the retry path from treating it as a
            // failed take (an API hiccup shouldn't burn a paid regeneration).
            editor.mutateShotPlan(actionName: "QA Shot") { plan in
                guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
                plan.shots[idx].qaSummary = "QA errored: \(error.localizedDescription) — shot is UNCHECKED"
            }
            return nil
        }
        guard finalizationIsCurrent(operationId, runId: runId) else { return nil }
        recordQAResult(result, shotId: shotId)
        return result
    }

    private func recordQAResult(_ result: VisionQA.Result, shotId: String) {
        guard let editor else { return }
        editor.undoManager?.beginUndoGrouping()
        defer { editor.undoManager?.endUndoGrouping() }
        editor.mutateShotPlan(actionName: "QA Shot") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            plan.shots[idx].qaSummary = result.summary
            if let last = plan.shots[idx].takes.indices.last {
                plan.shots[idx].takes[last].qaScore = result.score
                plan.shots[idx].takes[last].qaSummary = result.summary
            }
        }
    }

    /// A single JPEG frame of the nearest earlier shot (plan order) that shares a
    /// location with `shot` and has a ready panel or video — the reference the QA
    /// reviewer compares against for spatial continuity. Nil when there's no prior
    /// same-location coverage yet.
    private func priorSameLocationQAFrame(for shot: Shot, plan: ShotPlan, editor: EditorViewModel) async -> Data? {
        struct Candidate { let type: ClipType; let url: URL }
        let candidate: Candidate? = await MainActor.run {
            guard let idx = plan.shots.firstIndex(where: { $0.id == shot.id }), idx > 0 else { return nil }
            let locs = Set(shot.locationIds)
            guard !locs.isEmpty else { return nil }
            for prior in plan.shots[..<idx].reversed() {
                guard !locs.isDisjoint(with: prior.locationIds) else { continue }
                guard let assetId = prior.storyboardAssetId ?? prior.videoAssetId,
                      let asset = editor.mediaAssets.first(where: { $0.id == assetId }),
                      ToolExecutor.isReady(asset, editor: editor),
                      let url = editor.mediaResolver.resolveURL(for: asset.id) else { continue }
                return Candidate(type: asset.type, url: url)
            }
            return nil
        }
        guard let candidate else { return nil }
        switch candidate.type {
        case .image: return VisionQA.imageJPEG(url: candidate.url)
        case .video: return await VisionQA.videoFrames(url: candidate.url, count: 1).first
        default: return nil
        }
    }

    // MARK: - Plan mutations

    func recordTake(shotId: String, asset: MediaAsset, model: String, unitId: String? = nil, sourceRange: ShotSourceRange? = nil, operationId: String) {
        // The produced asset carries the fully-resolved submitted call (final
        // prompt, reference asset ids, negative prompt, seed) — snapshot it as the
        // take's replayable recipe (harness rule 39).
        let recipe = asset.generationInput
        guard let editor, let takeId = editor.productionOperation(id: operationId)?.attempts.last?.takeIds[shotId],
              editor.shot(id: shotId)?.takes.contains(where: { $0.id == takeId }) != true else { return }
        editor.undoManager?.beginUndoGrouping()
        defer { editor.undoManager?.endUndoGrouping() }
        editor.mutateShotPlan(actionName: "Shot Take") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == shotId }) else { return }
            guard !plan.shots[idx].takes.contains(where: { $0.id == takeId }) else { return }
            var take = ShotTake(
                id: takeId, videoAssetId: asset.id, model: model, recipe: recipe, seed: recipe?.seed
            )
            take.productionUnitId = unitId
            take.sourceRange = sourceRange
            plan.shots[idx].takes.append(take)
            plan.shots[idx].failureReason = nil
        }
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

    /// The multi-shot window budget for the routed default family: 30s on
    /// Seedance 2.5 (harness rules 50/51), 15s otherwise. Resolves the would-be
    /// R2V model the same way `route()`/`routeUnit()` do, so the planner's window
    /// cap matches what the generator will actually accept.
    private func windowBudget(plan: ShotPlan) -> MultiShotPlanner.WindowBudget {
        let enabled = VideoModelConfig.allModels.filter { ModelPreferences.shared.isEnabled($0.id) }
        func isR2V(_ m: VideoModelConfig) -> Bool {
            m.requiresReferenceImage && !m.requiresSourceVideo && m.maxReferenceImages > 0
        }
        let r2v = plan.defaultModel.flatMap { id in enabled.first { $0.id == id } }.flatMap { isR2V($0) ? $0 : nil }
            ?? Self.preferredModel(in: enabled, where: isR2V)
        if let r2v, r2v.id.lowercased().contains("seedance-2-5") {
            return .seedance25
        }
        return .standard
    }

    /// Family preferred when no explicit default/override names a model —
    /// Seedance 2.5 (Jordan, 2026-08-07): same three lane variants as 2.0
    /// (text-to-video / image-to-video / reference-to-video) with 4-30s
    /// durations, 21:9, and a 30-image reference budget. "Auto" in the
    /// Production panel resolves through this before falling back to
    /// first-enabled.
    static let preferredAutoFamily = "seedance-2-5"

    /// First enabled model matching `predicate`, preferring the
    /// `preferredAutoFamily` lane variant when present.
    static func preferredModel(
        in enabled: [VideoModelConfig],
        where predicate: (VideoModelConfig) -> Bool
    ) -> VideoModelConfig? {
        let matching = enabled.filter(predicate)
        return matching.first { $0.id.lowercased().contains(preferredAutoFamily) } ?? matching.first
    }

    struct Route {
        let model: VideoModelConfig
        let inputAssets: VideoGenerationSubmission.InputAssets
        let note: String
        /// Non-nil on @Image-tag models with slot binding active: the prompt is
        /// built with @ImageN bindings and the refs come from this plan's order.
        var slotPlan: ReferenceSlots.Plan?
    }

    /// @Image-tag slot binding is applied only to the probe-verified Seedance
    /// R2V family, and only when the user hasn't turned it off. Other tag models
    /// (Grok/MiniMax/HappyHorse) keep the name-in-prose path until probed.
    private func imageTagBindingActive(_ model: VideoModelConfig) -> Bool {
        ModelPreferences.shared.imageSlotBindingEnabled
            && VideoModelCapabilities.usesImageTags(id: model.id)
            && model.id.lowercased().contains("seedance")
    }

    /// Builds the ordered @ImageN slot plan for a single shot (same tiering as
    /// the untagged stack: character primaries → storyboard panel → location
    /// angles → extra character angles), deduping repeats, capped to `budget`.
    private func buildSlotPlan(for shot: Shot, plan: ShotPlan, editor: EditorViewModel, budget: Int) -> ReferenceSlots.Plan {
        var seen = Set<String>()
        func ready(_ assetIds: [String]) -> [MediaAsset] {
            assetIds.compactMap { aid in
                guard !seen.contains(aid),
                      let a = editor.mediaAssets.first(where: { $0.id == aid }),
                      a.type == .image, ToolExecutor.isReady(a, editor: editor) else { return nil }
                seen.insert(aid)
                return a
            }
        }
        var primaries: [ReferenceSlots.Candidate] = []
        var angles: [ReferenceSlots.Candidate] = []
        for cid in shot.characterIds {
            guard let c = plan.character(id: cid) else { continue }
            let refs = ready(c.activeReferenceAssetIds)
            if let primary = refs.first {
                primaries.append(.init(kind: .characterPrimary, asset: primary, label: c.name, roleClause: ""))
            }
            for a in refs.dropFirst() {
                angles.append(.init(kind: .characterAngle, asset: a, label: c.name,
                                    roleClause: ReferenceSlots.characterAngleRoleClause(name: c.name)))
            }
        }
        var storyboard: [ReferenceSlots.Candidate] = []
        if let sbId = shot.storyboardAssetId, !seen.contains(sbId),
           let panel = editor.mediaAssets.first(where: { $0.id == sbId }),
           panel.type == .image, ToolExecutor.isReady(panel, editor: editor) {
            seen.insert(sbId)
            storyboard.append(.init(kind: .storyboard, asset: panel, label: "panel", roleClause: ReferenceSlots.storyboardRoleClause))
        }
        var location: [ReferenceSlots.Candidate] = []
        for lid in shot.locationIds {
            guard let l = plan.location(id: lid) else { continue }
            for (i, a) in ready(l.activeReferenceAssetIds).enumerated() {
                location.append(.init(kind: .location, asset: a, label: l.name,
                                      roleClause: ReferenceSlots.locationRoleClause(name: l.name, angleIndex: i)))
            }
        }
        return ReferenceSlots.build(primaries: primaries, storyboard: storyboard, location: location, characterAngles: angles, budget: budget)
    }

    /// Same as `buildSlotPlan(for:)` but for a grouped window: character
    /// primaries across the window's unique cast, the window's first panel,
    /// then the shared location's angles.
    private func buildSlotPlan(forUnit window: [Shot], plan: ShotPlan, editor: EditorViewModel, budget: Int) -> ReferenceSlots.Plan {
        var seen = Set<String>()
        func ready(_ assetIds: [String]) -> [MediaAsset] {
            assetIds.compactMap { aid in
                guard !seen.contains(aid),
                      let a = editor.mediaAssets.first(where: { $0.id == aid }),
                      a.type == .image, ToolExecutor.isReady(a, editor: editor) else { return nil }
                seen.insert(aid)
                return a
            }
        }
        var primaries: [ReferenceSlots.Candidate] = []
        var angles: [ReferenceSlots.Candidate] = []
        for cid in MultiShotPlanner.orderedUniqueCharacterIds(window) {
            guard let c = plan.character(id: cid) else { continue }
            let refs = ready(c.activeReferenceAssetIds)
            if let primary = refs.first {
                primaries.append(.init(kind: .characterPrimary, asset: primary, label: c.name, roleClause: ""))
            }
            for a in refs.dropFirst() {
                angles.append(.init(kind: .characterAngle, asset: a, label: c.name,
                                    roleClause: ReferenceSlots.characterAngleRoleClause(name: c.name)))
            }
        }
        // Per-beat blocking plates (harness rule 42): every beat with a ready
        // panel contributes its OWN plate so beats 2+ have a composition anchor,
        // not just the window's first. Plates sit right after primaries in fill
        // order, so overflow drops the bottom tiers (angles, then location) before
        // any plate.
        var storyboard: [ReferenceSlots.Candidate] = []
        for beat in window {
            guard let sbId = beat.storyboardAssetId, !seen.contains(sbId),
                  let panel = editor.mediaAssets.first(where: { $0.id == sbId }),
                  panel.type == .image, ToolExecutor.isReady(panel, editor: editor) else { continue }
            seen.insert(sbId)
            storyboard.append(.init(kind: .storyboard, asset: panel, label: beat.slug ?? "panel",
                                    roleClause: ReferenceSlots.storyboardBeatRoleClause(slug: beat.slug)))
        }
        var location: [ReferenceSlots.Candidate] = []
        if let lid = window.first?.locationIds.first, let l = plan.location(id: lid) {
            for (i, a) in ready(l.activeReferenceAssetIds).enumerated() {
                location.append(.init(kind: .location, asset: a, label: l.name,
                                      roleClause: ReferenceSlots.locationRoleClause(name: l.name, angleIndex: i)))
            }
        }
        return ReferenceSlots.build(primaries: primaries, storyboard: storyboard, location: location, characterAngles: angles, budget: budget)
    }

    /// Lip-sync router hook (harness rule 32): whether this shot, on this model,
    /// is a candidate to TTS its on-screen line and attach it as `audio_url`
    /// instead of the timbre-only voice donor. Gated by the default-off
    /// `lipSyncEnabled` flag; the generation path is wired incrementally behind it.
    @MainActor
    func lipSyncEligible(shot: Shot, plan: ShotPlan, model: VideoModelConfig) -> Bool {
        guard ModelPreferences.shared.lipSyncEnabled else { return false }
        let lines = shot.onScreenDialogue.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return false }
        let speakerHasVoice = lines.contains { line in
            guard let cid = line.characterId, let c = plan.character(id: cid) else { return false }
            return c.lockedVoiceId != nil
        }
        return LipSync.eligible(
            hasOnScreenLine: true,
            speakerHasLockedVoice: speakerHasVoice,
            modelAcceptsAudioURL: VideoModelCapabilities.audioInputCapable(id: model.id)
        )
    }

    func route(
        _ shot: Shot, plan: ShotPlan, editor: EditorViewModel,
        chainFrame: MediaAsset? = nil, availableModels: [VideoModelConfig]? = nil
    ) throws -> Route {
        _ = try editor.requireApprovedStoryboard(for: shot, plan: plan)
        let enabled = availableModels ?? VideoModelConfig.allModels.filter { ModelPreferences.shared.isEnabled($0.id) }
        let selectedID = shot.modelOverride ?? plan.defaultModel
        let selected = try ProductionModelSelection.resolve(selectedID, in: enabled)
        guard !enabled.isEmpty else { throw ToolError("No enabled video model available. Refresh Models in Settings.") }

        // Tiered reference stack (ports the harness reference-slots allocator):
        //   1. Character identity refs (primary — one per character)  PROTECTED
        //   2. The shot's storyboard panel (per-shot framing/blocking) PROTECTED
        //   3. Location angle ladder (wide → medium → detail)
        //   4. Extra character angles
        // Overflow drops tier 4 first, then tier 3 from the detail end;
        // tiers 1-2 are dropped only if they alone exceed the model budget.
        func ready(_ assetIds: [String]) -> [MediaAsset] {
            assetIds.compactMap { aid in
                guard let a = editor.mediaAssets.first(where: { $0.id == aid }),
                      a.type == .image, ToolExecutor.isReady(a, editor: editor) else { return nil }
                return a
            }
        }
        var identityRefs: [MediaAsset] = []   // tier 1
        var extraCharRefs: [MediaAsset] = []  // tier 4
        for cid in shot.characterIds {
            guard let c = plan.character(id: cid) else { continue }
            let charRefs = ready(c.activeReferenceAssetIds)
            if let primary = charRefs.first { identityRefs.append(primary) }
            extraCharRefs.append(contentsOf: charRefs.dropFirst())
        }
        // Tier 2: the shot's own storyboard panel — per-shot composition anchor
        // (the raw location plate fed to every shot made all takes share one
        // fixed background composition; 2026-08-06 run).
        var panelRef: MediaAsset?
        if let sbId = shot.storyboardAssetId,
           let panel = editor.mediaAssets.first(where: { $0.id == sbId }),
           panel.type == .image, ToolExecutor.isReady(panel, editor: editor) {
            panelRef = panel
        }
        // Tier 3: location angle ladder (locked angle first, others follow).
        var locationRefs: [MediaAsset] = []
        for lid in shot.locationIds {
            guard let l = plan.location(id: lid) else { continue }
            locationRefs.append(contentsOf: ready(l.activeReferenceAssetIds))
        }

        func tieredRefs(budget: Int) -> [MediaAsset] {
            var out = identityRefs
            if let panelRef { out.append(panelRef) }
            if out.count > budget { return Array(out.prefix(budget)) }
            out.append(contentsOf: locationRefs.prefix(max(0, budget - out.count)))
            out.append(contentsOf: extraCharRefs.prefix(max(0, budget - out.count)))
            return out
        }
        let usedStoryboard = panelRef != nil
        let refs = tieredRefs(budget: Int.max)  // non-empty check below; capped per model at route time

        // Explicit shot audio ref wins; else the first attached character with a
        // locked voice reference (when the shot hasn't opted out). Only attached
        // to models that accept audio input — never risks a queue rejection.
        let audioRef = voiceAudioReference(for: shot, plan: plan, editor: editor)
        func audioRefs(for model: VideoModelConfig) -> [MediaAsset] {
            guard let audioRef, model.maxReferenceAudios > 0 else { return [] }
            return [audioRef]
        }

        if let selected, selected.supportsFirstFrame || !selected.requiresReferenceImage {
            if !selected.supportsFirstFrame, panelRef != nil || chainFrame != nil || !refs.isEmpty {
                throw ToolError("\(selected.displayName) cannot use this shot's visual inputs. Select I2V for the storyboard or R2V for references; no inputs were silently discarded.")
            }
            let frames = selected.supportsFirstFrame ? [panelRef ?? chainFrame].compactMap { $0 } : []
            let inputs = VideoGenerationSubmission.InputAssets(frames: frames, audioRefs: audioRefs(for: selected))
            if let error = inputs.validate(for: selected) { throw ToolError(error) }
            return Route(model: selected, inputAssets: inputs, note: frames.isEmpty ? "text-to-video" : "image-to-video (storyboard or chained frame)")
        }

        if selected == nil, let frame = panelRef ?? chainFrame {
            guard let model = Self.preferredModel(in: enabled, where: { $0.supportsFirstFrame && !$0.requiresSourceVideo }) else {
                throw ToolError("No enabled image-to-video model accepts the storyboard frame. Select an available I2V model.")
            }
            let inputs = VideoGenerationSubmission.InputAssets(frames: [frame], audioRefs: audioRefs(for: model))
            if let error = inputs.validate(for: model) { throw ToolError(error) }
            return Route(model: model, inputAssets: inputs, note: "image-to-video (storyboard or chained frame)")
        }

        if !refs.isEmpty {
            let r2v = selected ?? Self.preferredModel(in: enabled) {
                $0.requiresReferenceImage && !$0.requiresSourceVideo && $0.maxReferenceImages > 0
            }
            if let model = r2v {
                let audio = audioRefs(for: model)
                // @Image-tag models (Seedance R2V): bind each reference to an
                // @ImageN slot so identity/role can't be mis-attributed. Refs
                // come from the plan's order (same tiering as the untagged path).
                if imageTagBindingActive(model) {
                    let sp = buildSlotPlan(for: shot, plan: plan, editor: editor, budget: max(1, model.maxReferenceImages))
                    if !sp.isEmpty {
                        let ia = VideoGenerationSubmission.InputAssets(imageRefs: sp.imageRefs, audioRefs: audio)
                        if ia.validate(for: model) == nil {
                            let audioNote = audio.isEmpty ? "" : " + voice ref"
                            return Route(model: model, inputAssets: ia,
                                         note: "reference-to-video (@ImageN slots ×\(sp.slots.count)\(audioNote))",
                                         slotPlan: sp)
                        }
                    }
                }
                // Tier-aware cap: protects identity + panel, then location
                // angles, then extra character angles (harness overflow policy).
                let capped = tieredRefs(budget: max(1, model.maxReferenceImages))
                let ia = VideoGenerationSubmission.InputAssets(imageRefs: capped, audioRefs: audio)
                if ia.validate(for: model) == nil {
                    let audioNote = audio.isEmpty ? "" : " + voice ref"
                    let sbNote = usedStoryboard ? " incl. storyboard framing" : ""
                    return Route(model: model, inputAssets: ia, note: "reference-to-video (\(capped.count) ref\(capped.count == 1 ? "" : "s")\(sbNote)\(audioNote))")
                }
            }
        }

        if let selected {
            throw ToolError("\(selected.displayName) requires ready reference images. Generate or select references before producing this shot.")
        }
        guard refs.isEmpty else {
            throw ToolError("No enabled reference-to-video model accepts these references. Select an available R2V model.")
        }
        guard let model = Self.preferredModel(in: enabled, where: {
            !$0.requiresReferenceImage && !$0.requiresSourceVideo && !$0.supportsFirstFrame
        }) else { throw ToolError("No enabled text-to-video model available. Select an available T2V model.") }
        let inputs = VideoGenerationSubmission.InputAssets(audioRefs: audioRefs(for: model))
        if let error = inputs.validate(for: model) { throw ToolError(error) }
        return Route(model: model, inputAssets: inputs, note: "text-to-video")
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
        let requested = Int(shot.durationSeconds.rounded(.up))
        let duration: Int
        if model.durations.isEmpty {
            duration = max(1, requested)
        } else if model.durations.contains(requested) {
            duration = requested
        } else {
            duration = model.durations.sorted().first { $0 >= requested } ?? model.durations.max() ?? requested
        }
        let aspect = model.aspectRatios.contains(plan.aspectRatio) ? plan.aspectRatio : (model.aspectRatios.first ?? plan.aspectRatio)
        let resolution: String?
        if let allowed = model.resolutions, !allowed.isEmpty {
            resolution = allowed.contains(plan.resolution) ? plan.resolution : model.automaticResolution
        } else {
            resolution = nil
        }
        return (duration, aspect, resolution)
    }

    // MARK: - QA rubric (shared with qa_shot)

    /// - Parameter comparePriorPanel: when true, the last image handed to the
    ///   reviewer is the nearest earlier frame from the SAME location, and the
    ///   rubric adds a FLAG-CRITICAL spatial-comparison clause (harness
    ///   `qa-storyboard`) so side-swaps are caught against real prior coverage.
    static func qaRubric(for shot: Shot, plan: ShotPlan, comparePriorPanel: Bool = false) -> String {
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
        if comparePriorPanel {
            lines.append("- The LAST image is an earlier frame of THIS SAME location. Compare against it: named landmarks must not move, swap sides, or mirror, and characters must keep the same screen sides. Treat any spatial flip as a CRITICAL failure.")
        }
        lines.append("Judge the frames against this intent and return the JSON verdict.")
        return lines.joined(separator: "\n")
    }

    // MARK: - Progress

    private func postNotice(_ text: String) {
        editor?.agentService.postSystemNotice(text)
    }
}
