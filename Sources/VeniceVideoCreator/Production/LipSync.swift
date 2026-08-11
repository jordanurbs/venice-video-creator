import Foundation

/// Router decision hook for the (still-deferred) lip-sync strategy — harness
/// rule 32 / port plan `keyframe-pipeline`.
///
/// The voice-reference attachment (rule 40) already covers a character's TIMBRE
/// by pushing its locked voice sample as `reference_audio_urls`, but that does
/// not drive exact lip movement. True lip-sync instead TTS-es the shot's spoken
/// line and hands it to the model as a top-level `audio_url` track. That
/// generation path (synthesising the line in the router, the `audio_url` request
/// field) is wired incrementally behind `ModelPreferences.lipSyncEnabled`
/// (default OFF, non-regression). This type is the cheap, pure decision point:
/// "is this shot a lip-sync candidate?" — kept free of model/account state so
/// the rule is unit-tested directly.
enum LipSync {
    /// A shot is a lip-sync candidate when all three hold:
    /// - it has an on-screen (non voice-over) spoken line,
    /// - the speaking character has a locked voice (so the line can be TTS-ed in
    ///   a consistent voice), and
    /// - the routed model accepts a top-level `audio_url` lip-sync track.
    static func eligible(
        hasOnScreenLine: Bool,
        speakerHasLockedVoice: Bool,
        modelAcceptsAudioURL: Bool
    ) -> Bool {
        hasOnScreenLine && speakerHasLockedVoice && modelAcceptsAudioURL
    }
}
