import Foundation

extension ToolExecutor {
    func produceAudio(_ editor: EditorViewModel, _ args: [String: Any]) async throws -> ToolResult {
        guard let plan = editor.shotPlan else { throw ToolError("No shot plan yet.") }
        let dialogue = args.bool("dialogue") ?? true
        let music = args.bool("music") ?? false
        let ambient = args.bool("ambient") ?? false
        guard dialogue || music || ambient else { throw ToolError("Request dialogue, music, or ambient audio.") }
        let ids = Set(args.stringArray("shotIds"))
        for id in ids where plan.shot(id: id) == nil { throw ToolError("Shot not found: \(id)") }
        let coordinator = editor.productionAudioCoordinator
        var requests: [ProductionAudioCoordinator.Request] = []
        var skipped: [String] = []
        var nativeLines: [[String: String]] = []
        if dialogue {
            for shot in plan.shots where ids.isEmpty || ids.contains(shot.id) {
                guard !shot.dialogue.isEmpty else { continue }
                guard try shotStartFrame(shot, editor: editor) != nil else { skipped.append(shot.id); continue }
                for line in shot.dialogue where !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard line.voiceOver else {
                        nativeLines.append(["shotId": shot.id, "lineId": line.id, "status": "nativeSpeechUnverified"])
                        continue
                    }
                    let character = line.characterId.flatMap { plan.character(id: $0) }
                    let model = try dialogueModel(for: character)
                    let voice = character?.lockedVoiceId ?? model.defaultVoice
                    let params = AudioGenerationParams(prompt: line.text, voice: voice, lyrics: nil, styleInstructions: nil,
                                                       instrumental: false, durationSeconds: model.reconciledDuration(nil))
                    let input = GenerationInput(prompt: line.text, model: model.id, duration: params.durationSeconds ?? 0,
                                                aspectRatio: "", resolution: nil, voice: voice)
                    let estimate = max(1, Double(line.text.split(whereSeparator: \.isWhitespace).count) / 2.7)
                    requests.append(.init(key: .init(role: .dialogue, shotId: shot.id, lineId: line.id), input: input,
                                          model: model, params: params, name: "Dialogue · \(shot.slug ?? "shot")",
                                          estimatedFrames: max(1, secondsToFrame(seconds: estimate, fps: editor.timeline.fps))))
                }
            }
        }
        for role in [ProductionAudioOperation.Role.music, .ambient] where role == .music ? music : ambient {
            guard coordinator.pictureEnd > 0 else { throw ToolError("Place picture before producing an audio bed.") }
            let model = try defaultMusicModel(args.string("\(role.rawValue)Model"), role: role)
            let prompt = args.string("\(role.rawValue)Prompt") ?? (role == .music
                ? plan.logline ?? "Cinematic score for \(plan.title)" : "Subtle ambient background bed for \(plan.title)")
            let requestedSeconds = Int((Double(coordinator.pictureEnd) / Double(editor.timeline.fps)).rounded(.up))
            let duration = model.durations?.filter { $0 >= requestedSeconds }.min()
            if model.durations?.isEmpty == false, duration == nil { throw ToolError("The selected bed model cannot cover this cut. Select a model with a longer duration.") }
            let params = AudioGenerationParams(prompt: prompt, voice: nil, lyrics: nil, styleInstructions: nil,
                                               instrumental: model.supportsInstrumental, durationSeconds: duration)
            let input = GenerationInput(prompt: prompt, model: model.id, duration: duration ?? 0,
                                        aspectRatio: "", resolution: nil, instrumental: model.supportsInstrumental)
            requests.append(.init(key: .init(role: role), input: input, model: model, params: params,
                                  name: role == .music ? "Music" : "Ambient", estimatedFrames: coordinator.pictureEnd))
        }
        for request in requests {
            if let error = request.model.validate(params: request.params) { throw ToolError(error) }
        }
        var records: [[String: Any]] = []
        for request in requests {
            let id = try coordinator.submit(request, regenerate: args.bool("regenerate") ?? false)
            guard let record = coordinator.operation(id) else { throw ToolError("Audio operation was not retained.") }
            var summary: [String: Any] = ["operationId": id, "role": record.key.role.rawValue, "clipId": record.clipId, "stage": record.stage.rawValue]
            if let value = record.key.shotId { summary["shotId"] = value }
            if let value = record.key.lineId { summary["lineId"] = value }
            if let value = record.placeholderId { summary["assetId"] = value }
            if let value = record.failureReason { summary["failureReason"] = value }
            records.append(summary)
        }
        return .ok(Self.jsonString([
            "audioOperations": records, "skippedUnplacedShots": skipped, "nativeSpeechLines": nativeLines,
            "hint": "Audio attempts are retained. Completed output is measured and placed only when it fits picture. Repeat produce_audio to inspect or finish the same attempts; regenerate explicitly buys new attempts. On-screen lines remain owned by native video and are not transcript/lip-sync verified."
        ]) ?? "{}")
    }

    func shotStartFrame(_ shot: Shot, editor: EditorViewModel) throws -> Int? {
        try editor.productionClip(for: shot)?.startFrame
    }

    private func dialogueModel(for character: CharacterSpec?) throws -> AudioModelConfig {
        if let id = character?.voiceModel {
            guard let model = AudioModelConfig.allModels.first(where: { $0.id == id && $0.category == .tts }),
                  ModelPreferences.shared.isEnabled(id) else { throw ToolError("Enable the character's locked TTS model '\(id)' in Settings.") }
            return model
        }
        guard let model = AudioModelConfig.allModels.first(where: {
            $0.category == .tts && $0.voices?.isEmpty == false && ModelPreferences.shared.isEnabled($0.id)
        }) ?? AudioModelConfig.allModels.first(where: { $0.category == .tts && ModelPreferences.shared.isEnabled($0.id) }) else {
            throw ToolError("Enable a text-to-speech model in Settings.")
        }
        return model
    }

    private func defaultMusicModel(_ requested: String?, role: ProductionAudioOperation.Role) throws -> AudioModelConfig {
        func compatible(_ model: AudioModelConfig) -> Bool {
            model.inputs.contains(.text) && !model.inputs.contains(.video)
                && (model.category == .music || (role == .ambient && model.category == .sfx))
        }
        if let id = requested {
            guard let model = AudioModelConfig.allModels.first(where: { $0.id == id && compatible($0) }),
                  ModelPreferences.shared.isEnabled(id) else { throw ToolError("Enable the selected music model '\(id)' in Settings.") }
            return model
        }
        guard let model = AudioModelConfig.allModels.first(where: { compatible($0) && ModelPreferences.shared.isEnabled($0.id) }) else {
            throw ToolError("Enable a music model in Settings.")
        }
        return model
    }
}
