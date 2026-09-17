import Foundation

/// Assembles the text prompt sent to the video model for a shot. Kept separate from the
/// orchestrator so the VO/native-audio prompt rules (harness 03a17f4) live in one place and
/// can be unit-tested. Extended in Phase 4 for dialogue/native-audio handling.
enum ShotPromptBuilder {
    /// The prompt string for a shot's video generation.
    ///
    /// VO rule: voice-over / narration lines are never put into the video prompt — the video
    /// model would synthesize a competing narrator. Instead, when a shot is VO-only we append
    /// an explicit suppression line. On-screen dialogue may be described in the prompt.
    ///
    /// Spatial rule (harness rule 49, 2.12.0): when the shot carries authored
    /// `blocking` and/or its location carries `spatialAnchors`, both are restated
    /// verbatim in every generation so geometry is stated identically per take
    /// instead of re-inferred (the source of side-swaps and mirrored geography).
    /// - Parameter slotPlan: when set (an @Image-tag model with slot binding
    ///   active), the prompt gains up-front `@ImageN is …` identity + role
    ///   declarations and substitutes character names with their `@ImageN` tag
    ///   throughout, so the model binds each reference to a slot instead of
    ///   guessing (harness rule 42). Nil keeps the name-in-prose path.
    /// - Parameter model: the routed video model. Simple-prompt models (the
    ///   MiniMax H3 Max family) stage their own camera and geometry from a
    ///   stated intent, and the directorial geometry clauses below — blocking,
    ///   fixed layout, no-mirroring — flatten what they'd otherwise compose, so
    ///   those are dropped for them. Identity (style, @ImageN bindings, traits)
    ///   and the audio rules are model-independent and always kept. Nil keeps
    ///   the full directorial prompt, which is right for every other family.
    static func videoPrompt(
        for shot: Shot,
        plan: ShotPlan? = nil,
        slotPlan: ReferenceSlots.Plan? = nil,
        model: String? = nil
    ) -> String {
        if model == VideoModelCapabilities.multiAngleID,
           shot.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "" }
        var parts: [String] = []
        func tagged(_ text: String) -> String { slotPlan?.substitutingNames(in: text) ?? text }
        let simplePrompt = model.map { VideoModelCapabilities.wantsSimplePrompt(id: $0) } ?? false

        // Locked series style FIRST (harness rule 11): front-loading the visual
        // system prevents per-shot style drift across angles and takes.
        if let style = stylePrefix(plan) { parts.append(style) }

        // @ImageN bindings up front so the model reads them before the beats.
        if let slotPlan, !slotPlan.isEmpty {
            parts.append(contentsOf: slotPlan.identityDeclarations)
            parts.append(contentsOf: slotPlan.roleClauseLines)
        }

        var base = shot.prompt.isEmpty ? shot.summary : shot.prompt
        // Agents copy storyboard prompt style into shot prompts. "film still" /
        // "still frame" tells a VIDEO model to render a motionless frame —
        // the 2026-08-06 run produced near-identical static shots this way.
        for still in ["film still", "still frame", "still image"] {
            base = base.replacingOccurrences(of: still, with: "film scene", options: .caseInsensitive)
        }
        if !base.isEmpty { parts.append(tagged(base)) }

        switch shot.motionLevel {
        case .still: parts.append("static camera, minimal motion")
        case .subtle: parts.append("subtle, gentle motion")
        case .moderate: break
        case .dynamic: parts.append("dynamic camera movement, energetic motion")
        }

        // Authored shot geometry: who stands where, relative to the location's
        // named anchors, the frame, and each other — restated verbatim per take.
        if let blocking = shot.blocking, !blocking.isEmpty, !simplePrompt {
            parts.append("Blocking: \(tagged(blocking))")
        }

        // Locked location geography: named landmarks and their fixed relative
        // positions, plus an explicit no-mirroring clause when the shot also
        // places characters (mirrored/reshuffled geography is the failure mode).
        if let plan, !simplePrompt {
            let anchors = shot.locationIds
                .compactMap { plan.location(id: $0)?.spatialAnchors }
                .filter { !$0.isEmpty }
            if let first = anchors.first {
                parts.append("Fixed layout (never rearrange): \(first)")
                if shot.blocking != nil || !shot.characterIds.isEmpty {
                    parts.append("Each character stays on the same side of the scene and keeps the same position relative to these landmarks; do not mirror, swap, or rearrange who stands where")
                }
            }
        }

        // Restate each character's invariant traits in prose (harness rule 37):
        // @Image tags anchor the FACE, but wardrobe, markings, and relative scale
        // drift across separately-rendered shots unless repeated every time. Kept
        // even when slots are bound; truncated so a long bio can't blow the cap.
        if let plan, !shot.characterIds.isEmpty {
            for cid in shot.characterIds {
                guard let c = plan.character(id: cid),
                      let desc = c.description?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !desc.isEmpty else { continue }
                let trait = desc.count > 160 ? String(desc.prefix(160)) + "…" : desc
                let name = c.name.isEmpty ? "Character" : c.name
                parts.append(tagged("\(name): \(trait)"))
            }
        }

        // On-screen spoken lines can be described; voice-over lines must not reach the prompt.
        let onScreen = shot.onScreenDialogue.map(\.text).filter { !$0.isEmpty }
        if !onScreen.isEmpty {
            parts.append("Characters speak on screen: \(tagged(onScreen.joined(separator: " ")))")
        }

        // If the shot only carries voice-over (and nothing spoken on screen), tell the model
        // to stay silent so it doesn't invent a narrator over the top of the real VO track.
        if shot.hasVoiceOver && onScreen.isEmpty {
            parts.append("No narration, no voice-over, no spoken words in this shot.")
        }

        // Steer what KIND of audio the model generates (content), independent of
        // how the placed clip is mixed (nativeAudio).
        switch shot.audioContent {
        case .full:
            break
        case .noMusic:
            parts.append("Natural ambient sound and effects, no background music.")
        case .ambienceOnly:
            parts.append("Ambient sound and sound effects only — no speech, no music.")
        case .dialogueOnly:
            parts.append("Dialogue only — no background music, minimal ambient noise.")
        }

        return parts.joined(separator: ". ")
    }

    /// The prompt for a storyboard PANEL (harness storyboard pass 1 + rules 49).
    ///
    /// A panel is a tier-2 reference for the video it anchors, so it must carry the
    /// same geometry and lighting as the eventual shot — otherwise a panel with
    /// wrong blocking or a mirrored layout propagates into every take. This mirrors
    /// `videoPrompt`'s spatial clauses (blocking + fixed layout) but drops the
    /// motion/audio steering (a panel is a single still) and adds the location's
    /// locked look + lighting.
    ///
    /// - Parameter matchPreviousPanel: true when the immediately-preceding shot
    ///   shares this location and already has a panel — the panel is passed as an
    ///   extra reference and the prompt asks the model to match its lighting
    ///   (anti-pattern 7 lighting consistency).
    static func storyboardPanelPrompt(
        for shot: Shot,
        plan: ShotPlan? = nil,
        matchPreviousPanel: Bool = false
    ) -> String {
        var parts: [String] = []

        // Locked series style FIRST (harness rule 11) — a panel is a tier-2
        // reference the video anchors on, so it must be authored in the same
        // visual system as every other panel and the final shot.
        if let style = stylePrefix(plan) { parts.append(style) }

        // Prefer the dedicated storyboard prompt (2026-08-10 split); shots
        // without one compose from the video prompt as before.
        let base = shot.effectiveStoryboardBase
        if !base.isEmpty { parts.append(base) }
        parts.append("cinematic storyboard frame")
        parts.append("\(shot.motionLevel.rawValue) motion")

        // Locked location look + lighting so panels of one place cohere. The
        // description grounds the environment; lightingNotes lock the key/fill so
        // consecutive same-location panels don't drift in time of day or mood.
        if let plan {
            let locations = shot.locationIds.compactMap { plan.location(id: $0) }
            if let loc = locations.first {
                if let desc = loc.description, !desc.isEmpty {
                    parts.append("Location: \(desc)")
                }
                if let lighting = loc.lightingNotes, !lighting.isEmpty {
                    parts.append("Lighting: \(lighting)")
                }
            }
        }

        // Authored geometry — the same clause videoPrompt injects, so the panel's
        // composition matches the shot it will anchor.
        if let blocking = shot.blocking, !blocking.isEmpty {
            parts.append("Blocking: \(blocking)")
        }
        if let plan {
            let anchors = shot.locationIds
                .compactMap { plan.location(id: $0)?.spatialAnchors }
                .filter { !$0.isEmpty }
            if let first = anchors.first {
                parts.append("Fixed layout (never rearrange): \(first)")
            }
        }

        if matchPreviousPanel {
            parts.append("Match the lighting, colour, and layout of the previous panel of this location")
        }

        // Short STYLE REMINDER suffix (harness anti-pattern 2): repeating the
        // look at the tail keeps the model from committing to a different
        // rendering style between the opener and the details.
        if let reminder = styleReminder(plan) { parts.append(reminder) }

        return parts.joined(separator: ", ")
    }

    // MARK: - Locked series style (harness rule 11 / anti-pattern 2)

    /// The plan's locked `styleBlock`, trimmed — front-loaded into every
    /// generation prompt so the whole production shares one visual system. Nil
    /// when no style is authored (prompts keep their own phrasing).
    static func stylePrefix(_ plan: ShotPlan?) -> String? {
        guard let s = plan?.styleBlock?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    /// A short "Style reminder: …" tail (capped) for panels, so the look is
    /// restated after the shot details without dominating the prompt.
    static func styleReminder(_ plan: ShotPlan?) -> String? {
        guard let s = stylePrefix(plan) else { return nil }
        let capped = s.count > 140 ? String(s.prefix(140)) + "…" : s
        return "Style reminder: \(capped)"
    }

    /// Audio is ALWAYS generated. Users expect footage to have sound — a muted
    /// generation is unrecoverable (the speech/ambience never existed), while an
    /// unwanted track is one timeline mute away. `nativeAudio` mixes the placed
    /// clip (volume), `audioContent` steers the prompt; neither gates generation.
    static func generateNativeAudio(for shot: Shot) -> Bool {
        true
    }

    /// Rule-33 audio suppression negative for shots that should NOT carry a
    /// music bed or (for ambience-only) speech — baked-in audio can't be mixed
    /// out in post, so it's suppressed at generation. `.full` shots get nil (the
    /// model handles everything). Returned as `negative_prompt` terms; only sent
    /// to models that accept them (`supportsNegativePrompt`).
    static func negativePrompt(for shot: Shot) -> String? {
        let music = "background music, soundtrack, score, musical score, orchestral hits, sound design, audio drops"
        switch shot.audioContent {
        case .full:
            return nil
        case .noMusic, .dialogueOnly:
            return music
        case .ambienceOnly:
            return "speech, dialogue, talking, voices, singing, narration, " + music
        }
    }

    /// The negative for a grouped multi-shot window: emitted when ANY beat
    /// suppresses audio, using the strongest suppression present.
    static func negativePrompt(forWindow window: [Shot]) -> String? {
        if window.contains(where: { $0.audioContent == .ambienceOnly }),
           let ambient = window.first(where: { $0.audioContent == .ambienceOnly }) {
            return negativePrompt(for: ambient)
        }
        if let suppressing = window.first(where: { $0.audioContent != .full }) {
            return negativePrompt(for: suppressing)
        }
        return nil
    }

    /// Placed-clip volume for the shot's mix treatment.
    static func placedClipVolume(for shot: Shot) -> Double {
        switch shot.nativeAudio {
        case .keep: 1.0
        case .duck: 0.3
        case .mute: 0.0
        }
    }
}
