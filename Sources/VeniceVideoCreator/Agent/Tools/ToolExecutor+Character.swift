import Foundation

extension ToolExecutor {
    // MARK: - create_character

    /// Creates a recurring character and (optionally) generates front / three-quarter
    /// reference images for it via the existing image path. Generated references are tagged
    /// with face provenance so the Seedance R2V face gate can be satisfied later. Reference
    /// generation is async — poll get_media until the returned asset ids finish.
    func createCharacter(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let name = try args.requireString("name")
        let description = args.string("description")
        let visualPrompt = args.string("prompt") ?? description ?? name
        let kind: CharacterKind = args.string("kind") == "object" ? .object : .person

        var character = CharacterSpec(name: name, kind: kind, description: description, visualPrompt: visualPrompt)

        // Attach any existing reference images the caller already has.
        var attachedRefs: [MediaAsset] = []
        for id in args.stringArray("referenceMediaRefs") {
            let a = try asset(id, editor: editor, label: "Reference image")
            guard a.type == .image else {
                throw ToolError("referenceMediaRefs entry '\(id)' must be an image (got \(a.type.rawValue)).")
            }
            attachedRefs.append(a)
        }

        // Default to generating 2 references only when none were supplied.
        let defaultCount = attachedRefs.isEmpty ? 2 : 0
        let count = min(4, max(0, args.int("count") ?? defaultCount))

        var generatedIds: [String] = []
        var modelUsed: String?
        if count > 0 {
            guard AccountService.shared.hasVeniceKey else {
                throw ToolError("Generating references requires a Venice API key. Tell the user to add it in Settings, or pass referenceMediaRefs instead.")
            }
            guard let model = try resolveImageModel(args) else {
                throw ToolError("Image model catalog not loaded yet. Try again in a moment.")
            }
            modelUsed = model.id
            let aspectRatio = args.string("aspectRatio") ?? model.aspectRatios.first ?? ""
            let resolution = args.string("resolution") ?? Self.cheapestResolution(model)
            let quality = model.qualities?.last
            if let err = model.validate(aspectRatio: aspectRatio, resolution: resolution, quality: quality, imageRefCount: 0, numImages: 1) {
                throw ToolError(err)
            }
            let folderId = try resolveFolderId(args, editor: editor, fallbackReferences: attachedRefs)
            let styleSuffix = kind == .object ? Self.objectRefStyleSuffix : Self.characterRefStyleSuffix
            let poses = Self.referencePoses(args, count: count, kind: kind)
            for (i, pose) in poses.enumerated() {
                let fullPrompt = "\(visualPrompt), \(pose), \(styleSuffix)"
                var genInput = GenerationInput(
                    prompt: fullPrompt, model: model.id, duration: 0,
                    aspectRatio: aspectRatio, resolution: resolution, quality: quality
                )
                genInput.hasFace = (kind == .person)
                let pid = ImageGenerationSubmission.make(
                    genInput: genInput, model: model, references: [],
                    name: "\(name) · ref \(i + 1)", folderId: folderId
                ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
                generatedIds.append(pid)
            }
        }

        character.referenceImageAssetIds = attachedRefs.map(\.id) + generatedIds
        character.provenance = CharacterProvenance(generationModel: modelUsed, hasFace: kind == .person)
        // Lock one canonical reference by default so shot generation isn't fed
        // divergent takes. The user can switch or unlock it (Cast tab / inspector);
        // every shot using this character follows the new lock automatically.
        if character.lockedReferenceAssetId == nil, let first = character.referenceImageAssetIds.first {
            character.lockedReferenceAssetId = first
        }
        editor.upsertCharacter(character)
        if !character.referenceImageAssetIds.isEmpty {
            editor.mediaPanelVisible = true
            editor.showMediaPanelCastTab()
        }

        var body: [String: Any] = [
            "id": character.id,
            "name": character.name,
            "referenceImageAssetIds": character.referenceImageAssetIds,
        ]
        if let locked = character.lockedReferenceAssetId {
            body["lockedReferenceAssetId"] = locked
        }
        if !generatedIds.isEmpty {
            body["generatingAssetIds"] = generatedIds
            body["hint"] = kind == .object
                ? "Object references are generating; the first is locked as the canonical look (the user can switch it later). Objects have no face or voice. Call wait_for_media with these asset ids, inspect them, then attach the object to shots via characterIds."
                : "Reference images are generating; the first is locked as the canonical look (the user can switch it later). Call wait_for_media with these asset ids, inspect them, then audition_voices and lock_voice."
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - update_character

    /// Updates a character's fields and/or reference set. The bridge for images
    /// generated outside create_character: attaching them here is what makes
    /// them visible in the Cast tab and usable as R2V references.
    func updateCharacter(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let characterId = try args.requireString("characterId")
        guard var character = editor.character(id: characterId) else {
            throw ToolError("Character not found: \(characterId). Call get_shot_plan to list characters.")
        }

        if let name = args.string("name") { character.name = name }
        if let description = args.string("description") { character.description = description }
        if let prompt = args.string("prompt") { character.visualPrompt = prompt }

        func validatedImageIds(_ key: String) throws -> [String]? {
            guard args[key] != nil else { return nil }
            let ids = args.stringArray(key)
            for id in ids {
                let a = try asset(id, editor: editor, label: "Reference image")
                guard a.type == .image else {
                    throw ToolError("\(key) entry '\(id)' must be an image (got \(a.type.rawValue)).")
                }
            }
            return ids
        }
        var referencesChanged = false
        if let replace = try validatedImageIds("referenceMediaRefs") {
            character.referenceImageAssetIds = replace
            referencesChanged = true
        }
        if let add = try validatedImageIds("addReferenceMediaRefs") {
            character.referenceImageAssetIds += add.filter { !character.referenceImageAssetIds.contains($0) }
            referencesChanged = !add.isEmpty || referencesChanged
        }

        // Lock/unlock the canonical reference. Explicit null/"" clears the lock.
        if args.keys.contains("lockedReferenceMediaRef") {
            if let locked = args.string("lockedReferenceMediaRef") {
                guard character.referenceImageAssetIds.contains(locked) else {
                    throw ToolError("lockedReferenceMediaRef '\(locked)' is not one of this character's references. Attach it first (addReferenceMediaRefs) or pick an attached id.")
                }
                character.lockedReferenceAssetId = locked
            } else {
                character.lockedReferenceAssetId = nil
            }
        }
        // A replaced set invalidates a lock that didn't survive it.
        if let locked = character.lockedReferenceAssetId, !character.referenceImageAssetIds.contains(locked) {
            character.lockedReferenceAssetId = nil
        }

        // Lock/unlock the canonical voice reference (audio attached to the
        // character's shots as audio_url). Explicit null/"" clears the lock.
        if args.keys.contains("voiceReferenceMediaRef") {
            if let voiceRef = args.string("voiceReferenceMediaRef") {
                let a = try asset(voiceRef, editor: editor, label: "Voice reference")
                guard a.type == .audio else {
                    throw ToolError("voiceReferenceMediaRef '\(voiceRef)' must be an audio asset (got \(a.type.rawValue)).")
                }
                character.voiceReferenceAssetId = voiceRef
                if !character.voiceSampleAssetIds.contains(voiceRef) {
                    character.voiceSampleAssetIds.append(voiceRef)
                }
            } else {
                character.voiceReferenceAssetId = nil
            }
        }

        editor.upsertCharacter(character)
        if referencesChanged {
            editor.mediaPanelVisible = true
            editor.showMediaPanelCastTab()
        }
        var body: [String: Any] = [
            "id": character.id,
            "name": character.name,
            "referenceImageAssetIds": character.referenceImageAssetIds,
            "hint": "Character updated. References now show in the Cast tab and will be used for shot consistency.",
        ]
        if let locked = character.lockedReferenceAssetId {
            body["lockedReferenceAssetId"] = locked
        } else if character.referenceImageAssetIds.count > 1 {
            body["hint"] = "Character updated. Multiple references with no lock — if they show different looks, lock the best one (lockedReferenceMediaRef) so generation isn't fed divergent takes."
        }
        if let voiceRef = character.voiceReferenceAssetId {
            body["voiceReferenceAssetId"] = voiceRef
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - audition_voices

    /// Generates one short TTS sample per candidate voice so the user/agent can pick one.
    /// Does not lock anything — call lock_voice with the chosen voice afterward.
    func auditionVoices(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Auditioning voices requires a Venice API key. Tell the user to add it in Settings.")
        }
        guard let model = try resolveTTSModel(args) else {
            throw ToolError("No enabled text-to-speech model with selectable voices is available. Turn one on in Settings → Models.")
        }
        guard let allVoices = model.voices, !allVoices.isEmpty else {
            throw ToolError("Model '\(model.id)' has no selectable voices.")
        }

        let requested = args.stringArray("voices")
        let count = min(8, max(1, args.int("count") ?? 4))
        let voices: [String]
        if !requested.isEmpty {
            for v in requested where !allVoices.contains(v) {
                let sample = Array(allVoices.prefix(10)).joined(separator: ", ")
                throw ToolError("Voice '\(v)' isn't offered by \(model.id). Available (sample): \(sample)")
            }
            voices = requested
        } else {
            voices = Array(allVoices.prefix(count))
        }

        let character = args.string("characterId").flatMap { editor.character(id: $0) }
        let line = Self.auditionLine(args, character: character, minLength: model.minPromptLength)
        let folderId = try resolveFolderId(args, editor: editor)
        let duration = model.reconciledDuration(args.int("duration"))

        var results: [[String: Any]] = []
        for voice in voices {
            let params = AudioGenerationParams(
                prompt: line, voice: voice, lyrics: nil, styleInstructions: nil,
                instrumental: false, durationSeconds: duration
            )
            if let err = model.validate(params: params) {
                throw ToolError("Voice '\(voice)': \(err)")
            }
            var genInput = GenerationInput(
                prompt: line, model: model.id, duration: duration ?? 0,
                aspectRatio: "", resolution: nil, voice: voice
            )
            genInput.createdAt = Date()
            let sampleName = character.map { "\($0.name) · \(voice)" } ?? "Voice · \(voice)"
            let pid = AudioGenerationSubmission.make(
                genInput: genInput, model: model, params: params, name: sampleName, folderId: folderId
            ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
            results.append(["voice": voice, "assetId": pid])
        }

        // Samples surface in the character's Voice section so the user can lock one.
        if var c = character {
            let ids = results.compactMap { $0["assetId"] as? String }
            c.voiceSampleAssetIds += ids.filter { !c.voiceSampleAssetIds.contains($0) }
            editor.upsertCharacter(c)
        }

        let body: [String: Any] = [
            "model": model.id,
            "line": line,
            "samples": results,
            "hint": "Samples are generating. Call wait_for_media with the sample asset ids, inspect_media to listen, then call lock_voice with the chosen voice and this model id (pass voiceReferenceMediaRef with the winning sample to also lock it as the audio reference for shot generation).",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - lock_voice

    func lockVoice(_ editor: EditorViewModel, _ args: [String: Any]) throws -> ToolResult {
        let characterId = try args.requireString("characterId")
        guard var character = editor.character(id: characterId) else {
            throw ToolError("Character not found: \(characterId). Call get_shot_plan to list characters.")
        }
        let voiceId = try args.requireString("voiceId")
        let voiceModel = args.string("voiceModel")
        if let vm = voiceModel {
            guard let model = AudioModelConfig.allModels.first(where: { $0.id == vm }) else {
                throw ToolError("Unknown audio model '\(vm)'.")
            }
            if let voices = model.voices, !voices.isEmpty, !voices.contains(voiceId) {
                let sample = Array(voices.prefix(10)).joined(separator: ", ")
                throw ToolError("Voice '\(voiceId)' isn't offered by \(vm). Available (sample): \(sample)")
            }
        }
        character.lockedVoiceId = voiceId
        character.voiceModel = voiceModel

        // Optionally lock an existing audio asset (e.g. the winning audition
        // sample) as the character's voice reference for shot generation.
        var lockedVoiceRef: String?
        if let voiceRef = args.string("voiceReferenceMediaRef") {
            let a = try asset(voiceRef, editor: editor, label: "Voice reference")
            guard a.type == .audio else {
                throw ToolError("voiceReferenceMediaRef '\(voiceRef)' must be an audio asset (got \(a.type.rawValue)).")
            }
            character.voiceReferenceAssetId = voiceRef
            if !character.voiceSampleAssetIds.contains(voiceRef) {
                character.voiceSampleAssetIds.append(voiceRef)
            }
            lockedVoiceRef = voiceRef
        }
        editor.upsertCharacter(character)

        // No reference supplied: generate a canonical sample in the locked voice
        // and auto-lock it once it finishes, so shots pick it up by default.
        var generatingRefId: String?
        if lockedVoiceRef == nil, character.voiceReferenceAssetId == nil, AccountService.shared.hasVeniceKey {
            generatingRefId = generateVoiceReference(editor, character: character)
        }

        var body: [String: Any] = [
            "id": character.id,
            "name": character.name,
            "lockedVoiceId": voiceId,
            "voiceModel": voiceModel as Any,
        ]
        if let lockedVoiceRef {
            body["voiceReferenceAssetId"] = lockedVoiceRef
            body["hint"] = "Voice and voice reference locked. Shots with this character attach the reference audio automatically when the model supports audio input."
        } else if let generatingRefId {
            body["generatingVoiceReferenceAssetId"] = generatingRefId
            body["hint"] = "Voice locked. A canonical voice-reference sample is generating and will auto-lock when ready — shots with this character then attach it as the audio reference by default."
        }
        return .ok(Self.jsonString(body) ?? "{}")
    }

    /// Generates a spoken reference line in the character's locked voice and
    /// auto-locks it as the voice reference on completion.
    private func generateVoiceReference(_ editor: EditorViewModel, character: CharacterSpec) -> String? {
        let model = character.voiceModel
            .flatMap { vm in AudioModelConfig.allModels.first { $0.id == vm && ModelPreferences.shared.isEnabled($0.id) } }
            ?? AudioModelConfig.allModels.first {
                $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
            }
        guard let model else { return nil }
        var line = EditorViewModel.voiceReferenceLine(name: character.name)
        if line.count < model.minPromptLength {
            line += " " + String(repeating: "Testing one two three. ", count: max(1, (model.minPromptLength - line.count) / 22 + 1))
        }
        let voice = character.lockedVoiceId ?? model.defaultVoice ?? model.voices?.first
        let params = AudioGenerationParams(
            prompt: line, voice: voice, lyrics: nil, styleInstructions: nil,
            instrumental: false, durationSeconds: nil
        )
        guard model.validate(params: params) == nil else { return nil }
        var genInput = GenerationInput(
            prompt: line, model: model.id, duration: 0,
            aspectRatio: "", resolution: nil, voice: voice
        )
        genInput.createdAt = Date()
        let characterId = character.id
        let pid = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params,
            name: "\(character.name.isEmpty ? "Character" : character.name) · voice ref", folderId: nil
        ).submit(
            service: editor.generationService,
            projectURL: editor.projectURL,
            editor: editor,
            onComplete: { [weak editor] asset in
                guard let editor, var c = editor.character(id: characterId) else { return }
                if !c.voiceSampleAssetIds.contains(asset.id) { c.voiceSampleAssetIds.append(asset.id) }
                // Don't stomp a reference the user locked while this generated.
                if c.voiceReferenceAssetId == nil { c.voiceReferenceAssetId = asset.id }
                editor.upsertCharacter(c)
            }
        )
        var updated = character
        if !updated.voiceSampleAssetIds.contains(pid) { updated.voiceSampleAssetIds.append(pid) }
        editor.upsertCharacter(updated)
        return pid
    }

    // MARK: - Helpers

    /// Style suffix for character reference generations. "character reference
    /// sheet / character design" reads as illustration to image models and
    /// produced cartoons in otherwise photoreal productions — anchor to the
    /// same cinematic-photograph language the storyboard panels use.
    static let characterRefStyleSuffix =
        "cinematic film still, photorealistic, natural skin texture, consistent appearance across shots, neutral studio background, soft key light"

    /// Object/prop counterpart: a clean product-style reference plate, no people,
    /// no face-specific language (which pushed image models toward illustration).
    static let objectRefStyleSuffix =
        "cinematic film still, photorealistic product reference shot, consistent object across shots, neutral seamless background, soft even studio light, no people"

    /// Default view ladder for object/prop reference generation.
    static let objectPoses = [
        "front view",
        "three-quarter view",
        "side profile view",
        "detail close-up",
    ]

    /// Location counterpart: environment plates, no people.
    static let locationRefStyleSuffix =
        "cinematic film still, photorealistic, location establishing plate, no people, consistent environment across shots, natural light"

    /// Default angle ladder for location reference generation.
    static let locationAngles = [
        "wide establishing shot",
        "medium shot from the main entrance perspective",
        "detail shot of a distinctive feature",
        "reverse angle",
    ]

    private func resolveImageModel(_ args: [String: Any]) throws -> ImageModelConfig? {
        if let id = args.string("model") {
            guard let model = ImageModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown image model '\(id)'.")
            }
            guard ModelPreferences.shared.isEnabled(id) else {
                throw ToolError("Image model '\(id)' is turned off in Settings → Models.")
            }
            return model
        }
        return ImageModelConfig.allModels.first { ModelPreferences.shared.isEnabled($0.id) }
    }

    private func resolveTTSModel(_ args: [String: Any]) throws -> AudioModelConfig? {
        if let id = args.string("model") {
            guard let model = AudioModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown audio model '\(id)'.")
            }
            guard ModelPreferences.shared.isEnabled(id) else {
                throw ToolError("Audio model '\(id)' is turned off in Settings → Models.")
            }
            return model
        }
        return AudioModelConfig.allModels.first {
            $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
        }
    }

    private static func referencePoses(_ args: [String: Any], count: Int, kind: CharacterKind) -> [String] {
        let provided = args.stringArray("poses")
        let personBase = [
            "front view, facing the camera, neutral expression",
            "three-quarter view",
            "profile side view",
            "full-body shot",
        ]
        let base = provided.isEmpty ? (kind == .object ? objectPoses : personBase) : provided
        guard !base.isEmpty else { return Array(repeating: "front view", count: count) }
        return (0..<count).map { base[$0 % base.count] }
    }

    /// The line spoken in each voice sample; padded to the model's minimum prompt length.
    private static func auditionLine(_ args: [String: Any], character: CharacterSpec?, minLength: Int) -> String {
        var line = args.string("text") ?? args.string("line")
            ?? "Hi, I'm \(character?.name ?? "your character"). This is how I sound — let me know if this voice fits."
        if line.count < minLength {
            line += " " + String(repeating: "Testing one two three. ", count: max(1, (minLength - line.count) / 22 + 1))
        }
        return line
    }
}
