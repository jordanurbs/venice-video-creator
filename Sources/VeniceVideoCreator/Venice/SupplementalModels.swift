import Foundation

/// Models whose generation endpoints Venice still accepts, but which its
/// `/models` catalog does not return for every key. The app's catalog is
/// otherwise a verbatim mirror of `/models`, so without this these models can't
/// be selected at all.
///
/// Entries are shaped exactly like raw `/models` objects and flow through the
/// normal `VeniceModelMapper`, so they inherit correct variant labels, input
/// slots, and capability gating. They are merged in only when the live response
/// omits them (de-duplicated by id), so this self-heals the moment Venice starts
/// returning them again.
///
/// The Seedance 2.0 family — regular + Fast (each t2v/i2v/r2v), Mini (t2v/i2v/r2v),
/// Enhanced and Mini Enhanced (t2v/r2v only; neither has an image-to-video variant)
/// — is absent from this key's `/models` response yet accepted by the generation
/// API. Every slug below was verified via `/video/quote` (free, no generation) on
/// 2026-07-13 & 2026-07-17: regular & Enhanced $0.95, Fast $0.76,
/// Mini/Mini Enhanced $0.47 per 5s @ 720p. Regular 2.0 and Enhanced also reach
/// 1080p ($2.34) and 4k ($4.86); Fast/Mini/Mini Enhanced cap at 720p. The
/// `*-enhanced-image-to-video` and `*-mini-enhanced-image-to-video` slugs 404, so
/// they are omitted. Keep in sync with the harness per
/// `.cursor/rules/harness-app-capability-sync.mdc`.
enum SupplementalModels {
    /// Prepends any supplemental entry whose id is not already present in the live
    /// `/models` payload, so the Seedance family sits at the top of the picker and
    /// its first entry (Mini Enhanced Text→Video) is the default selection. Live
    /// truth still wins on conflicts (dropped from additions when already present).
    static func merged(into live: [[String: Any]]) -> [[String: Any]] {
        let liveIds = Set(live.compactMap { $0["id"] as? String })
        let additions = (videoEntries + audioEntries).filter { entry in
            guard let id = entry["id"] as? String else { return false }
            return !liveIds.contains(id)
        }
        return additions + live
    }

    // Seedance 2.0 constraints (harness registry). Fast uses a denser duration ladder.
    private static let seedanceDurations = ["4s", "5s", "8s", "10s", "12s", "15s"]
    private static let seedanceFastDurations =
        ["4s", "5s", "6s", "7s", "8s", "9s", "10s", "11s", "12s", "13s", "14s", "15s"]
    // Only the regular Seedance 2.0 line supports 1080p + 4k ($2.34 / $4.86 per 5s);
    // Fast/Mini/Mini Enhanced 400 on both, capping at 720p (verified via
    // /video/quote 2026-07-13 & 2026-07-17). Venice's 4k resolution string is "4k".
    private static let seedanceResolutions = ["480p", "720p"]
    private static let seedanceResolutionsHD = ["480p", "720p", "1080p", "4k"]
    private static let seedanceAspectRatios = ["16:9", "9:16", "4:3", "3:4", "1:1"]

    private static var videoEntries: [[String: Any]] {
        [
            // Enhanced Text→Video is listed first so it becomes the default
            // selection (the picker defaults to the first enabled model).
            // Enhanced (non-Mini): full 1080p+4k ladder, t2v + r2v only (i2v 404s). Prices match regular 2.0.
            videoEntry(id: "seedance-2-0-enhanced-text-to-video", name: "Seedance 2.0 Enhanced", modelType: "text-to-video", durations: seedanceDurations, resolutions: seedanceResolutionsHD),
            videoEntry(id: "seedance-2-0-enhanced-reference-to-video", name: "Seedance 2.0 Enhanced R2V", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutionsHD),
            // Mini Enhanced has no image-to-video variant (live /video/quote 404), only t2v + r2v.
            videoEntry(id: "seedance-2-0-mini-enhanced-text-to-video", name: "Seedance 2.0 Mini Enhanced", modelType: "text-to-video", durations: seedanceDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-mini-enhanced-reference-to-video", name: "Seedance 2.0 Mini Enhanced R2V", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-mini-text-to-video", name: "Seedance 2.0 Mini", modelType: "text-to-video", durations: seedanceDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-mini-image-to-video", name: "Seedance 2.0 Mini", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-mini-reference-to-video", name: "Seedance 2.0 Mini R2V", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-text-to-video", name: "Seedance 2.0", modelType: "text-to-video", durations: seedanceDurations, resolutions: seedanceResolutionsHD),
            videoEntry(id: "seedance-2-0-image-to-video", name: "Seedance 2.0", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutionsHD),
            // R2V shares Venice's "image-to-video" model_type; the slug's
            // "reference-to-video" is what routes it to the reference-image slot.
            videoEntry(id: "seedance-2-0-reference-to-video", name: "Seedance 2.0 R2V", modelType: "image-to-video", durations: seedanceDurations, resolutions: seedanceResolutionsHD),
            videoEntry(id: "seedance-2-0-fast-text-to-video", name: "Seedance 2.0 Fast", modelType: "text-to-video", durations: seedanceFastDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-fast-image-to-video", name: "Seedance 2.0 Fast", modelType: "image-to-video", durations: seedanceFastDurations, resolutions: seedanceResolutions),
            videoEntry(id: "seedance-2-0-fast-reference-to-video", name: "Seedance 2.0 Fast R2V", modelType: "image-to-video", durations: seedanceFastDurations, resolutions: seedanceResolutions),
        ]
    }

    // MARK: - Audio

    /// Seed Audio 1.0's 25 named voices (harness registry, 2026-07-17). The default,
    /// "Describe in prompt", lets the prompt steer delivery instead of picking a fixed voice.
    private static let seedAudioVoices = [
        "Describe in prompt",
        "Aria", "Nova", "Sol", "Ember", "Cove", "Vale", "Onyx", "Iris",
        "Juno", "Atlas", "Wren", "Sage", "Rowan", "Lyra", "Orion", "Hazel",
        "Milo", "Freya", "Reed", "Ada", "Cyrus", "Nora", "Felix", "Luna",
    ]

    /// Audio models Venice accepts but a key's `/models` may omit. Seed Audio 1.0 is a premium
    /// prompt-directed narration/VO model on the async audio queue (25 voices, 2048-char cap,
    /// speed 0.5–2, mp3/wav, ~$0.0029/s — harness `b137102`, 2026-07-17). The three music
    /// models are added conservatively (prompt-only, no lyrics/instrumental/style flags) pending
    /// a live capability probe, per the never-over-enable rule in the harness-sync workspace rule.
    private static var audioEntries: [[String: Any]] {
        [
            audioEntry(
                id: "seed-audio-1-0", name: "Seed Audio 1.0", type: "music", category: "tts",
                constraints: [
                    "voices": seedAudioVoices,
                    "default_voice": "Describe in prompt",
                    "max_prompt_length": 2048,
                    "min_speed": 0.5,
                    "max_speed": 2.0,
                    "formats": ["mp3", "wav"],
                ],
                usdPerSecond: 0.0029
            ),
            audioEntry(id: "minimax-music-v25", name: "MiniMax Music v2.5", type: "music", category: "music"),
            audioEntry(id: "minimax-music-v26", name: "MiniMax Music v2.6", type: "music", category: "music"),
            audioEntry(id: "lyria-3-pro", name: "Lyria 3 Pro", type: "music", category: "music"),
        ]
    }

    private static func audioEntry(
        id: String, name: String, type: String, category: String,
        constraints extra: [String: Any] = [:], usdPerSecond: Double? = nil
    ) -> [String: Any] {
        var constraints: [String: Any] = ["category": category]
        constraints.merge(extra) { _, new in new }
        var spec: [String: Any] = ["name": name, "constraints": constraints]
        if let usdPerSecond { spec["pricing"] = ["usd_per_second": usdPerSecond] }
        return ["id": id, "type": type, "model_spec": spec]
    }

    private static func videoEntry(id: String, name: String, modelType: String, durations: [String], resolutions: [String]) -> [String: Any] {
        [
            "id": id,
            "type": "video",
            "model_spec": [
                "name": name,
                "constraints": [
                    "aspect_ratios": seedanceAspectRatios,
                    "resolutions": resolutions,
                    "durations": durations,
                    "model_type": modelType,
                    "audio_configurable": true,
                    "video_input": false,
                ],
            ],
        ]
    }
}
