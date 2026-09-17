import Foundation
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

    @Test func minimaxH3MaxR2VAcceptsAudioUrl() {
        // Probe 2026-09-03: same t2v/i2v vs R2V split as base H3. Turbo has no
        // R2V lane at all, so there is nothing to enable for it.
        #expect(VideoModelCapabilities.audioInputCapable(id: "minimax-h3-max-reference-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "minimax-h3-max-text-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "minimax-h3-max-image-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "minimax-h3-max-turbo-image-to-video"))
    }
}

/// MiniMax H3 Max is the only `promptStyle: "simple"` family: it stages its own
/// framing and cutting from a plain statement of intent. Everything else is
/// directorial, and that must stay the default — a wrong "simple" strips the
/// blocking and geography clauses out of a family that needs them.
@Suite("VideoModelCapabilities prompt style")
struct VideoModelPromptStyleTests {

    @Test func h3MaxFamilyWantsSimplePrompts() {
        for id in [
            "minimax-h3-max-text-to-video",
            "minimax-h3-max-image-to-video",
            "minimax-h3-max-reference-to-video",
            "minimax-h3-max-turbo-text-to-video",
            "minimax-h3-max-turbo-image-to-video",
        ] {
            #expect(VideoModelCapabilities.wantsSimplePrompt(id: id), "expected simple-prompt mode for \(id)")
        }
    }

    @Test func everyOtherFamilyStaysDirectorial() {
        for id in [
            // Same name as H3 Max, opposite prompt style — the trap worth pinning.
            "minimax-h3-text-to-video",
            "minimax-h3-reference-to-video",
            "seedance-2-5-reference-to-video",
            "happyhorse-1-1-reference-to-video",
            "wan-3-0-image-to-video",
            "kling-o3-pro-reference-to-video",
            "some-future-model-text-to-video",
        ] {
            #expect(!VideoModelCapabilities.wantsSimplePrompt(id: id), "expected directorial prompts for \(id)")
        }
    }
}

@Suite("VideoModelCapabilities resolution preference order")
struct VideoModelResolutionOrderTests {

    /// Venice reports H3 Max as ["480P", "768P"]. reconcile() takes `.first`
    /// whenever the plan's resolution isn't offered — which for MiniMax tier
    /// labels is always — so live order alone renders every shot at draft tier.
    @Test func h3MaxPrefers768PoverVeniceLiveOrder() {
        for id in [
            "minimax-h3-max-text-to-video",
            "minimax-h3-max-image-to-video",
            "minimax-h3-max-reference-to-video",
            "minimax-h3-max-turbo-text-to-video",
            "minimax-h3-max-turbo-image-to-video",
        ] {
            let ordered = VideoModelCapabilities.preferredResolutionOrder(id: id, live: ["480P", "768P"])
            #expect(ordered?.first == "768P", "expected 768P defaulted for \(id), got \(ordered ?? [])")
            #expect(ordered?.contains("480P") == true, "480P must stay selectable as the draft tier for \(id)")
        }
    }

    /// A resolution the live API offers but the registry hasn't caught up to is
    /// kept, just ranked behind the ones we've made a decision about.
    @Test func unknownLiveResolutionsAreKeptRankedLast() {
        let ordered = VideoModelCapabilities.preferredResolutionOrder(
            id: "minimax-h3-max-image-to-video", live: ["480P", "768P", "1080P"]
        )
        #expect(ordered == ["768P", "480P", "1080P"])
    }

    /// Base MiniMax H3 is the inverse case, and the pair has to not cross:
    /// Venice now offers it 768P as well, but the harness pins every H3 render to
    /// 2K, so the app defaults there too rather than quietly disagreeing.
    @Test func baseH3Prefers2KAndDoesNotInheritTheMaxCap() {
        let ordered = VideoModelCapabilities.preferredResolutionOrder(
            id: "minimax-h3-image-to-video", live: ["768P", "2K"]
        )
        #expect(ordered == ["2K", "768P"])
    }

    /// No manifest entry, no opinion — live order passes through untouched.
    @Test func unknownModelsKeepLiveOrder() {
        let ordered = VideoModelCapabilities.preferredResolutionOrder(
            id: "some-future-model-text-to-video", live: ["540p", "1080p"]
        )
        #expect(ordered == ["540p", "1080p"])
        #expect(VideoModelCapabilities.preferredResolutionOrder(id: "anything", live: nil) == nil)
        #expect(VideoModelCapabilities.preferredResolutionOrder(id: "anything", live: []) == [])
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
            "minimax-h3-max-reference-to-video",
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

    @Test func seedance25R2VCarriesTheFullReferenceFirstCapabilitySet() {
        // Phase 0.3: mirror the harness coverage test — Seedance 2.5 R2V (the
        // default video family) must resolve as a 30-ref, image-tag,
        // audio-input, reference-audio pure-reference lane whether or not the
        // manifest is loaded (these hold via the hardcode + family fallbacks).
        let id = "seedance-2-5-reference-to-video"
        #expect(VideoModelCapabilities.maxReferenceImages(id: id) == 30, "2.5 R2V must keep the 30-ref budget")
        #expect(VideoModelCapabilities.usesImageTags(id: id), "2.5 R2V must honor @ImageN tags")
        #expect(VideoModelCapabilities.audioInputCapable(id: id), "2.5 R2V must accept audio_url")
        #expect(VideoModelCapabilities.supportsReferenceAudio(id: id), "2.5 R2V must accept reference_audio_urls")
        // t2v/i2v lanes are NOT reference lanes.
        #expect(!VideoModelCapabilities.audioInputCapable(id: "seedance-2-5-text-to-video"))
        #expect(!VideoModelCapabilities.audioInputCapable(id: "seedance-2-5-image-to-video"))
    }

    @Test func pureReferenceModelsUseImageTags() {
        // These reject image_url alongside reference media (hard 400) and honor
        // @ImageN prompt tags; probe dates in the harness registry.
        for id in [
            "seedance-2-0-reference-to-video",
            "seedance-2-0-enhanced-reference-to-video",
            "minimax-h3-reference-to-video",
            "minimax-h3-max-reference-to-video",
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

    @Test func negativePromptFamilies() {
        for id in ["seedance-2-0-reference-to-video", "wan-2-7-image-to-video",
                   "kling-2.6-pro-image-to-video", "pixverse-v5.6-transition", "ltx-video", "ovi-1-0"] {
            #expect(VideoModelCapabilities.supportsNegativePrompt(id: id), "expected negative for \(id)")
        }
        #expect(!VideoModelCapabilities.supportsNegativePrompt(id: "some-unknown-family-v1"))
    }

    @Test func seedStaysOffUntilProbed() {
        // Non-regression: no family is seed-verified yet, so no seed reaches a paid
        // request. Flipping any of these on requires a live /video/quote probe.
        for id in ["seedance-2-0-reference-to-video", "wan-2-7-image-to-video", "kling-o3-pro-image-to-video"] {
            #expect(!VideoModelCapabilities.supportsSeed(id: id))
        }
    }

    @Test func takeRecipeAndSeedRoundTripThroughCodable() throws {
        var recipe = GenerationInput(prompt: "a wave", model: "seedance-2-0-reference-to-video",
                                     duration: 5, aspectRatio: "16:9", resolution: "1080p")
        recipe.negativePrompt = "background music"
        recipe.seed = 4242
        recipe.referenceImageAssetIds = ["ref-a", "ref-b"]
        let take = ShotTake(videoAssetId: "vid1", model: recipe.model, recipe: recipe, seed: recipe.seed)
        let data = try JSONEncoder().encode(take)
        let decoded = try JSONDecoder().decode(ShotTake.self, from: data)
        #expect(decoded.seed == 4242)
        #expect(decoded.recipe?.prompt == "a wave")
        #expect(decoded.recipe?.seed == 4242)
        #expect(decoded.recipe?.referenceImageAssetIds == ["ref-a", "ref-b"])
    }

    @Test func planSeedRoundTripsThroughCodable() throws {
        var plan = ShotPlan(title: "Test")
        plan.seed = 99
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: data)
        #expect(decoded.seed == 99)
    }
}
