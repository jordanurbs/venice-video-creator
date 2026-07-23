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
        guard shot(id: id) != nil else { return }
        selectedShotId = id
        selectedCharacterId = nil
        selectedLocationId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
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
        guard character(id: id) != nil else { return }
        selectedCharacterId = id
        selectedShotId = nil
        selectedLocationId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
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
        guard location(id: id) != nil else { return }
        selectedLocationId = id
        selectedShotId = nil
        selectedCharacterId = nil
        selectedClipIds = []
        selectedGap = nil
        selectedTimelineRange = nil
        selectedMediaAssetIds = []
    }

    func deselectLocation() {
        selectedLocationId = nil
    }

    // MARK: - Writes

    /// Replaces the whole plan (stamping `updatedAt`), registers undo, mirrors a markdown
    /// document into the Documents tab, and marks the project dirty.
    @discardableResult
    func saveShotPlan(_ plan: ShotPlan) -> ShotPlan {
        var updated = plan
        updated.updatedAt = Date()
        applyShotPlan(updated, actionName: "Edit Shot Plan")
        return updated
    }

    /// Mutates the current plan in place (creating an empty one if none exists) and persists.
    @discardableResult
    func mutateShotPlan(actionName: String, _ mutate: (inout ShotPlan) -> Void) -> ShotPlan {
        var plan = mediaManifest.shotPlan ?? ShotPlan()
        mutate(&plan)
        plan.updatedAt = Date()
        applyShotPlan(plan, actionName: actionName)
        return plan
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
        guard let model = ImageModelConfig.allModels.first(where: { ModelPreferences.shared.isEnabled($0.id) }) else {
            editorToast = MediaPanelToast(message: "No enabled image model. Turn one on in Settings → Models.")
            return
        }

        let visualPrompt = character.effectiveVisualPrompt
        let aspectRatio = model.aspectRatios.first ?? ""
        let resolution = ToolExecutor.cheapestResolution(model)
        let quality = model.qualities?.last
        let poses = [
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
                prompt: "\(visualPrompt), \(pose), \(ToolExecutor.characterRefStyleSuffix)",
                model: model.id, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality
            )
            genInput.hasFace = true
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
        updated.provenance = CharacterProvenance(generationModel: model.id, hasFace: true)
        upsertCharacter(updated)
    }

    /// Generates a spoken voice sample for a character via TTS and appends it to
    /// the character's voice samples. Uses the character's locked voice when set,
    /// else the model's default. The sample can then be locked as the character's
    /// voice reference (attached as audio_url during shot generation).
    func generateCharacterVoiceSample(characterId: String, voice: String? = nil, text: String? = nil) {
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
        if updated.lockedVoiceId == nil { updated.lockedVoiceId = chosenVoice }
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

    func removeLocation(id: String) {
        mutateShotPlan(actionName: "Remove Location") { plan in
            plan.locations.removeAll { $0.id == id }
            for i in plan.shots.indices {
                plan.shots[i].locationIds.removeAll { $0 == id }
            }
        }
    }

    /// Location counterpart of `regenerateCharacterReferences`: fresh angle set
    /// via the image path, swapped onto the location (old assets stay in Media).
    func regenerateLocationReferences(locationId: String, count: Int = 2) {
        guard let location = location(id: locationId) else { return }
        guard AccountService.shared.hasVeniceKey else {
            editorToast = MediaPanelToast(message: "Add your Venice API key in Settings to generate references.")
            return
        }
        guard let model = ImageModelConfig.allModels.first(where: { ModelPreferences.shared.isEnabled($0.id) }) else {
            editorToast = MediaPanelToast(message: "No enabled image model. Turn one on in Settings → Models.")
            return
        }

        let visualPrompt = location.effectiveVisualPrompt
        let aspectRatio = model.aspectRatios.first ?? ""
        let resolution = ToolExecutor.cheapestResolution(model)
        let quality = model.qualities?.last
        let angles = ToolExecutor.locationAngles
        let folderId = location.referenceImageAssetIds
            .compactMap { id in mediaAssets.first { $0.id == id }?.folderId }
            .first

        var generatedIds: [String] = []
        for i in 0..<max(1, min(4, count)) {
            let angle = angles[i % angles.count]
            var genInput = GenerationInput(
                prompt: "\(visualPrompt), \(angle), \(ToolExecutor.locationRefStyleSuffix)",
                model: model.id, duration: 0,
                aspectRatio: aspectRatio, resolution: resolution, quality: quality
            )
            genInput.hasFace = false
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
            if !shot.prompt.isEmpty { out += "- **Prompt:** \(shot.prompt)\n" }
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
