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
    static let multiAngleID = "minimax-h3-max-multi-angle"

    static func supportsCameraTrajectory(id: String) -> Bool {
        guard id == multiAngleID else { return false }
        if let spec = manifest?.videoModels.first(where: { $0.id == id }) {
            return spec.supportsCameraTrajectory
        }
        return true
    }

    static func automaticResolution(id: String, allowed: [String]?) -> String? {
        if id == multiAngleID { return ["768P", "480P"].first { allowed?.contains($0) == true } }
        return allowed?.first
    }

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
        if lower.contains("minimax-h3-max-reference-to-video") { return true }
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
        if lower.contains("minimax-h3-max-reference-to-video") { return true }
        if lower.contains("happyhorse-1-1-reference-to-video") { return true }
        return false
    }

    /// Per-model `reference_image_urls` budget. The Venice API cap is 9; models the
    /// manifest doesn't list fall back to the legacy conservative cap of 4. Harness
    /// registry: Seedance 2.0 R2V ×3, HappyHorse 1.1 R2V, MiniMax H3 R2V, and
    /// Wan 3.0 R2V (standard + enhanced) all take 9.
    static func maxReferenceImages(id: String) -> Int {
        let lowerId = id.lowercased()
        // Seedance 2.5 R2V: 30-image reference budget (harness probe 2026-08-07,
        // venice-video-harness seedance-2-5 registry). Checked before the
        // manifest so a stale manifest can't clamp it back to 9.
        if lowerId.contains("seedance-2-5") && lowerId.contains("reference-to-video") { return 30 }
        if let m = manifest {
            if let exact = m.budgets.maxReferenceImagesByModel[id] { return exact }
            if m.knownIds.contains(id) { return m.budgets.defaultMaxReferenceImages }
        }
        let lower = id.lowercased()
        if lower.contains("seedance") && lower.contains("reference-to-video") { return 9 }
        if lower.contains("happyhorse-1-1-reference-to-video") { return 9 }
        if lower.contains("minimax-h3-reference-to-video") { return 9 }
        if lower.contains("minimax-h3-max-reference-to-video") { return 9 }
        if lower.contains("wan-3-0") && lower.contains("reference-to-video") { return 9 }
        return 4
    }

    /// Venice's video prompt cap (2500 chars on the Seedance family and MiniMax H3).
    static var videoPromptCharLimit: Int {
        manifest?.budgets.videoPromptCharLimit ?? 2500
    }

    /// Whether the model wants a short, plain prompt rather than a fully
    /// directed one. The MiniMax H3 Max family stages its own coverage and
    /// cutting from a stated intent (harness registry `promptStyle: "simple"`,
    /// probe 2026-09-03), so the directorial stack — and the production
    /// pre-flight that insists on it — works against these models rather than
    /// for them. Everything else is directorial; that stays the default for
    /// ids neither layer knows.
    static func wantsSimplePrompt(id: String) -> Bool {
        if let m = manifest, m.knownIds.contains(id) {
            return m.promptStyle(id: id) == "simple"
        }
        return id.lowercased().contains("minimax-h3-max")
    }

    /// Live `/models` resolutions reordered to follow the harness registry's
    /// preference order, which is deliberate where the live order is incidental.
    ///
    /// This matters because `ProductionOrchestrator.reconcile` falls back to the
    /// FIRST allowed resolution whenever the plan's own value isn't offered — and
    /// for the whole MiniMax family that fallback is the effective default, since
    /// their tier labels (`768P`, `2K`) never match a plan's `1080p`-style value.
    /// Venice lists MiniMax H3 Max as `["480P", "768P"]`, so taking the live order
    /// at face value silently renders every H3 Max shot at its draft tier.
    ///
    /// The live list still decides what is *allowed* — it's the fresher source, and
    /// anything it offers that the registry hasn't caught up to is kept, ranked
    /// last rather than dropped.
    static func preferredResolutionOrder(id: String, live: [String]?) -> [String]? {
        guard let live, !live.isEmpty else { return live }
        if id == multiAngleID {
            let preferred = ["768P", "480P", "1080P"]
            return preferred.filter(live.contains) + live.filter { !preferred.contains($0) }
        }
        guard let preferred = manifest?.resolutions(id: id) ?? resolutionFallback(id: id),
              !preferred.isEmpty
        else { return live }
        let ranked = preferred.filter(live.contains)
        guard !ranked.isEmpty else { return live }
        return ranked + live.filter { !ranked.contains($0) }
    }

    /// Family fallback for `preferredResolutionOrder`, for ids the manifest
    /// doesn't carry and for the window before the manifest store has loaded —
    /// the catalog can map models in that window, and a resolution defaulted
    /// there sticks for the session. Only families whose live order we know to
    /// be wrong appear here; everything else keeps live order untouched.
    private static func resolutionFallback(id: String) -> [String]? {
        let lower = id.lowercased()
        // Must precede the `minimax-h3` check: H3 Max is 768P-capped and rejects
        // 2K, the exact inverse of base H3.
        if lower.contains("minimax-h3-max") { return ["768P", "480P"] }
        if lower.contains("minimax-h3") { return ["2K"] }
        return nil
    }

    /// Whether the model accepts a top-level `negative_prompt`. Venice's
    /// `/video/queue` schema declares it as a general string field with a
    /// per-model default (clones/outerface
    /// `api/v1/video/queue/api-video-queue-schema.ts`), and the fal-hosted
    /// families below ship a `negative_prompt` default in the model registry
    /// (wan / kling / pixverse / ltx / longcat / ovi). Seedance is the
    /// production path the harness relies on for rule-33 audio suppression.
    /// Conservative default OFF for ids we can't place — a wrong "on" wastes a
    /// paid generation; enable a new family only after a live probe.
    static func supportsNegativePrompt(id: String) -> Bool {
        let lower = id.lowercased()
        let families = ["seedance", "wan-", "wan2", "wan-2", "kling", "pixverse", "ltx", "longcat", "ovi"]
        return families.contains { lower.contains($0) }
    }

    /// Whether the model's queue accepts a top-level `seed` for reproducible
    /// generation (harness seed-locking / recipe replay). No family has been
    /// live-probed for seed acceptance yet, so this returns FALSE for everything:
    /// the plumbing (GenerationInput.seed, ShotTake recipe, request-body emit) is
    /// in place, but no seed reaches a paid request until a family is probe-verified
    /// and added here — per the non-regression rule (a rejected seed field can hard
    /// 400 the whole job). Fill the allowlist below after probing via /video/quote.
    static func supportsSeed(id: String) -> Bool {
        let probeVerifiedSeedFamilies: [String] = []   // e.g. "seedance" once probed
        let lower = id.lowercased()
        return probeVerifiedSeedFamilies.contains { lower.contains($0) }
    }
}
