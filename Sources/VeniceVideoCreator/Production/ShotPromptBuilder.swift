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
    static func videoPrompt(for shot: Shot, plan: ShotPlan? = nil) -> String {
        var parts: [String] = []
        let base = shot.prompt.isEmpty ? shot.summary : shot.prompt
        if !base.isEmpty { parts.append(base) }

        switch shot.motionLevel {
        case .still: parts.append("static camera, minimal motion")
        case .subtle: parts.append("subtle, gentle motion")
        case .moderate: break
        case .dynamic: parts.append("dynamic camera movement, energetic motion")
        }

        // Authored shot geometry: who stands where, relative to the location's
        // named anchors, the frame, and each other — restated verbatim per take.
        if let blocking = shot.blocking, !blocking.isEmpty {
            parts.append("Blocking: \(blocking)")
        }

        // Locked location geography: named landmarks and their fixed relative
        // positions, plus an explicit no-mirroring clause when the shot also
        // places characters (mirrored/reshuffled geography is the failure mode).
        if let plan {
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

        // On-screen spoken lines can be described; voice-over lines must not reach the prompt.
        let onScreen = shot.onScreenDialogue.map(\.text).filter { !$0.isEmpty }
        if !onScreen.isEmpty {
            parts.append("Characters speak on screen: \(onScreen.joined(separator: " "))")
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

    /// Audio is ALWAYS generated. Users expect footage to have sound — a muted
    /// generation is unrecoverable (the speech/ambience never existed), while an
    /// unwanted track is one timeline mute away. `nativeAudio` mixes the placed
    /// clip (volume), `audioContent` steers the prompt; neither gates generation.
    static func generateNativeAudio(for shot: Shot) -> Bool {
        true
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
