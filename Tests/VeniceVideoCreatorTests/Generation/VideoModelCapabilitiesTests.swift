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

    @Test func wanAcceptsAudioUrl() {
        for id in [
            "wan-2-7-image-to-video", "wan-2-7-text-to-video", "wan-2-7-video-to-video",
            "wan-2-7-spicy-image-to-video",
            "wan-2.6-image-to-video", "wan-2.6-flash-image-to-video", "wan-2.6-reference-to-video",
            "wan-2.5-preview-image-to-video",
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

    @Test func seedanceR2VAcceptsAudioUrl() {
        // Live probe 2026-07-23: R2V variants accept audio_url; i2v/t2v reject it.
        for id in [
            "seedance-2-0-reference-to-video", "seedance-2-0-fast-reference-to-video",
            "seedance-2-0-enhanced-reference-to-video", "seedance-2-0-mini-reference-to-video",
        ] {
            #expect(VideoModelCapabilities.audioInputCapable(id: id), "expected audio_url for \(id)")
        }
        for id in ["seedance-2-0-text-to-video", "seedance-2-0-fast-image-to-video", "happyhorse-1-1-reference-to-video"] {
            #expect(!VideoModelCapabilities.audioInputCapable(id: id), "did not expect audio_url for \(id)")
        }
    }

    @Test func wan27EnforcesThreeSecondFloor() {
        #expect(VideoModelCapabilities.minAudioInputSeconds(id: "wan-2-7-image-to-video") == 3)
        // Wan 2.6 / 2.5 accept audio but declare no minimum.
        #expect(VideoModelCapabilities.minAudioInputSeconds(id: "wan-2.6-image-to-video") == nil)
    }

    @Test func minimaxH3R2VAcceptsAudioUrl() {
        // Registry sync 2026-07-31: audio_input true on the R2V lane only.
        #expect(VideoModelCapabilities.audioInputCapable(id: "minimax-h3-reference-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "minimax-h3-text-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "minimax-h3-image-to-video"))
    }
}

@Suite("VideoModelCapabilities reference budgets and tags")
struct VideoModelReferenceCapabilityTests {

    @Test func nineImageBudgetFamilies() {
        for id in [
            "seedance-2-0-reference-to-video",
            "seedance-2-0-enhanced-reference-to-video",
            "seedance-2-0-fast-reference-to-video",
            "happyhorse-1-1-reference-to-video",
            "minimax-h3-reference-to-video",
            "wan-3-0-reference-to-video",
            "wan-3-0-enhanced-reference-to-video",
        ] {
            #expect(VideoModelCapabilities.maxReferenceImages(id: id) == 9, "expected 9-ref budget for \(id)")
        }
    }

    @Test func unknownModelsKeepConservativeFourRefBudget() {
        #expect(VideoModelCapabilities.maxReferenceImages(id: "some-future-model-reference-to-video") == 4)
        #expect(VideoModelCapabilities.maxReferenceImages(id: "kling-o3-pro-reference-to-video") == 4)
    }

    @Test func pureReferenceModelsUseImageTags() {
        // These reject image_url alongside reference media (hard 400) and honor
        // @ImageN prompt tags; probe dates in the harness registry.
        for id in [
            "seedance-2-0-reference-to-video",
            "seedance-2-0-enhanced-reference-to-video",
            "minimax-h3-reference-to-video",
            "happyhorse-1-1-reference-to-video",
            "grok-imagine-reference-to-video",
        ] {
            #expect(VideoModelCapabilities.usesImageTags(id: id), "expected image-tag mode for \(id)")
        }
        #expect(!VideoModelCapabilities.usesImageTags(id: "kling-o3-pro-reference-to-video"))
        #expect(!VideoModelCapabilities.usesImageTags(id: "wan-2-7-reference-to-video"))
    }

    @Test func referenceAudioFamilies() {
        // /video/quote probe 2026-07-23: Seedance R2V ×3 + HappyHorse 1.1 R2V.
        for id in [
            "seedance-2-0-reference-to-video",
            "seedance-2-0-enhanced-reference-to-video",
            "seedance-2-0-fast-reference-to-video",
            "happyhorse-1-1-reference-to-video",
        ] {
            #expect(VideoModelCapabilities.supportsReferenceAudio(id: id), "expected reference_audio_urls for \(id)")
        }
        #expect(!VideoModelCapabilities.supportsReferenceAudio(id: "seedance-2-0-image-to-video"))
        #expect(!VideoModelCapabilities.supportsReferenceAudio(id: "wan-2-7-image-to-video"))
    }
}
