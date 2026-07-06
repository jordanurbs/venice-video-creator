import Foundation

/// Venice video capabilities that its `/models` constraints payload does not
/// expose, so the catalog mapper can't read them directly. Values are ported
/// from the probe-verified production harness registry and matched by family
/// substring so they survive live-catalog id drift; unknown ids fall through to
/// the mapper's conservative defaults (no capability), never enabling something
/// the model can't do.
enum VideoModelCapabilities {
    /// Whether the model accepts an `end_image_url` (last-frame interpolation).
    /// Only meaningful for image-to-video models here — the app routes the end
    /// frame through the same `frames` slot as the first frame, which requires a
    /// first-frame-capable (i2v) model — so the mapper gates this on i2v anyway.
    /// Per the registry: all Kling i2v variants, Wan 2.7 i2v (incl. Spicy), and
    /// PixVerse transition models support it; other families do not.
    static func supportsEndImage(id: String) -> Bool {
        let lower = id.lowercased()
        if lower.contains("kling") { return true }
        if lower.contains("wan-2-7") { return true }
        if lower.contains("pixverse") && lower.contains("transition") { return true }
        return false
    }

    /// Whether the model accepts a single `audio_url` lip-sync/scoring track.
    /// Registry `audioInput: true` families: DaVinci MagiHuman and the Wan 2.5/2.6/2.7
    /// lines — except Wan 2.7 R2V, which takes per-reference `elements[].audio_url`
    /// rather than a top-level `audio_url` and so must stay off this path.
    static func audioInputCapable(id: String) -> Bool {
        let lower = id.lowercased()
        if lower.contains("magihuman") { return true }
        if lower.contains("wan-2-7-reference-to-video") { return false }
        if lower.contains("wan-2-7") { return true }
        if lower.contains("wan-2.6") { return true }
        if lower.contains("wan-2.5-preview") { return true }
        return false
    }

    /// Minimum `audio_url` duration (seconds) a model enforces; nil when it has no
    /// floor. Wan 2.7 and MagiHuman reject audio shorter than 3s (HTTP 400 at queue
    /// time), so shorter clips must be padded with trailing silence first.
    static func minAudioInputSeconds(id: String) -> Double? {
        let lower = id.lowercased()
        if lower.contains("wan-2-7") { return 3 }
        if lower.contains("magihuman") { return 3 }
        return nil
    }
}
