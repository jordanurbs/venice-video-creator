import Foundation
import Testing
@testable import VeniceVideoCreator

/// Lip-sync router hook eligibility (harness rule 32). The predicate is the cheap
/// decision point; the generation path stays behind the default-off
/// `lipSyncEnabled` flag.
@Suite("LipSync eligibility")
struct LipSyncTests {

    @Test func allThreeConditionsRequired() {
        #expect(LipSync.eligible(hasOnScreenLine: true, speakerHasLockedVoice: true, modelAcceptsAudioURL: true))
        #expect(!LipSync.eligible(hasOnScreenLine: false, speakerHasLockedVoice: true, modelAcceptsAudioURL: true))
        #expect(!LipSync.eligible(hasOnScreenLine: true, speakerHasLockedVoice: false, modelAcceptsAudioURL: true))
        #expect(!LipSync.eligible(hasOnScreenLine: true, speakerHasLockedVoice: true, modelAcceptsAudioURL: false))
    }

    @Test func audioUrlCapabilityMatchesTheModelsThatAcceptIt() {
        // The lip-sync track rides the same audio_url lane as scoring input.
        #expect(VideoModelCapabilities.audioInputCapable(id: "seedance-2-0-fast-reference-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "seedance-2-0-image-to-video"))
    }

    @Test func defaultFlagIsOff() {
        // Non-regression: the paid audio_url path is opt-in.
        // (Read the persisted value without mutating user state.)
        let key = "lipSyncEnabled"
        let stored = UserDefaults.standard.object(forKey: key) as? Bool
        #expect(stored == nil || stored == false)
    }
}
