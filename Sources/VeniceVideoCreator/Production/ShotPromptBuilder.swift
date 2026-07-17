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
    static func videoPrompt(for shot: Shot) -> String {
        var parts: [String] = []
        let base = shot.prompt.isEmpty ? shot.summary : shot.prompt
        if !base.isEmpty { parts.append(base) }

        switch shot.motionLevel {
        case .still: parts.append("static camera, minimal motion")
        case .subtle: parts.append("subtle, gentle motion")
        case .moderate: break
        case .dynamic: parts.append("dynamic camera movement, energetic motion")
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

        return parts.joined(separator: ". ")
    }

    /// Whether the video model should generate its own audio for this shot. Native audio is
    /// kept on for ambient/SFX unless the shot explicitly mutes it.
    static func generateNativeAudio(for shot: Shot) -> Bool {
        shot.nativeAudio != .mute
    }
}
