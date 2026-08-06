import Foundation

/// Venice video capabilities that its `/models` constraints payload does not
/// expose, so the catalog mapper can't read them directly.
///
/// Resolution order (2026-08-06):
/// 1. The harness capability manifest (`CapabilityManifestSnapshot`) — exact-id
///    sets exported by the probe-verified `venice-video-harness` registry
///    (`venice-video capabilities`, harness ≥2.15.0). Bundled snapshot by
///    default; refreshed from the harness repo when the user enables
///    "Update model capabilities automatically" (Settings → Models). An id the
///    manifest KNOWS resolves exactly; ids it doesn't know fall through.
/// 2. Family-substring fallbacks, for ids the manifest doesn't carry (or when
///    no manifest loaded). Synced to harness registry 2.15.0 (2026-08-06).
/// 3. Conservative default: capability off. Never enable something a model
///    might not have — a wrong "on" wastes a paid generation.
///
/// Live API truth beats both layers: when a real Venice response contradicts
/// them (e.g. a queue 400), fix the harness registry AND these fallbacks, and
/// record the probe date + exact error (see
/// `.cursor/rules/harness-app-capability-sync.mdc`).
enum VideoModelCapabilities {
    private static var manifest: CapabilityManifest? { CapabilityManifestSnapshot.current }

    /// Whether the model accepts an `end_image_url` (last-frame interpolation).
    /// Only meaningful for image-to-video models here — the app routes the end
    /// frame through the same `frames` slot as the first frame, which requires a
    /// first-frame-capable (i2v) model — so the mapper gates this on i2v anyway.
    /// Fallback families: Kling i2v variants (live-confirmed on Kling O3 Pro) and
    /// PixVerse transition models. Wan 2.7 is excluded despite the harness
    /// historically marking the family end-image-capable: live 2026-07-06 the
    /// Wan 2.7 i2v (Uncensored/Spicy) queue rejected `end_image_url` ("This model
    /// does not support end_image_url"), so the whole family falls through to false.
    static func supportsEndImage(id: String) -> Bool {
        if let m = manifest, m.knownIds.contains(id) {
            return m.capabilitySets.endImage.contains(id)
        }
        let lower = id.lowercased()
        if lower.contains("kling") { return true }
        if lower.contains("pixverse") && lower.contains("transition") { return true }
        return false
    }

    /// Whether the model accepts a single `audio_url` lip-sync/scoring track.
    /// Fallback families with `audioInput: true`: the Wan 2.5/2.6/2.7 lines —
    /// except Wan 2.7 R2V, which takes per-reference `elements[].audio_url`
    /// rather than a top-level `audio_url` and so must stay off this path.
    /// Seedance 2.0 R2V variants accept `audio_url` despite the live catalog
    /// reporting `audio_input: false` — probe 2026-07-23: queue accepted
    /// audio_url on all four R2V variants (real job completed on Fast R2V);
    /// i2v/t2v returned "This model does not support audio input".
    /// MiniMax H3 R2V reports `audio_input: true` in /models (registry sync
    /// 2026-07-31); its t2v/i2v lanes report false and stay off.
    static func audioInputCapable(id: String) -> Bool {
        if let m = manifest, m.knownIds.contains(id) {
            return m.capabilitySets.audioInput.contains(id)
        }
        let lower = id.lowercased()
        if lower.contains("wan-2-7-reference-to-video") { return false }
        if lower.contains("wan-2-7") { return true }
        if lower.contains("wan-2.6") { return true }
        if lower.contains("wan-2.5-preview") { return true }
        if lower.contains("seedance") && lower.contains("reference-to-video") { return true }
        if lower.contains("minimax-h3-reference-to-video") { return true }
        return false
    }

    /// Minimum `audio_url` duration (seconds) a model enforces; nil when it has no
    /// floor. Wan 2.7 rejects audio shorter than 3s (HTTP 400 at queue time), so
    /// shorter clips must be padded with trailing silence first.
    static func minAudioInputSeconds(id: String) -> Double? {
        if let m = manifest, m.knownIds.contains(id) {
            return m.minAudioInputSeconds(id: id)
        }
        let lower = id.lowercased()
        if lower.contains("wan-2-7") { return 3 }
        return nil
    }

    /// Whether the model accepts an `elements[]` array (per-element reference + optional
    /// per-element `audio_url`), as used by Kling O3 R2V and Wan 2.7 R2V. The app's
    /// request builder for `elements[]` is deliberately deferred (see plan), so this
    /// stays OFF regardless of the manifest — flipping it on must accompany the
    /// builder + a live probe. The manifest set is still exposed for future use.
    static func supportsElements(id: String) -> Bool {
        false
    }

    /// Whether the model accepts `scene_images` (multiple scene/setting reference images
    /// distinct from character references). Request builder deferred; stays OFF
    /// regardless of the manifest, same rationale as `supportsElements`.
    static func supportsSceneImages(id: String) -> Bool {
        false
    }

    /// Whether the model supports per-reference audio (each reference image/element
    /// carrying its own `audio_url`), e.g. Wan 2.7 R2V's `elements[].audio_url` and
    /// HappyHorse 1.1 R2V's `image_references[{image_url, audio_url}]` (probe
    /// 2026-07-23: queue accepted a paid job). Both object builders are deferred,
    /// so this stays OFF regardless of the manifest.
    static func perReferenceAudio(id: String) -> Bool {
        false
    }

    /// Whether the model accepts `reference_audio_urls` — voice-donor clips (≤3,
    /// 2-15s each, ≤15s aggregate) bound in-prompt as @Audio1… so a character's
    /// voice stays consistent across shots. Distinct from `audioInputCapable`
    /// (the lip-sync `audio_url` lane). Harness probe 2026-07-23 via /video/quote:
    /// the three Seedance 2.0 R2V lanes + HappyHorse 1.1 R2V validate; Venice
    /// requires ≥1 reference image alongside (audio-only rejects at validation).
    static func supportsReferenceAudio(id: String) -> Bool {
        if let m = manifest, m.knownIds.contains(id) {
            return m.capabilitySets.referenceAudio.contains(id)
        }
        let lower = id.lowercased()
        if lower.contains("seedance") && lower.contains("reference-to-video") { return true }
        if lower.contains("happyhorse-1-1-reference-to-video") { return true }
        return false
    }

    /// Whether the model is a pure-reference lane: it honors @ImageN prompt tags
    /// and REJECTS `image_url`/`end_image_url` alongside reference media (hard 400).
    /// MiniMax H3 R2V probe 2026-07-31: "image_url and end_image_url cannot be
    /// combined with reference media for this model".
    static func usesImageTags(id: String) -> Bool {
        if let m = manifest, m.knownIds.contains(id) {
            return m.capabilitySets.imageTags.contains(id)
        }
        let lower = id.lowercased()
        if lower.contains("seedance") && lower.contains("reference-to-video") { return true }
        if lower.contains("grok-imagine-reference-to-video") { return true }
        if lower.contains("minimax-h3-reference-to-video") { return true }
        if lower.contains("happyhorse-1-1-reference-to-video") { return true }
        return false
    }

    /// Per-model `reference_image_urls` budget. The Venice API cap is 9; models the
    /// manifest doesn't list fall back to the legacy conservative cap of 4. Harness
    /// registry: Seedance 2.0 R2V ×3, HappyHorse 1.1 R2V, MiniMax H3 R2V, and
    /// Wan 3.0 R2V (standard + enhanced) all take 9.
    static func maxReferenceImages(id: String) -> Int {
        if let m = manifest {
            if let exact = m.budgets.maxReferenceImagesByModel[id] { return exact }
            if m.knownIds.contains(id) { return m.budgets.defaultMaxReferenceImages }
        }
        let lower = id.lowercased()
        if lower.contains("seedance") && lower.contains("reference-to-video") { return 9 }
        if lower.contains("happyhorse-1-1-reference-to-video") { return 9 }
        if lower.contains("minimax-h3-reference-to-video") { return 9 }
        if lower.contains("wan-3-0") && lower.contains("reference-to-video") { return 9 }
        return 4
    }

    /// Venice's video prompt cap (2500 chars on the Seedance family and MiniMax H3).
    static var videoPromptCharLimit: Int {
        manifest?.budgets.videoPromptCharLimit ?? 2500
    }
}
