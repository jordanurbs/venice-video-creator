import Testing
@testable import VeniceVideoCreator

@Suite("VideoModelCapabilities.supportsEndImage")
struct VideoModelCapabilitiesTests {

    @Test func klingVariantsSupportEndImage() {
        for id in [
            "kling-2.6-pro-image-to-video",
            "kling-2.5-turbo-pro-image-to-video",
            "kling-o3-pro-image-to-video",
            "kling-o3-standard-image-to-video",
            "kling-o3-4k-image-to-video",
            "kling-v3-pro-image-to-video",
            "kling-v3-standard-image-to-video",
        ] {
            #expect(VideoModelCapabilities.supportsEndImage(id: id), "expected end-image for \(id)")
        }
    }

    @Test func wan27DoesNotSupportEndImage() {
        // Live 2026-07-06: Wan 2.7 i2v (Uncensored/Spicy) rejects end_image_url
        // despite the harness marking the family capable. Whole family stays off.
        #expect(!VideoModelCapabilities.supportsEndImage(id: "wan-2-7-image-to-video"))
        #expect(!VideoModelCapabilities.supportsEndImage(id: "wan-2-7-spicy-image-to-video"))
    }

    @Test func pixverseTransitionSupportsEndImage() {
        #expect(VideoModelCapabilities.supportsEndImage(id: "pixverse-v5.6-transition"))
        #expect(VideoModelCapabilities.supportsEndImage(id: "pixverse-c1-transition"))
    }

    @Test func familiesWithoutEndImageAreOff() {
        // Registry marks these end-image=false; the mapper's isImageToVideo gate
        // also stops t2v/r2v, but the allowlist itself must not over-match.
        for id in [
            "veo3.1-fast-image-to-video",
            "seedance-2-0-image-to-video",
            "grok-imagine-image-to-video",
            "sora-2-image-to-video",
            "runway-gen4-5",
            "ltx-2-fast-image-to-video",
            "longcat-image-to-video",
            "vidu-q3-image-to-video",
            "wan-2.6-image-to-video",
            "pixverse-v5.6-image-to-video",
        ] {
            #expect(!VideoModelCapabilities.supportsEndImage(id: id), "did not expect end-image for \(id)")
        }
    }
}

@Suite("VideoModelCapabilities.audioInput")
struct VideoModelAudioCapabilityTests {

    @Test func wanAndMagihumanAcceptAudioUrl() {
        for id in [
            "wan-2-7-image-to-video", "wan-2-7-text-to-video", "wan-2-7-video-to-video",
            "wan-2-7-spicy-image-to-video",
            "wan-2.6-image-to-video", "wan-2.6-flash-image-to-video", "wan-2.6-reference-to-video",
            "wan-2.5-preview-image-to-video",
            "davinci-magihuman-image-to-video",
        ] {
            #expect(VideoModelCapabilities.audioInputCapable(id: id), "expected audio_url for \(id)")
        }
    }

    @Test func wan27R2VUsesPerReferenceAudioNotAudioUrl() {
        // R2V drives audio via elements[].audio_url, not a top-level audio_url.
        #expect(!VideoModelCapabilities.audioInputCapable(id: "wan-2-7-reference-to-video"))
    }

    @Test func nonAudioFamiliesAreOff() {
        for id in ["veo3.1-fast-image-to-video", "seedance-2-0-image-to-video", "kling-o3-pro-image-to-video", "sora-2-image-to-video"] {
            #expect(!VideoModelCapabilities.audioInputCapable(id: id), "did not expect audio_url for \(id)")
        }
    }

    @Test func wan27AndMagihumanEnforceThreeSecondFloor() {
        #expect(VideoModelCapabilities.minAudioInputSeconds(id: "wan-2-7-image-to-video") == 3)
        #expect(VideoModelCapabilities.minAudioInputSeconds(id: "davinci-magihuman-image-to-video") == 3)
        // Wan 2.6 / 2.5 accept audio but declare no minimum.
        #expect(VideoModelCapabilities.minAudioInputSeconds(id: "wan-2.6-image-to-video") == nil)
    }
}
