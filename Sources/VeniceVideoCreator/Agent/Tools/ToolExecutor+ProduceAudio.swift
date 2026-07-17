import Foundation

extension ToolExecutor {
    // MARK: - produce_audio

    /// Generates the production's audio layers and places them on the timeline: per-shot
    /// dialogue (TTS in each character's locked voice), an optional music bed, and an optional
    /// ambient/SFX bed. Dialogue is placed at each shot's timeline position on the dialogue
    /// lane; music/ambient span the whole edit. Async — clips resolve as generation finishes.
    func produceAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        guard AccountService.shared.hasVeniceKey else {
            throw ToolError("Audio generation requires a Venice API key. Tell the user to add it in Settings.")
        }

        let wantDialogue = args.bool("dialogue") ?? true
        let wantMusic = args.bool("music") ?? false
        let wantAmbient = args.bool("ambient") ?? false
        guard wantDialogue || wantMusic || wantAmbient else {
            throw ToolError("Nothing requested. Set dialogue, music, and/or ambient to true.")
        }

        let requestedIds = Set(args.stringArray("shotIds"))
        let targets = plan.shots.filter { requestedIds.isEmpty || requestedIds.contains($0.id) }

        var dialogueClips: [[String: Any]] = []
        var beds: [[String: Any]] = []

        // MARK: Dialogue
        if wantDialogue {
            let fallbackModel = try defaultTTSModel()
            for shot in targets {
                guard !shot.dialogue.isEmpty else { continue }
                let startFrame = shotStartFrame(shot, editor: editor)
                var offsetFrames = 0
                for line in shot.dialogue where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let character = line.characterId.flatMap { plan.character(id: $0) }
                    let model = try dialogueModel(for: character, fallback: fallbackModel)
                    let voice = character?.lockedVoiceId ?? model.defaultVoice
                    let estSeconds = Self.estimateSpeechSeconds(line.text)
                    let params = AudioGenerationParams(
                        prompt: line.text, voice: voice, lyrics: nil, styleInstructions: nil,
                        instrumental: false, durationSeconds: model.reconciledDuration(nil)
                    )
                    if let err = model.validate(params: params) {
                        throw ToolError("Dialogue for shot \(shot.slug ?? shot.id): \(err)")
                    }
                    var genInput = GenerationInput(
                        prompt: line.text, model: model.id, duration: 0,
                        aspectRatio: "", resolution: nil, voice: voice
                    )
                    genInput.createdAt = Date()
                    let placeStart = startFrame + offsetFrames
                    let placeholderId = AudioGenerationSubmission.make(
                        genInput: genInput, model: model, params: params,
                        name: "Dialogue · \(shot.slug ?? "shot")"
                    ).submit(
                        service: editor.generationService, projectURL: editor.projectURL, editor: editor,
                        onComplete: { asset in editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset) }
                    )
                    editor.placeGeneratingAudioClip(
                        placeholderId: placeholderId, startFrame: placeStart,
                        spanSeconds: estSeconds, actionName: "Add Dialogue"
                    )
                    offsetFrames += max(1, secondsToFrame(seconds: estSeconds, fps: editor.timeline.fps))
                    dialogueClips.append(["shotId": shot.id, "assetId": placeholderId, "voice": voice as Any])
                }
            }
        }

        // MARK: Music bed
        if wantMusic {
            let model = try defaultMusicModel(args.string("musicModel"))
            let prompt = args.string("musicPrompt") ?? plan.logline ?? "Cinematic score for \(plan.title)"
            if let bed = try submitBed(prompt: prompt, model: model, plan: plan, editor: editor, actionName: "Add Music") {
                beds.append(["kind": "music", "assetId": bed])
            }
        }

        // MARK: Ambient / SFX bed
        if wantAmbient {
            let model = try defaultMusicModel(args.string("ambientModel"))
            let prompt = args.string("ambientPrompt") ?? "Subtle ambient background bed for \(plan.title)"
            if let bed = try submitBed(prompt: prompt, model: model, plan: plan, editor: editor, actionName: "Add Ambient") {
                beds.append(["kind": "ambient", "assetId": bed])
            }
        }

        let body: [String: Any] = [
            "dialogueClips": dialogueClips,
            "beds": beds,
            "hint": "Audio is generating and placed on the timeline; clips resolve as each finishes (poll get_media). For subtitles, run add_captions over the timeline.",
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    // MARK: - Bed placement

    private func submitBed(
        prompt: String, model: AudioModelConfig, plan: ShotPlan, editor: EditorViewModel, actionName: String
    ) throws -> String? {
        let totalFrames = editor.timeline.totalFrames
        let spanSeconds = totalFrames > 0
            ? Double(totalFrames) / Double(max(1, editor.timeline.fps))
            : max(plan.totalPlannedSeconds, 5)
        let duration = model.reconciledDuration(Int(spanSeconds.rounded()))
        let params = AudioGenerationParams(
            prompt: prompt, voice: nil, lyrics: nil, styleInstructions: nil,
            instrumental: false, durationSeconds: duration
        )
        if let err = model.validate(params: params) { throw ToolError("\(actionName): \(err)") }
        var genInput = GenerationInput(
            prompt: prompt, model: model.id, duration: duration ?? 0, aspectRatio: "", resolution: nil
        )
        genInput.createdAt = Date()
        let placeholderId = AudioGenerationSubmission.make(
            genInput: genInput, model: model, params: params, name: actionName
        ).submit(
            service: editor.generationService, projectURL: editor.projectURL, editor: editor,
            onComplete: { asset in editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset) }
        )
        editor.placeGeneratingAudioClip(
            placeholderId: placeholderId, startFrame: 0, spanSeconds: spanSeconds, actionName: actionName
        )
        return placeholderId
    }

    // MARK: - Helpers

    /// Timeline start frame for a shot: its placed video clip position, else end of the
    /// production video track (append), else 0.
    private func shotStartFrame(_ shot: Shot, editor: EditorViewModel) -> Int {
        if let assetId = shot.videoAssetId,
           let clipId = editor.productionClipId(forAsset: assetId),
           let clip = editor.clipFor(id: clipId) {
            return clip.startFrame
        }
        return 0
    }

    private func defaultTTSModel() throws -> AudioModelConfig {
        guard let model = AudioModelConfig.allModels.first(where: {
            $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
        }) ?? AudioModelConfig.allModels.first(where: { $0.category == .tts && ModelPreferences.shared.isEnabled($0.id) }) else {
            throw ToolError("No enabled text-to-speech model available. Turn one on in Settings → Models.")
        }
        return model
    }

    private func dialogueModel(for character: CharacterSpec?, fallback: AudioModelConfig) throws -> AudioModelConfig {
        guard let vm = character?.voiceModel else { return fallback }
        guard let model = AudioModelConfig.allModels.first(where: { $0.id == vm }) else {
            throw ToolError("Character's locked voice model '\(vm)' isn't available.")
        }
        return model
    }

    private func defaultMusicModel(_ requested: String?) throws -> AudioModelConfig {
        if let id = requested {
            guard let model = AudioModelConfig.allModels.first(where: { $0.id == id }) else {
                throw ToolError("Unknown audio model '\(id)'.")
            }
            return model
        }
        guard let model = AudioModelConfig.allModels.first(where: {
            $0.category == .music && ModelPreferences.shared.isEnabled($0.id)
        }) else {
            throw ToolError("No enabled music model available. Turn one on in Settings → Models.")
        }
        return model
    }

    /// Rough spoken-duration estimate (~2.7 words/sec) for placing dialogue before the real
    /// clip length is known; finalizeGeneratingClip corrects it on completion.
    private static func estimateSpeechSeconds(_ text: String) -> Double {
        let words = text.split { $0 == " " || $0 == "\n" }.count
        return max(1.0, Double(words) / 2.7)
    }
}
