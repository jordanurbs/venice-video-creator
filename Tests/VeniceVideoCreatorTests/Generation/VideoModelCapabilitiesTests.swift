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

    @Test func wan27SupportsEndImage() {
        #expect(VideoModelCapabilities.supportsEndImage(id: "wan-2-7-image-to-video"))
        #expect(VideoModelCapabilities.supportsEndImage(id: "wan-2-7-spicy-image-to-video"))
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
