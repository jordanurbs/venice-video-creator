import Foundation

extension EditorViewModel {
    // MARK: - Reads

    var shotPlan: ShotPlan? { mediaManifest.shotPlan }

    func shot(id: String) -> Shot? { mediaManifest.shotPlan?.shot(id: id) }
    func character(id: String) -> CharacterSpec? { mediaManifest.shotPlan?.character(id: id) }
    func location(id: String) -> LocationSpec? { mediaManifest.shotPlan?.location(id: id) }

    /// The shot backing the inspector, or nil when the selection is stale.
    var selectedShot: Shot? {
        guard let id = selectedShotId else { return nil }
        return shot(id: id)
    }

    // MARK: - Selection

    /// Selecting a shot claims the inspector: clip/asset selection is cleared so
    /// the routing (clip > shot > character > asset > project) lands on the shot.
    func selectShot(id: String) {
        guard let shot = shot(id: id) else { return }
        selectedShotId = id
        selectedCharacterId = nil
        selectedLocationId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
        // Show the shot's visual state in the viewer: generated video when
        // placed, else its storyboard panel — reviewing panels shot-by-shot
        // is the storyboard workflow.
        if let videoId = shot.videoAssetId,
           let video = mediaAssets.first(where: { $0.id == videoId }),
           !video.isGenerating {
            openPreviewTab(for: video)
        } else if let sbId = shot.storyboardAssetId,
                  let panel = mediaAssets.first(where: { $0.id == sbId }) {
            openPreviewTab(for: panel)
        }
    }

    func deselectShot() {
        selectedShotId = nil
    }

    /// The character backing the inspector, or nil when the selection is stale.
    var selectedCharacter: CharacterSpec? {
        guard let id = selectedCharacterId else { return nil }
        return character(id: id)
    }

    func selectCharacter(id: String) {
        guard let character = character(id: id) else { return }
        selectedCharacterId = id
        selectedShotId = nil
        selectedLocationId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
        // Show the character's canonical reference in the viewer — selecting a
        // cast member surfaces its look the same way selecting a shot surfaces
        // its footage.
        openCanonicalReferencePreview(character.referenceImageAssetIds, locked: character.lockedReferenceAssetId)
    }

    func deselectCharacter() {
        selectedCharacterId = nil
    }

    /// The location backing the inspector, or nil when the selection is stale.
    var selectedLocation: LocationSpec? {
        guard let id = selectedLocationId else { return nil }
        return location(id: id)
    }

    func selectLocation(id: String) {
        guard let location = location(id: id) else { return }
        selectedLocationId = id
        selectedShotId = nil
        selectedCharacterId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
        // Show the location's canonical reference plate in the viewer, mirroring
        // selectShot / selectCharacter.
        openCanonicalReferencePreview(location.referenceImageAssetIds, locked: location.lockedReferenceAssetId)
    }

    func deselectLocation() {
        selectedLocationId = nil
    }

    /// Surfaces an entity's canonical reference image in the viewer: the locked
    /// reference when set, else the first reference that resolves to a ready
    /// (non-generating) asset. No-op when nothing has been generated yet — so
    /// selecting an entity without references leaves the viewer untouched.
    private func openCanonicalReferencePreview(_ referenceIds: [String], locked: String?) {
        let ordered = (locked.map { [$0] } ?? []) + referenceIds
        for id in ordered {
            guard let asset = mediaAssets.first(where: { $0.id == id }), !asset.isGenerating else { continue }
            openPreviewTab(for: asset)
            return
        }
    }

    // MARK: - Writes

    /// Replaces the whole plan (stamping `updatedAt`), registers undo, mirrors a markdown
    /// document into the Documents tab, and marks the project dirty.
    @discardableResult
    func saveShotPlan(_ plan: ShotPlan) -> ShotPlan {
        var updated = plan
        updated.updatedAt = Date()
        applyShotPlan(updated, actionName: "Edit Shot Plan")
        return mediaManifest.shotPlan ?? updated
    }

    /// Mutates the current plan in place (creating an empty one if none exists) and persists.
    @discardableResult
    func mutateShotPlan(actionName: String, _ mutate: (inout ShotPlan) -> Void) -> ShotPlan {
        var plan = mediaManifest.shotPlan ?? ShotPlan()
        mutate(&plan)
        plan.updatedAt = Date()
        applyShotPlan(plan, actionName: actionName)
        return mediaManifest.shotPlan ?? plan
    }

    func clearShotPlan() {
        guard mediaManifest.shotPlan != nil else { return }
        let previous = mediaManifest.shotPlan
        mediaManifest.shotPlan = nil
        undoManager?.registerUndo(withTarget: self) { vm in
            if let previous { vm.applyShotPlan(previous, actionName: "Restore Shot Plan") }
        }
        undoManager?.setActionName("Clear Shot Plan")
        onProjectContentChanged?()
        requestDebouncedCheckpoint()
    }

    // MARK: - Shot mutations

    /// Upserts a shot by id; appends when new. Returns the stored shot.
    @discardableResult
    func upsertShot(_ shot: Shot) -> Shot {
        mutateShotPlan(actionName: "Update Shot") { plan in
            if let idx = plan.shots.firstIndex(where: { $0.id == shot.id }) {
                plan.shots[idx] = shot
            } else {
                plan.shots.append(shot)
            }
        }
        return shot
    }

    func removeShot(id: String) {
        mutateShotPlan(actionName: "Remove Shot") { plan in
            plan.shots.removeAll { $0.id == id }
        }
    }

    /// Reorders shots to match `orderedIds`; ids not present are left in their relative order at the end.
    func reorderShots(orderedIds: [String]) {
        mutateShotPlan(actionName: "Reorder Shots") { plan in
            var byId = Dictionary(plan.shots.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var reordered: [Shot] = []
            for id in orderedIds {
                if let shot = byId.removeValue(forKey: id) { reordered.append(shot) }
            }
            // Preserve any leftover shots in their original order.
            for shot in plan.shots where byId[shot.id] != nil {
                reordered.append(shot)
                byId[shot.id] = nil
            }
            plan.shots = reordered
        }
    }

    func setShotStatus(id: String, _ status: ShotStatus) {
        mutateShotPlan(actionName: "Set Shot Status") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == id }) else { return }
            plan.shots[idx].status = status
        }
    }

    // MARK: - Character mutations

    @discardableResult
    func upsertCharacter(_ character: CharacterSpec) -> CharacterSpec {
        mutateShotPlan(actionName: "Update Character") { plan in
            if let idx = plan.characters.firstIndex(where: { $0.id == character.id }) {
                plan.characters[idx] = character
            } else {
                plan.characters.append(character)
            }
        }
        return character
    }

    func removeCharacter(id: String) {
        mutateShotPlan(actionName: "Remove Character") { plan in
            plan.characters.removeAll { $0.id == id }
            for i in plan.shots.indices {
                plan.shots[i].characterIds.removeAll { $0 == id }
            }
        }
    }

    /// Generates a fresh set of reference images for a character (front +
    /// three-quarter) via the image path and swaps them onto the character.
    /// Old assets stay in the media library. Mirrors create_character's flow.
    func regenerateCharacterReferences(characterId: String, count: Int = 2) {
        guard let character = character(id: characterId) else { return }
        guard AccountService.shared.hasVeniceKey else {
            editorToast = MediaPanelToast(message: "Add your Venice API key in Settings to generate references.")
            return
        }
        guard let model = referencePlateModel() else {
            editorToast = MediaPanelToast(message: "No enabled image model. Turn one on in Settings → Models.")
            return
        }

        let visualPrompt = character.effectiveVisualPrompt
        let aspectRatio = model.aspectRatios.first ?? ""
        // Reference sheets are tier-1 identity anchors — full quality/resolution.
        let resolution = ToolExecutor.referenceResolution(model)
        let quality = ToolExecutor.referenceQuality(model)
        let styleLead = ShotPromptBuilder.stylePrefix(shotPlan).map { "\($0). " } ?? ""
        // Match the create path: objects get the product-style suffix, the object
        // pose ladder, and no-face provenance; people get the photoreal-portrait
        // set. (The UI regenerate previously forced the person styling on both,
        // so prop refs came back face-oriented and mis-provenanced.)
        let isObject = character.kind == .object
        let styleSuffix = isObject ? ToolExecutor.objectRefStyleSuffix : ToolExecutor.characterRefStyleSuffix
        let poses = isObject ? ToolExecutor.objectPoses : [
            "front view, facing the camera, neutral expression",
            "three-quarter view",
            "profile side view",
            "full-body shot",
        ]
        // Keep new references in the same folder as the outgoing set.
        let folderId = character.referenceImageAssetIds
            .compactMap { id in mediaAssets.first { $0.id == id }?.folderId }
            .first

        var generatedIds: [String] = []
        for i in 0..<max(1, min(4, count)) {
            let pose = poses[i % poses.count]
            var genInput = GenerationInput(
                prompt: "\(styleLead)\(visualPrompt), \(pose), \(styleSuffix)",
                model: model.id, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality
            )
            genInput.hasFace = !isObject
            ToolExecutor.applyReferenceSeed(&genInput, model: model, plan: shotPlan)
            let pid = ImageGenerationSubmission.make(
                genInput: genInput, model: model, references: [],
                name: "\(character.name) · ref \(i + 1)", folderId: folderId
            ).submit(service: generationService, projectURL: projectURL, editor: self)
            generatedIds.append(pid)
        }

        var updated = character
        updated.referenceImageAssetIds = generatedIds
        // Old lock is gone; lock the first new take so one canonical look stays
        // set by default (the user can switch it in the inspector).
        updated.lockedReferenceAssetId = generatedIds.first
        updated.provenance = CharacterProvenance(generationModel: model.id, hasFace: !isObject)
        upsertCharacter(updated)
    }

    /// Generates a spoken voice sample for a character via TTS and appends it to
    /// the character's voice samples. Uses the character's locked voice when set,
    /// else the model's default. The sample can then be locked as the character's
    /// voice reference (attached as audio_url during shot generation).
    /// `lockIfUnset`: auditioning from the inspector picker passes false — trying
    /// a voice must not silently lock it; locking is the explicit next step.
    func generateCharacterVoiceSample(characterId: String, voice: String? = nil, text: String? = nil, lockIfUnset: Bool = true) {
        guard let character = character(id: characterId) else { return }
        guard AccountService.shared.hasVeniceKey else {
            editorToast = MediaPanelToast(message: "Add your Venice API key in Settings to generate a voice sample.")
            return
        }
        let model = character.voiceModel
            .flatMap { vm in AudioModelConfig.allModels.first { $0.id == vm && ModelPreferences.shared.isEnabled($0.id) } }
            ?? AudioModelConfig.allModels.first {
                $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
            }
        guard let model else {
            editorToast = MediaPanelToast(message: "No enabled text-to-speech model. Turn one on in Settings → Models.")
            return
        }
        let chosenVoice = voice ?? character.lockedVoiceId ?? model.defaultVoice ?? model.voices?.first
        var line = text ?? Self.voiceReferenceLine(name: character.name)
        if line.count < model.minPromptLength {
            line += " " + String(repeating: "Testing one two three. ", count: max(1, (model.minPromptLength - line.count) / 22 + 1))
        }
        let params = AudioGenerationParams(
            prompt: line, voice: chosenVoice, lyrics: nil, styleInstructions: nil,
            instrumental: false, durationSeconds: nil
        )
        if let err = model.validate(params: params) {
            editorToast = MediaPanelToast(message: err)
            return
        }
        var genInput = GenerationInput(
            prompt: line, model: model.id, duration: 0,
            aspectRatio: "", resolution: nil, voice: chosenVoice
        )
        genInput.createdAt = Date()
        let folderId = character.voiceSampleAssetIds
            .compactMap { id in mediaAssets.first { $0.id == id }?.folderId }
            .first
        let pid = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params,
            name: "\(character.name.isEmpty ? "Character" : character.name) · voice", folderId: folderId
        ).submit(service: generationService, projectURL: projectURL, editor: self)

        var updated = character
        updated.voiceSampleAssetIds.append(pid)
        if lockIfUnset, updated.lockedVoiceId == nil { updated.lockedVoiceId = chosenVoice }
        if updated.voiceModel == nil { updated.voiceModel = model.id }
        upsertCharacter(updated)
    }

    /// A neutral spoken line long enough to clear model audio-input floors (3s+).
    static func voiceReferenceLine(name: String) -> String {
        let who = name.isEmpty ? "this character" : name
        return "Hello, my name is \(who). This is my voice: steady, clear, and always the same, in every scene and every shot we film together."
    }

    // MARK: - Shot splitting

    /// Splits an overlong shot into consecutive ≤`cap` parts covering the same
    /// beat: same prompt/references, slugs suffixed a/b/c…, chained with
    /// matchCut so production seeds each part from the previous part's last
    /// frame. The original shot becomes part one; generated work is kept on it.
    @discardableResult
    func splitShot(id: String, cap: Double) -> [Shot]? {
        guard let original = shot(id: id), original.durationSeconds > cap, cap > 0 else { return nil }

        let partCount = Int(ceil(original.durationSeconds / cap))
        let partSeconds = (original.durationSeconds / Double(partCount)).rounded()
        let suffixes = ["a", "b", "c", "d", "e", "f", "g", "h"]
        let baseSlug = original.slug ?? "S?"

        var parts: [Shot] = []
        for i in 0..<partCount {
            var part = i == 0 ? original : Shot(
                summary: original.summary,
                prompt: original.prompt,
                motionLevel: original.motionLevel,
                modelOverride: original.modelOverride,
                characterIds: original.characterIds,
                locationIds: original.locationIds,
                nativeAudio: original.nativeAudio
            )
            part.slug = baseSlug + suffixes[min(i, suffixes.count - 1)]
            part.durationSeconds = partSeconds
            // Chain parts for continuity; the last part keeps the original transition.
            part.transition = i == partCount - 1 ? original.transition : .matchCut
            if i > 0 {
                part.summary = original.summary.isEmpty ? "" : "\(original.summary) (part \(i + 1))"
                // Spoken lines stay on part one only, so produce_audio doesn't
                // voice the same beat once per part.
                part.dialogue = []
            }
            parts.append(part)
        }

        mutateShotPlan(actionName: "Split Shot") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == id }) else { return }
            plan.shots.replaceSubrange(idx...idx, with: parts)
        }
        return parts
    }

    // MARK: - Location mutations

    @discardableResult
    func upsertLocation(_ location: LocationSpec) -> LocationSpec {
        mutateShotPlan(actionName: "Update Location") { plan in
            if let idx = plan.locations.firstIndex(where: { $0.id == location.id }) {
                plan.locations[idx] = location
            } else {
                plan.locations.append(location)
            }
        }
        return location
    }

    // MARK: - Shot reset (start over)

    /// Wipes a shot's produced state back to `planned`: removes its placed
    /// timeline clip, clears video/storyboard links, takes, QA notes, and the
    /// failure reason. The generated assets STAY in the media library (they
    /// cost money; delete them explicitly if unwanted). One undoable step.
    /// The prompt/summary/blocking are untouched — this resets production,
    /// not planning.
    func resetShot(id: String) {
        guard let shot = shotPlan?.shot(id: id) else { return }
        undoManager?.beginUndoGrouping()
        // Remove the clip backing this shot from the timeline (placed runs).
        if let assetId = shot.videoAssetId, let clipId = productionClipId(forAsset: assetId) {
            removeClips(ids: [clipId], prune: true)
        }
        mutateShotPlan(actionName: "Start Shot Over") { plan in
            guard let idx = plan.shots.firstIndex(where: { $0.id == id }) else { return }
            plan.shots[idx].videoAssetId = nil
            plan.shots[idx].storyboardAssetId = nil
            plan.shots[idx].takes = []
            plan.shots[idx].qaSummary = nil
            plan.shots[idx].failureReason = nil
            plan.shots[idx].status = .planned
        }
        undoManager?.setActionName("Start Shot Over")
        undoManager?.endUndoGrouping()
    }

    /// Start-over for the whole production: every shot back to `planned` in
    /// one undoable step. Library assets are kept.
    func resetAllShots() {
        guard let plan = shotPlan, !plan.shots.isEmpty else { return }
        undoManager?.beginUndoGrouping()
        let clipIds = plan.shots
            .compactMap(\.videoAssetId)
            .compactMap { productionClipId(forAsset: $0) }
        if !clipIds.isEmpty {
            removeClips(ids: Set(clipIds), prune: true)
        }
        mutateShotPlan(actionName: "Start Production Over") { plan in
            for idx in plan.shots.indices {
                plan.shots[idx].videoAssetId = nil
                plan.shots[idx].storyboardAssetId = nil
                plan.shots[idx].takes = []
                plan.shots[idx].qaSummary = nil
                plan.shots[idx].failureReason = nil
                plan.shots[idx].status = .planned
            }
        }
        undoManager?.setActionName("Start Production Over")
        undoManager?.endUndoGrouping()
    }

    /// Scrubs deleted media-asset ids out of the shot plan so cast/location
    /// panes never show ghost references. Deleting media always cleaned the
    /// timeline but historically left the plan pointing at gone assets — the
    /// "assets randomly unlinked" bug: every delete_media / folder delete of a
    /// reference image silently orphaned its entity (2026-08-07).
    /// Registers its own undo via mutateShotPlan; callers run in the same
    /// runloop undo group as their media mutation, so one Undo restores both.
    func detachAssetsFromShotPlan(ids: Set<String>) {
        guard !ids.isEmpty, let plan = mediaManifest.shotPlan else { return }
        // Only mutate when something actually references a deleted id.
        let referenced = plan.characters.contains { c in
            c.referenceImageAssetIds.contains(where: ids.contains)
                || c.voiceSampleAssetIds.contains(where: ids.contains)
                || (c.voiceReferenceAssetId.map(ids.contains) ?? false)
        } || plan.locations.contains { l in
            l.referenceImageAssetIds.contains(where: ids.contains)
        } || plan.shots.contains { s in
            (s.audioReferenceAssetId.map(ids.contains) ?? false)
                || (s.storyboardAssetId.map(ids.contains) ?? false)
                || (s.videoAssetId.map(ids.contains) ?? false)
        }
        guard referenced else { return }

        mutateShotPlan(actionName: "Detach Deleted Media") { plan in
            for i in plan.characters.indices {
                plan.characters[i].referenceImageAssetIds.removeAll { ids.contains($0) }
                if let locked = plan.characters[i].lockedReferenceAssetId, ids.contains(locked) {
                    plan.characters[i].lockedReferenceAssetId = plan.characters[i].referenceImageAssetIds.first
                }
                plan.characters[i].voiceSampleAssetIds.removeAll { ids.contains($0) }
                if let voiceRef = plan.characters[i].voiceReferenceAssetId, ids.contains(voiceRef) {
                    plan.characters[i].voiceReferenceAssetId = nil
                }
            }
            for i in plan.locations.indices {
                plan.locations[i].referenceImageAssetIds.removeAll { ids.contains($0) }
                if let locked = plan.locations[i].lockedReferenceAssetId, ids.contains(locked) {
                    plan.locations[i].lockedReferenceAssetId = plan.locations[i].referenceImageAssetIds.first
                }
            }
            for i in plan.shots.indices {
                if let audioRef = plan.shots[i].audioReferenceAssetId, ids.contains(audioRef) {
                    plan.shots[i].audioReferenceAssetId = nil
                }
                if let sb = plan.shots[i].storyboardAssetId, ids.contains(sb) {
                    plan.shots[i].storyboardAssetId = nil
                    // Panel gone: the shot needs a new one before production.
                    if plan.shots[i].status == .storyboarded { plan.shots[i].status = .planned }
                }
                if let video = plan.shots[i].videoAssetId, ids.contains(video) {
                    plan.shots[i].videoAssetId = nil
                }
            }
        }
    }

    /// One-shot heal for plans that already carry ghost ids (created before
    /// deletion started detaching, 2026-08-07): scrubs every plan reference to
    /// an asset that exists in neither the live library nor the manifest.
    /// Called after project restore, when the real asset set is known.
    /// Manifest entries count as existing so a missing-file asset (offline
    /// disk, interrupted download) is NOT detached — it can still be relinked.
    func reconcileShotPlanWithMediaLibrary() {
        guard let plan = mediaManifest.shotPlan else { return }
        var known = Set(mediaAssets.map(\.id))
        known.formUnion(mediaManifest.entries.map(\.id))

        var referenced = Set<String>()
        for c in plan.characters {
            referenced.formUnion(c.referenceImageAssetIds)
            referenced.formUnion(c.voiceSampleAssetIds)
            if let v = c.voiceReferenceAssetId { referenced.insert(v) }
        }
        for l in plan.locations {
            referenced.formUnion(l.referenceImageAssetIds)
        }
        for s in plan.shots {
            if let a = s.audioReferenceAssetId { referenced.insert(a) }
            if let sb = s.storyboardAssetId { referenced.insert(sb) }
            if let v = s.videoAssetId { referenced.insert(v) }
        }

        let ghosts = referenced.subtracting(known)
        guard !ghosts.isEmpty else { return }
        Log.project.notice("reconcile: detaching \(ghosts.count) ghost asset id(s) from the shot plan")
        detachAssetsFromShotPlan(ids: ghosts)
    }

    func removeLocation(id: String) {
        mutateShotPlan(actionName: "Remove Location") { plan in
            plan.locations.removeAll { $0.id == id }
            for i in plan.shots.indices {
                plan.shots[i].locationIds.removeAll { $0 == id }
            }
        }
    }

    /// Removes a single reference plate from a location: detaches it from the
    /// location's reference set (repointing the canonical lock to the first
    /// remaining plate if the removed one was locked) and deletes the underlying
    /// media asset. Grouped into one undoable step.
    func removeLocationReference(locationId: String, assetId: String) {
        guard var location = location(id: locationId),
              location.referenceImageAssetIds.contains(assetId) else { return }
        undoManager?.beginUndoGrouping()
        location.referenceImageAssetIds.removeAll { $0 == assetId }
        if location.lockedReferenceAssetId == assetId {
            location.lockedReferenceAssetId = location.referenceImageAssetIds.first
        }
        upsertLocation(location)
        deleteMediaAssets(ids: [assetId])
        undoManager?.setActionName("Remove Reference Plate")
        undoManager?.endUndoGrouping()
    }

    /// The image model reference plates should be generated with: the
    /// bakeoff-locked `plan.referenceImageModel` when it's set and still enabled,
    /// otherwise the first enabled model. Keeps the panels' Regenerate buttons in
    /// sync with the agent tool path (`ToolExecutor.resolveImageModel`), which
    /// already prioritizes the bakeoff winner so every entity shares one look.
    func referencePlateModel() -> ImageModelConfig? {
        if let locked = mediaManifest.shotPlan?.referenceImageModel,
           let model = ImageModelConfig.allModels.first(where: { $0.id == locked }),
           ModelPreferences.shared.isEnabled(locked) {
            return model
        }
        return ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) }
    }

    /// Location counterpart of `regenerateCharacterReferences`: fresh angle set
    /// via the image path, swapped onto the location (old assets stay in Media).
    func regenerateLocationReferences(locationId: String, count: Int = 2) {
        guard let location = location(id: locationId) else { return }
        guard AccountService.shared.hasVeniceKey else {
            editorToast = MediaPanelToast(message: "Add your Venice API key in Settings to generate references.")
            return
        }
        guard let model = referencePlateModel() else {
            editorToast = MediaPanelToast(message: "No enabled image model. Turn one on in Settings → Models.")
            return
        }

        let visualPrompt = location.effectiveVisualPrompt
        let aspectRatio = model.aspectRatios.first ?? ""
        // Location plates are tier-2 references — full quality/resolution.
        let resolution = ToolExecutor.referenceResolution(model)
        let quality = ToolExecutor.referenceQuality(model)
        let styleLead = ShotPromptBuilder.stylePrefix(shotPlan).map { "\($0). " } ?? ""
        let angles = ToolExecutor.locationAngles
        // Match the create path: bake the locked geography into every angle so
        // regenerated plates keep the same fixed layout (harness rule 49).
        let anchorsClause = location.spatialAnchors.map { ", fixed layout (never rearrange): \($0)" } ?? ""
        let folderId = location.referenceImageAssetIds
            .compactMap { id in mediaAssets.first { $0.id == id }?.folderId }
            .first

        var generatedIds: [String] = []
        for i in 0..<max(1, min(4, count)) {
            let angle = angles[i % angles.count]
            var genInput = GenerationInput(
                prompt: "\(styleLead)\(visualPrompt), \(angle)\(anchorsClause), \(ToolExecutor.locationRefStyleSuffix)",
                model: model.id, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality
            )
            genInput.hasFace = false
            ToolExecutor.applyReferenceSeed(&genInput, model: model, plan: shotPlan)
            let pid = ImageGenerationSubmission.make(
                genInput: genInput, model: model, references: [],
                name: "\(location.name) · ref \(i + 1)", folderId: folderId
            ).submit(service: generationService, projectURL: projectURL, editor: self)
            generatedIds.append(pid)
        }

        var updated = location
        updated.referenceImageAssetIds = generatedIds
        // Lock the first new plate so one canonical look stays set by default.
        updated.lockedReferenceAssetId = generatedIds.first
        upsertLocation(updated)
    }

    // MARK: - Internal apply + undo + mirror

    private func applyShotPlan(_ plan: ShotPlan, actionName: String) {
        let previous = mediaManifest.shotPlan
        var plan = plan
        for index in plan.shots.indices {
            let shot = plan.shots[index]
            let replacedPanel = previous?.shot(id: shot.id)?.storyboardAssetId != shot.storyboardAssetId
            let staleReview = shot.panelReview.map {
                $0.revision.settingsDigest != (try? StoryboardReviewGate.settingsDigest(shot: shot, plan: plan))
            } ?? false
            if staleReview || (replacedPanel && shot.panelReview == nil) {
                plan.shots[index].panelReview = nil
                plan.shots[index].qaSummary = nil
                if shot.status == .approved || shot.status == .placed {
                    plan.shots[index].status = shot.videoAssetId == nil ? .storyboarded : .qa
                }
            }
        }
        mediaManifest.shotPlan = plan
        undoManager?.registerUndo(withTarget: self) { vm in
            if let previous {
                vm.applyShotPlan(previous, actionName: actionName)
            } else {
                vm.clearShotPlan()
            }
        }
        undoManager?.setActionName(actionName)
        // Mirror a human-readable version into the Documents library (upserted by name).
        saveDocument(name: Self.shotPlanDocumentName, content: plan.markdown())
        onProjectContentChanged?()
        // Flush the plan to disk soon so a hang/crash can't lose it (coalesced).
        requestDebouncedCheckpoint()
    }

    static let shotPlanDocumentName = "Shot Plan"
}

// MARK: - Markdown mirror

extension ShotPlan {
    /// Renders a human-readable markdown mirror shown in the Documents tab.
    func markdown() -> String {
        var out = "# \(title)\n\n"
        if let logline, !logline.isEmpty { out += "\(logline)\n\n" }
        out += "- **Format:** \(aspectRatio) · \(resolution)\n"
        if let defaultModel, !defaultModel.isEmpty { out += "- **Default model:** \(defaultModel)\n" }
        out += "- **Shots:** \(shots.count) · **Planned runtime:** \(Self.formatSeconds(totalPlannedSeconds))\n\n"

        if !characters.isEmpty {
            out += "## Characters\n\n"
            for c in characters {
                out += "- **\(c.name.isEmpty ? "(unnamed)" : c.name)**"
                if let d = c.description, !d.isEmpty { out += " — \(d)" }
                if let v = c.lockedVoiceId, !v.isEmpty { out += " · voice: `\(v)`" }
                if c.voiceReferenceAssetId != nil { out += " · voice ref locked" }
                let refs = c.referenceImageAssetIds.count
                if refs > 0 { out += " · \(refs) ref image\(refs == 1 ? "" : "s")" }
                out += "\n"
            }
            out += "\n"
        }

        if !locations.isEmpty {
            out += "## Locations\n\n"
            for l in locations {
                out += "- **\(l.name.isEmpty ? "(unnamed)" : l.name)**"
                if let d = l.description, !d.isEmpty { out += " — \(d)" }
                let refs = l.referenceImageAssetIds.count
                if refs > 0 { out += " · \(refs) ref image\(refs == 1 ? "" : "s")" }
                out += "\n"
                if let anchors = l.spatialAnchors, !anchors.isEmpty {
                    out += "  - **Fixed layout:** \(anchors)\n"
                }
            }
            out += "\n"
        }

        out += "## Shots\n\n"
        if shots.isEmpty {
            out += "_No shots yet._\n"
        }
        for (i, shot) in shots.enumerated() {
            let label = shot.slug ?? "Shot \(i + 1)"
            out += "### \(label) — \(shot.status.rawValue)\n\n"
            if !shot.summary.isEmpty { out += "\(shot.summary)\n\n" }
            out += "- **Duration:** \(Self.formatSeconds(shot.durationSeconds)) · **Motion:** \(shot.motionLevel.rawValue) · **Transition:** \(shot.transition.rawValue)\n"
            if let m = shot.modelOverride, !m.isEmpty { out += "- **Model:** \(m)\n" }
            if !shot.characterIds.isEmpty {
                let names = shot.characterIds.map { id in character(id: id)?.name ?? id }
                out += "- **Characters:** \(names.joined(separator: ", "))\n"
            }
            if !shot.locationIds.isEmpty {
                let names = shot.locationIds.map { id in location(id: id)?.name ?? id }
                out += "- **Locations:** \(names.joined(separator: ", "))\n"
            }
            if let blocking = shot.blocking, !blocking.isEmpty { out += "- **Blocking:** \(blocking)\n" }
            if !shot.prompt.isEmpty { out += "- **Video prompt:** \(shot.prompt)\n" }
            if let sb = shot.storyboardPrompt, !sb.isEmpty { out += "- **Storyboard prompt:** \(sb)\n" }
            for line in shot.dialogue {
                let who = line.characterId.flatMap { character(id: $0)?.name } ?? line.speaker ?? "Speaker"
                let tag = line.voiceOver ? " (V.O.)" : ""
                out += "  - **\(who)\(tag):** \(line.text)\n"
            }
            if shot.takes.count > 1 { out += "- **Takes:** \(shot.takes.count)\n" }
            if let qa = shot.qaSummary, !qa.isEmpty { out += "- **QA:** \(qa)\n" }
            if let fail = shot.failureReason, !fail.isEmpty { out += "- **Failure:** \(fail)\n" }
            out += "\n"
        }
        return out
    }

    private static func formatSeconds(_ s: Double) -> String {
        if s <= 0 { return "0s" }
        if s < 60 { return s == s.rounded() ? "\(Int(s))s" : String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let rem = Int(s) % 60
        return rem == 0 ? "\(m)m" : "\(m)m \(rem)s"
    }
}
