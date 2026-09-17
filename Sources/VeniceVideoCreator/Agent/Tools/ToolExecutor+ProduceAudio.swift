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

        let fps = editor.timeline.fps
        // A single global cursor schedules every spoken line: small gap between
        // lines, no lead into the shot. Dialogue only lands where a shot's video
        // is already placed (harness order: produce_shots THEN produce_audio) —
        // an unplaced shot has no timeline position, so its lines would pile at
        // frame 0 (the exact anti-pattern-19 bug).
        let gapFrames = max(1, secondsToFrame(seconds: 0.12, fps: fps))
        let leadFrames = 0
        let duckWindows = try dialogueDuckWindows(plan: plan, editor: editor, leadFrames: leadFrames, gapFrames: gapFrames)

        var dialogueClips: [[String: Any]] = []
        var beds: [[String: Any]] = []
        var skippedUnplaced: [String] = []

        // MARK: Dialogue
        if wantDialogue {
            let fallbackModel = try defaultTTSModel()

            // Resolve every placeable line first (model/voice/estimate + the
            // shot's timeline start), in plan → dialogue order, skipping unplaced
            // shots and blank lines.
            struct PlannedLine {
                let shot: Shot
                let line: ShotDialogue
                let model: AudioModelConfig
                let voice: String?
                let estSeconds: Double
                let shotStartFrame: Int
            }
            var planned: [PlannedLine] = []
            for shot in targets {
                guard !shot.dialogue.isEmpty else { continue }
                guard let startFrame = try shotStartFrame(shot, editor: editor) else {
                    skippedUnplaced.append(shot.slug ?? shot.id)
                    continue
                }
                for line in shot.dialogue where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                    let character = line.characterId.flatMap { plan.character(id: $0) }
                    let model = try dialogueModel(for: character, fallback: fallbackModel)
                    let voice = character?.lockedVoiceId ?? model.defaultVoice
                    planned.append(PlannedLine(
                        shot: shot, line: line, model: model, voice: voice,
                        estSeconds: Self.estimateSpeechSeconds(line.text), shotStartFrame: startFrame
                    ))
                }
            }

            let placements = DialogueScheduler.schedule(
                lines: planned.map {
                    DialogueScheduler.Line(
                        shotStartFrame: $0.shotStartFrame,
                        estimatedFrames: max(1, secondsToFrame(seconds: $0.estSeconds, fps: fps))
                    )
                },
                leadFrames: leadFrames, gapFrames: gapFrames
            )

            // Ordered lane so a clip that renders longer than its estimate
            // ripples the later lines instead of overlapping them, once the real
            // duration lands (reflowProductionDialogueLane on each completion).
            var laneEntries: [(clipId: String, desiredStart: Int)] = []
            let lane = DialogueLaneBox()
            for (planLine, placement) in zip(planned, placements) {
                let model = planLine.model
                let params = AudioGenerationParams(
                    prompt: planLine.line.text, voice: planLine.voice, lyrics: nil, styleInstructions: nil,
                    instrumental: false, durationSeconds: model.reconciledDuration(nil)
                )
                if let err = model.validate(params: params) {
                    throw ToolError("Dialogue for shot \(planLine.shot.slug ?? planLine.shot.id): \(err)")
                }
                var genInput = GenerationInput(
                    prompt: planLine.line.text, model: model.id, duration: 0,
                    aspectRatio: "", resolution: nil, voice: planLine.voice
                )
                genInput.createdAt = Date()
                let placeholderId = AudioGenerationSubmission.make(
                    genInput: genInput, model: model, params: params,
                    name: "Dialogue · \(planLine.shot.slug ?? "shot")"
                ).submit(
                    service: editor.generationService, projectURL: editor.projectURL, editor: editor,
                    onComplete: { asset in
                        editor.finalizeGeneratingClip(placeholderId: asset.id, asset: asset)
                        editor.reflowProductionDialogueLane(lane.entries, gapFrames: gapFrames)
                    }
                )
                if let clipId = editor.placeGeneratingAudioClip(
                    placeholderId: placeholderId, startFrame: placement.startFrame,
                    spanSeconds: Double(placement.estimatedFrames) / Double(max(1, fps)),
                    actionName: "Add Dialogue"
                ) {
                    laneEntries.append((clipId: clipId, desiredStart: placement.startFrame))
                    lane.entries = laneEntries
                }
                dialogueClips.append([
                    "shotId": planLine.shot.id, "assetId": placeholderId,
                    "voice": planLine.voice as Any, "startFrame": placement.startFrame,
                ])
            }
        }

        // MARK: Music bed
        if wantMusic {
            let model = try defaultMusicModel(args.string("musicModel"))
            let prompt = args.string("musicPrompt") ?? plan.logline ?? "Cinematic score for \(plan.title)"
            if let bed = try submitBed(prompt: prompt, model: model, plan: plan, editor: editor, actionName: "Add Music", duckWindows: duckWindows) {
                beds.append(["kind": "music", "assetId": bed])
            }
        }

        // MARK: Ambient / SFX bed
        if wantAmbient {
            let model = try defaultMusicModel(args.string("ambientModel"))
            let prompt = args.string("ambientPrompt") ?? "Subtle ambient background bed for \(plan.title)"
            if let bed = try submitBed(prompt: prompt, model: model, plan: plan, editor: editor, actionName: "Add Ambient", duckWindows: duckWindows) {
                beds.append(["kind": "ambient", "assetId": bed])
            }
        }

        var hint = "Audio is generating and placed on the timeline; clips resolve as each finishes (poll get_media). For subtitles, run add_captions over the timeline."
        if !skippedUnplaced.isEmpty {
            hint = "Skipped dialogue for unplaced shot(s) \(skippedUnplaced.joined(separator: ", ")) — run produce_shots first so each shot has a timeline position, then produce_audio. " + hint
        }
        let body: [String: Any] = [
            "dialogueClips": dialogueClips,
            "beds": beds,
            "skippedUnplacedShots": skippedUnplaced,
            "hint": hint,
        ]
        return .ok(Self.jsonString(body) ?? "{}")
    }

    /// Absolute-frame windows where dialogue sits, for ducking a bed beneath it.
    /// Uses the same global scheduler as placement so the envelope matches the
    /// lines regardless of whether they were generated this call.
    private func dialogueDuckWindows(
        plan: ShotPlan, editor: EditorViewModel, leadFrames: Int, gapFrames: Int
    ) throws -> [ClosedRange<Int>] {
        let fps = editor.timeline.fps
        var lines: [DialogueScheduler.Line] = []
        for shot in plan.shots {
            guard !shot.dialogue.isEmpty, let start = try shotStartFrame(shot, editor: editor) else { continue }
            for line in shot.dialogue where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append(DialogueScheduler.Line(
                    shotStartFrame: start,
                    estimatedFrames: max(1, secondsToFrame(seconds: Self.estimateSpeechSeconds(line.text), fps: fps))
                ))
            }
        }
        guard !lines.isEmpty else { return [] }
        return DialogueScheduler.schedule(lines: lines, leadFrames: leadFrames, gapFrames: gapFrames)
            .map { $0.startFrame...($0.startFrame + $0.estimatedFrames) }
    }

    // MARK: - Bed placement

    private func submitBed(
        prompt: String, model: AudioModelConfig, plan: ShotPlan, editor: EditorViewModel,
        actionName: String, duckWindows: [ClosedRange<Int>] = []
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
        let clipId = editor.placeGeneratingAudioClip(
            placeholderId: placeholderId, startFrame: 0, spanSeconds: spanSeconds, actionName: actionName
        )
        // Duck the bed under every dialogue window (harness auto-duck) rather
        // than leaving a static full-volume bed over speech.
        if let clipId, !duckWindows.isEmpty {
            editor.duckBedUnderDialogue(bedClipId: clipId, windows: duckWindows)
        }
        return placeholderId
    }

    // MARK: - Helpers

    /// Timeline start frame for a shot: its placed video clip position, or nil
    /// when the shot has no placed clip yet. A shot without a position must NOT
    /// default to frame 0 — that piles every unplaced shot's dialogue at the
    /// head of the timeline (anti-pattern 19).
    func shotStartFrame(_ shot: Shot, editor: EditorViewModel) throws -> Int? {
        try editor.productionClip(for: shot)?.startFrame
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

/// Shared, mutable ordered dialogue lane captured by each line's completion
/// closure so the last-completing clip re-flows the whole lane against the
/// final set of measured durations. @MainActor because the closures run there.
@MainActor
private final class DialogueLaneBox {
    var entries: [(clipId: String, desiredStart: Int)] = []
}
