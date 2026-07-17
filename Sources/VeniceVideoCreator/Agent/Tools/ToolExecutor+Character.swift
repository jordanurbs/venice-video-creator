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

        var character = CharacterSpec(name: name, description: description)

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
            let poses = Self.characterPoses(args, count: count)
            for (i, pose) in poses.enumerated() {
                let fullPrompt = "\(visualPrompt), \(pose), character reference sheet, consistent character design, clean neutral background"
                var genInput = GenerationInput(
                    prompt: fullPrompt, model: model.id, duration: 0,
                    aspectRatio: aspectRatio, resolution: resolution, quality: quality
                )
                genInput.hasFace = true
                let pid = ImageGenerationSubmission.make(
                    genInput: genInput, model: model, references: [],
                    name: "\(name) · ref \(i + 1)", folderId: folderId
                ).submit(service: editor.generationService, projectURL: editor.projectURL, editor: editor)
                generatedIds.append(pid)
            }
        }

        character.referenceImageAssetIds = attachedRefs.map(\.id) + generatedIds
        character.provenance = CharacterProvenance(generationModel: modelUsed, hasFace: true)
        editor.upsertCharacter(character)

        var body: [String: Any] = [
            "id": character.id,
            "name": character.name,
            "referenceImageAssetIds": character.referenceImageAssetIds,
        ]
        if !generatedIds.isEmpty {
            body["generatingAssetIds"] = generatedIds
            body["hint"] = "Reference images are generating. Poll get_media until these assets finish, inspect them, then audition_voices and lock_voice."
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

        let body: [String: Any] = [
            "model": model.id,
            "line": line,
            "samples": results,
            "hint": "Samples are generating. Poll get_media until they finish, inspect_media to listen, then call lock_voice with the chosen voice and this model id.",
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
        editor.upsertCharacter(character)
        let body: [String: Any] = [
            "id": character.id,
            "name": character.name,
            "lockedVoiceId": voiceId,
            "voiceModel": voiceModel as Any,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - Helpers

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

    private static func characterPoses(_ args: [String: Any], count: Int) -> [String] {
        let provided = args.stringArray("poses")
        let base = provided.isEmpty
            ? [
                "front view, facing the camera, neutral expression",
                "three-quarter view",
                "profile side view",
                "full-body shot",
            ]
            : provided
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
