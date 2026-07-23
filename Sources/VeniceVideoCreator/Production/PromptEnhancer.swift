import Foundation

/// Generates or enhances a shot/character prompt from project context — the
/// shot plan (title, logline, sibling shot prompts, cast) plus project
/// documents (script, treatment). One cheap non-streaming completion; the
/// result lands in the inspector draft for review, never auto-saved.
@MainActor
enum PromptEnhancer {

    enum Target {
        case shot(Shot)
        case character(CharacterSpec)
        case location(LocationSpec)
    }

    static func enhance(_ target: Target, current: String, editor: EditorViewModel) async -> String? {
        guard let api = VeniceAPI.fromKeychain() else { return nil }
        let context = contextBlock(editor: editor)
        let (role, task) = instruction(for: target, current: current)

        let system = """
        You write image/video generation prompts for a film production. \
        Match the production's established visual style EXACTLY — if sibling prompts \
        are photorealistic documentary, stay photorealistic documentary; never drift \
        into illustration. Output ONLY the prompt text: no quotes, no preamble, no \
        explanations, no trailing style suffix like 'cinematic storyboard frame' \
        (the app appends those). Target 20-40 words of concrete nouns: subject, \
        setting, framing, lighting, mood.
        """
        let user = "\(context)\n\n\(role)\n\n\(task)"

        let body: [String: Any] = [
            "model": modelId(),
            "max_tokens": 300,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        guard let obj = try? await api.postJSON(path: "chat/completions", body: body),
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { return nil }
        let cleaned = content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return cleaned.isEmpty ? nil : cleaned
    }

    // MARK: - Pieces

    /// Fastest enabled text model (same heuristic as chat-recap summarization).
    private static func modelId() -> String {
        let available = ModelCatalog.shared.textModels
        let ids = Set(available.map(\.id))
        if let fastest = ModelTraitsCatalog.shared.textTraits["fastest"] {
            let resolved = ModelTraitsCatalog.shared.resolve(fastest)
            if ids.contains(resolved) { return resolved }
        }
        return available.first?.id ?? "qwen-2.5-qwq-32b"
    }

    private static func instruction(for target: Target, current: String) -> (role: String, task: String) {
        switch target {
        case .shot(let shot):
            let role = """
            TARGET SHOT: \(shot.slug ?? shot.id)
            Summary: \(shot.summary.isEmpty ? "(none)" : shot.summary)
            Motion: \(shot.motionLevel.rawValue)
            """
            let task = current.isEmpty
                ? "Write the generation prompt for this shot, consistent with the sibling prompts' style."
                : "Improve this prompt — keep its intent, sharpen the visual language, match the production style:\n\(current)"
            return (role, task)
        case .character(let character):
            let role = """
            TARGET CHARACTER: \(character.name)
            Description: \(character.description ?? "(none)")
            """
            let task = current.isEmpty || current == character.description || current == character.name
                ? "Write the reference-image prompt for this character: age, build, face, hair, wardrobe, in the production's visual style. Describe the PERSON only — no pose or framing (the app adds those)."
                : "Improve this character reference prompt — keep identity, add missing physical specifics, match the production style:\n\(current)"
            return (role, task)
        case .location(let location):
            let role = """
            TARGET LOCATION: \(location.name)
            Description: \(location.description ?? "(none)")
            """
            let task = current.isEmpty || current == location.description || current == location.name
                ? "Write the reference-plate prompt for this location: architecture, era, condition, palette, atmosphere, in the production's visual style. Describe the PLACE only — no people, no camera angle (the app adds those)."
                : "Improve this location reference prompt — keep the place's identity, add missing environmental specifics, match the production style:\n\(current)"
            return (role, task)
        }
    }

    /// Compact project context: plan header, cast, sibling prompts, doc excerpts.
    private static func contextBlock(editor: EditorViewModel) -> String {
        var out: [String] = ["PROJECT CONTEXT:"]
        if let plan = editor.shotPlan {
            out.append("Title: \(plan.title)")
            if let logline = plan.logline, !logline.isEmpty { out.append("Logline: \(logline)") }
            let styled = plan.shots.filter { !$0.prompt.isEmpty }.prefix(6)
            if !styled.isEmpty {
                out.append("Existing shot prompts (match this style):")
                for s in styled {
                    out.append("- [\(s.slug ?? s.id)] \(s.prompt)")
                }
            }
            if !plan.characters.isEmpty {
                out.append("Cast:")
                for c in plan.characters {
                    out.append("- \(c.name): \(c.description ?? c.effectiveVisualPrompt)")
                }
            }
            if !plan.locations.isEmpty {
                out.append("Locations:")
                for l in plan.locations {
                    out.append("- \(l.name): \(l.description ?? l.effectiveVisualPrompt)")
                }
            }
        }
        // Most recent documents (script, treatment, etc.), excerpted.
        for doc in editor.documents.prefix(2) where doc.name != EditorViewModel.shotPlanDocumentName {
            out.append("Document '\(doc.name)' (excerpt):\n\(String(doc.content.prefix(2000)))")
        }
        return out.joined(separator: "\n")
    }
}
