import Foundation

/// The typed artifact the in-app agent (and the production panel) build a video from:
/// an ordered list of `Shot`s plus the `CharacterSpec`s they reference. Persisted as an
/// optional field on `MediaManifest` and mirrored to a human-readable markdown document.
///
/// All nested types decode tolerantly (missing keys fall back to defaults) so a plan
/// written by a newer build still opens in an older one and vice-versa, matching the
/// version-safe style of `MediaManifest`.
struct ShotPlan: Codable, Sendable, Equatable {
    var title: String
    var logline: String?
    var aspectRatio: String
    var resolution: String
    /// Default video model for shots without an override (a Venice slug).
    var defaultModel: String?
    /// Image model locked for ALL reference-image generation in this project
    /// (characters, locations, objects) — chosen via the reference bakeoff so
    /// every entity's refs share one look. Nil = first enabled model.
    var referenceImageModel: String?
    /// The series' locked visual system — ONE authored sentence naming medium,
    /// palette, lighting language, and lens character (harness rule 11 /
    /// anti-pattern 2). Front-loaded into every storyboard panel, video, and
    /// multi-shot prompt, and into character/location reference generations, so
    /// the whole production shares one look instead of drifting per shot. Nil =
    /// no locked style (prompts fall back to their own phrasing).
    var styleBlock: String?
    var defaultShotSeconds: Double
    var shots: [Shot]
    var characters: [CharacterSpec]
    var locations: [LocationSpec]
    /// Locked series seed for reproducibility (harness rule seeds): when set and
    /// the routed family accepts a seed, every shot generates from it so a run is
    /// repeatable. Only applied on seed-capable models; nil leaves the queue to
    /// pick a random seed per job (current behavior).
    var seed: Int?
    var updatedAt: Date

    init(
        title: String = "Untitled Production",
        logline: String? = nil,
        aspectRatio: String = "16:9",
        resolution: String = "1080p",
        defaultModel: String? = nil,
        referenceImageModel: String? = nil,
        styleBlock: String? = nil,
        defaultShotSeconds: Double = 5,
        shots: [Shot] = [],
        characters: [CharacterSpec] = [],
        locations: [LocationSpec] = [],
        seed: Int? = nil,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.logline = logline
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.defaultModel = defaultModel
        self.referenceImageModel = referenceImageModel
        self.styleBlock = styleBlock
        self.defaultShotSeconds = defaultShotSeconds
        self.shots = shots
        self.characters = characters
        self.locations = locations
        self.seed = seed
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case title, logline, aspectRatio, resolution, defaultModel, referenceImageModel, styleBlock, defaultShotSeconds, shots, characters, locations, seed, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Production"
        logline = try c.decodeIfPresent(String.self, forKey: .logline)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? "16:9"
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? "1080p"
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        referenceImageModel = try c.decodeIfPresent(String.self, forKey: .referenceImageModel)
        styleBlock = try c.decodeIfPresent(String.self, forKey: .styleBlock)
        defaultShotSeconds = try c.decodeIfPresent(Double.self, forKey: .defaultShotSeconds) ?? 5
        shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        characters = try c.decodeIfPresent([CharacterSpec].self, forKey: .characters) ?? []
        locations = try c.decodeIfPresent([LocationSpec].self, forKey: .locations) ?? []
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func shot(id: String) -> Shot? { shots.first { $0.id == id } }
    func character(id: String) -> CharacterSpec? { characters.first { $0.id == id } }
    func location(id: String) -> LocationSpec? { locations.first { $0.id == id } }

    var totalPlannedSeconds: Double { shots.reduce(0) { $0 + $1.durationSeconds } }
}

// MARK: - Shot

/// A single planned shot. Carries both its human-readable summary and the generation
/// prompt, its lifecycle status, the storyboard/video assets it produces, and a take
/// history so regeneration is non-destructive.
struct Shot: Codable, Sendable, Equatable, Identifiable {
    let id: String
    /// Short handle shown in the UI and chat, e.g. "S1", "S2a".
    var slug: String?
    /// One-line human description of the shot.
    var summary: String
    /// The VIDEO prompt — camera movement, subject action, what moves. This is
    /// the paid path's prompt; the pre-flight gate rejects motionless ones.
    var prompt: String
    /// Optional STORYBOARD-panel prompt (a still frame: composition, framing,
    /// look — no motion language needed). Nil = panels compose from `prompt`,
    /// which keeps pre-split plans working unchanged. Split 2026-08-10 so a
    /// panel-caption prompt can never masquerade as the video prompt again.
    var storyboardPrompt: String?
    var durationSeconds: Double
    var motionLevel: ShotMotionLevel
    var transition: ShotTransition
    /// Optional per-shot video model override (Venice slug); falls back to the plan default.
    var modelOverride: String?
    var characterIds: [String]
    var locationIds: [String]
    var dialogue: [ShotDialogue]
    /// Explicit spatial blocking for the shot (harness rule 49): where each
    /// character/object is relative to the location's fixed anchors
    /// (`LocationSpec.spatialAnchors`), to each other, and to the frame — plus
    /// facing/eyeline. One or two sentences of concrete geometry, e.g. "MARA at
    /// the bar counter, screen left, facing right toward the door; JAX enters
    /// through the door in the background, screen right." Injected verbatim
    /// into the video prompt so placement is stated identically on every
    /// generation instead of being re-inferred per take (side-swaps, teleporting
    /// props, and mirrored geography come from re-inference).
    var blocking: String?
    /// Multi-shot grouping opt-out (harness `allowMultiShot`): set false to
    /// force this shot to render as its own generation even when the planner
    /// would group it into a multi-shot unit. nil/true = groupable.
    var allowMultiShot: Bool?
    /// How to treat the video model's own audio track once the clip is placed.
    var nativeAudio: ShotNativeAudio
    /// What KIND of audio the model should generate (prompt steering). Audio is
    /// always generated; this shapes its content, `nativeAudio` shapes the mix.
    var audioContent: ShotAudioContent
    /// Explicit audio reference (audio_url) for this shot. When set it wins over
    /// the default cast-voice attachment.
    var audioReferenceAssetId: String?
    /// Attach the locked voice reference of the shot's first voiced character as
    /// the audio reference when the routed model supports audio input. Default on.
    var attachCastVoiceReference: Bool
    var status: ShotStatus
    var storyboardAssetId: String?
    var videoAssetId: String?
    var takes: [ShotTake]
    var qaSummary: String?
    var failureReason: String?

    init(
        id: String = UUID().uuidString,
        slug: String? = nil,
        summary: String = "",
        prompt: String = "",
        storyboardPrompt: String? = nil,
        durationSeconds: Double = 5,
        motionLevel: ShotMotionLevel = .moderate,
        transition: ShotTransition = .cut,
        modelOverride: String? = nil,
        characterIds: [String] = [],
        locationIds: [String] = [],
        dialogue: [ShotDialogue] = [],
        blocking: String? = nil,
        allowMultiShot: Bool? = nil,
        nativeAudio: ShotNativeAudio = .keep,
        audioContent: ShotAudioContent = .full,
        audioReferenceAssetId: String? = nil,
        attachCastVoiceReference: Bool = true,
        status: ShotStatus = .planned,
        storyboardAssetId: String? = nil,
        videoAssetId: String? = nil,
        takes: [ShotTake] = [],
        qaSummary: String? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.slug = slug
        self.summary = summary
        self.prompt = prompt
        self.storyboardPrompt = storyboardPrompt
        self.durationSeconds = durationSeconds
        self.motionLevel = motionLevel
        self.transition = transition
        self.modelOverride = modelOverride
        self.characterIds = characterIds
        self.locationIds = locationIds
        self.dialogue = dialogue
        self.blocking = blocking
        self.allowMultiShot = allowMultiShot
        self.nativeAudio = nativeAudio
        self.audioContent = audioContent
        self.audioReferenceAssetId = audioReferenceAssetId
        self.attachCastVoiceReference = attachCastVoiceReference
        self.status = status
        self.storyboardAssetId = storyboardAssetId
        self.videoAssetId = videoAssetId
        self.takes = takes
        self.qaSummary = qaSummary
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, slug, summary, prompt, storyboardPrompt, durationSeconds, motionLevel, transition
        case modelOverride, characterIds, locationIds, dialogue, blocking, allowMultiShot, nativeAudio, audioContent, status
        case audioReferenceAssetId, attachCastVoiceReference
        case storyboardAssetId, videoAssetId, takes, qaSummary, failureReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        storyboardPrompt = try c.decodeIfPresent(String.self, forKey: .storyboardPrompt)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 5
        motionLevel = try c.decodeIfPresent(ShotMotionLevel.self, forKey: .motionLevel) ?? .moderate
        transition = try c.decodeIfPresent(ShotTransition.self, forKey: .transition) ?? .cut
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        characterIds = try c.decodeIfPresent([String].self, forKey: .characterIds) ?? []
        locationIds = try c.decodeIfPresent([String].self, forKey: .locationIds) ?? []
        dialogue = try c.decodeIfPresent([ShotDialogue].self, forKey: .dialogue) ?? []
        blocking = try c.decodeIfPresent(String.self, forKey: .blocking)
        allowMultiShot = try c.decodeIfPresent(Bool.self, forKey: .allowMultiShot)
        nativeAudio = try c.decodeIfPresent(ShotNativeAudio.self, forKey: .nativeAudio) ?? .keep
        audioContent = try c.decodeIfPresent(ShotAudioContent.self, forKey: .audioContent) ?? .full
        audioReferenceAssetId = try c.decodeIfPresent(String.self, forKey: .audioReferenceAssetId)
        attachCastVoiceReference = try c.decodeIfPresent(Bool.self, forKey: .attachCastVoiceReference) ?? true
        status = try c.decodeIfPresent(ShotStatus.self, forKey: .status) ?? .planned
        storyboardAssetId = try c.decodeIfPresent(String.self, forKey: .storyboardAssetId)
        videoAssetId = try c.decodeIfPresent(String.self, forKey: .videoAssetId)
        takes = try c.decodeIfPresent([ShotTake].self, forKey: .takes) ?? []
        qaSummary = try c.decodeIfPresent(String.self, forKey: .qaSummary)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
    }

    /// The base the storyboard-panel prompt composes from: the dedicated
    /// storyboard prompt when authored, else the video prompt, else the summary.
    var effectiveStoryboardBase: String {
        if let sb = storyboardPrompt, !sb.isEmpty { return sb }
        return prompt.isEmpty ? summary : prompt
    }

    /// Dialogue lines the video model should hear (on-screen speech), excluding
    /// voice-over/narration which would make the model synthesize a competing narrator.
    var onScreenDialogue: [ShotDialogue] { dialogue.filter { !$0.voiceOver } }
    var voiceOverDialogue: [ShotDialogue] { dialogue.filter { $0.voiceOver } }
    var hasVoiceOver: Bool { dialogue.contains { $0.voiceOver } }
}

// MARK: - Enums

/// A cast entry's nature: a person (face provenance gate + lockable voice) or an
/// inanimate object/prop (no face, no voice) kept for reference consistency.
enum CharacterKind: String, Codable, Sendable, CaseIterable {
    case person, object
}

/// Motion intensity hint, routed into the prompt and (later) model selection.
enum ShotMotionLevel: String, Codable, Sendable, CaseIterable {
    case still, subtle, moderate, dynamic
}

/// Transition into the *next* shot. `dissolve`/`matchCut` drive last-frame chaining.
enum ShotTransition: String, Codable, Sendable, CaseIterable {
    case cut, dissolve, matchCut, fadeIn, fadeOut, fadeToBlack
}

enum ShotStatus: String, Codable, Sendable, CaseIterable {
    case planned, storyboarded, generating, qa, approved, placed, failed
}

/// How the video model's own generated audio track is handled once a shot is placed.
enum ShotNativeAudio: String, Codable, Sendable, CaseIterable {
    case keep, duck, mute
}

/// What kind of audio the model should generate. Content steering only —
/// audio is always generated; the mix is `ShotNativeAudio`'s job.
enum ShotAudioContent: String, Codable, Sendable, CaseIterable {
    /// Everything the prompt implies (speech, ambience, music).
    case full
    /// Ambient + SFX + speech, but no music bed (post adds music).
    case noMusic
    /// Ambience/SFX only — no speech, no music.
    case ambienceOnly
    /// Speech only, minimal ambience, no music.
    case dialogueOnly

    var label: String {
        switch self {
        case .full: "Full"
        case .noMusic: "No music"
        case .ambienceOnly: "Ambience only"
        case .dialogueOnly: "Dialogue only"
        }
    }
}

// MARK: - Dialogue

/// A spoken line tied to a shot. Voice-over lines drive the TTS pass but are kept out of
/// the video prompt (harness VO rule 03a17f4): the video model otherwise synthesizes a
/// competing narrator. On-screen dialogue may appear in the prompt.
struct ShotDialogue: Codable, Sendable, Equatable, Identifiable {
    let id: String
    /// Links to a `CharacterSpec` for the locked voice; nil for anonymous/narrator lines.
    var characterId: String?
    /// Free-text speaker label used when no character is linked (e.g. "NARRATOR").
    var speaker: String?
    var text: String
    var voiceOver: Bool

    init(
        id: String = UUID().uuidString,
        characterId: String? = nil,
        speaker: String? = nil,
        text: String = "",
        voiceOver: Bool = false
    ) {
        self.id = id
        self.characterId = characterId
        self.speaker = speaker
        self.text = text
        self.voiceOver = voiceOver
    }

    private enum CodingKeys: String, CodingKey { case id, characterId, speaker, text, voiceOver }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        characterId = try c.decodeIfPresent(String.self, forKey: .characterId)
        speaker = try c.decodeIfPresent(String.self, forKey: .speaker)
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        voiceOver = try c.decodeIfPresent(Bool.self, forKey: .voiceOver) ?? false
    }
}

// MARK: - Take history

/// One generation attempt for a shot. Kept so `regenerate_shot` is non-destructive and
/// the user can compare/restore earlier takes.
struct ShotTake: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var videoAssetId: String?
    var model: String?
    var createdAt: Date
    var note: String?
    var qaScore: Double?
    var qaSummary: String?
    /// The full submitted call for this take (harness rule 39 recipe): final
    /// prompt string, model, reference asset ids, negative prompt, seed. Makes a
    /// take replayable ("regenerate exactly take 2 but change one word") and gives
    /// an inspectable prompt history per shot.
    var recipe: GenerationInput?

    /// The seed this take was generated with, when the routed family accepts one
    /// (mirror of `recipe?.seed`, hoisted for cheap display/replay).
    var seed: Int?

    init(
        id: String = UUID().uuidString,
        videoAssetId: String? = nil,
        model: String? = nil,
        createdAt: Date = Date(),
        note: String? = nil,
        qaScore: Double? = nil,
        qaSummary: String? = nil,
        recipe: GenerationInput? = nil,
        seed: Int? = nil
    ) {
        self.id = id
        self.videoAssetId = videoAssetId
        self.model = model
        self.createdAt = createdAt
        self.note = note
        self.qaScore = qaScore
        self.qaSummary = qaSummary
        self.recipe = recipe
        self.seed = seed
    }

    private enum CodingKeys: String, CodingKey { case id, videoAssetId, model, createdAt, note, qaScore, qaSummary, recipe, seed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        videoAssetId = try c.decodeIfPresent(String.self, forKey: .videoAssetId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        note = try c.decodeIfPresent(String.self, forKey: .note)
        qaScore = try c.decodeIfPresent(Double.self, forKey: .qaScore)
        qaSummary = try c.decodeIfPresent(String.self, forKey: .qaSummary)
        recipe = try c.decodeIfPresent(GenerationInput.self, forKey: .recipe)
        seed = try c.decodeIfPresent(Int.self, forKey: .seed)
    }
}

// MARK: - Character

/// A recurring on-screen character: reference images for visual consistency (Seedance R2V)
/// and a locked TTS voice for its dialogue. Provenance records how the references were made
/// so the Seedance face gate can be satisfied.
struct CharacterSpec: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    /// Person (face gate + voice) or an inanimate object/prop (no face, no voice)
    /// reused as a reference for visual consistency. Both live in the Cast & Objects tab.
    var kind: CharacterKind
    var description: String?
    /// The exact styled prompt reference images are generated from (carries the
    /// production's look, e.g. photorealism). Falls back to description/name.
    var visualPrompt: String?
    var referenceImageAssetIds: [String]
    /// When set, this single reference is the character's canonical look:
    /// generation consumers use ONLY it, so models aren't fed divergent takes.
    var lockedReferenceAssetId: String?
    var lockedVoiceId: String?
    /// Audio model slug the locked voice belongs to (e.g. "seed-audio-1-0").
    var voiceModel: String?
    /// Generated voice sample assets (audition takes), mirroring referenceImageAssetIds.
    var voiceSampleAssetIds: [String]
    /// When set, this audio asset is the character's canonical voice: shot
    /// generation attaches it as the audio reference (audio_url) by default.
    var voiceReferenceAssetId: String?
    var provenance: CharacterProvenance?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        kind: CharacterKind = .person,
        description: String? = nil,
        visualPrompt: String? = nil,
        referenceImageAssetIds: [String] = [],
        lockedReferenceAssetId: String? = nil,
        lockedVoiceId: String? = nil,
        voiceModel: String? = nil,
        voiceSampleAssetIds: [String] = [],
        voiceReferenceAssetId: String? = nil,
        provenance: CharacterProvenance? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.description = description
        self.visualPrompt = visualPrompt
        self.referenceImageAssetIds = referenceImageAssetIds
        self.lockedReferenceAssetId = lockedReferenceAssetId
        self.lockedVoiceId = lockedVoiceId
        self.voiceModel = voiceModel
        self.voiceSampleAssetIds = voiceSampleAssetIds
        self.voiceReferenceAssetId = voiceReferenceAssetId
        self.provenance = provenance
        self.createdAt = createdAt
    }

    /// Prompt used to generate this character's reference images.
    var effectiveVisualPrompt: String {
        if let p = visualPrompt, !p.isEmpty { return p }
        if let d = description, !d.isEmpty { return d }
        return name
    }

    /// Reference ids generation consumers should use: the locked one when set
    /// (and still present), otherwise all of them.
    var activeReferenceAssetIds: [String] {
        if let locked = lockedReferenceAssetId, referenceImageAssetIds.contains(locked) {
            return [locked]
        }
        return referenceImageAssetIds
    }

    var isObject: Bool { kind == .object }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, description, visualPrompt, referenceImageAssetIds
        case lockedReferenceAssetId, lockedVoiceId, voiceModel
        case voiceSampleAssetIds, voiceReferenceAssetId, provenance, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(CharacterKind.self, forKey: .kind) ?? .person
        description = try c.decodeIfPresent(String.self, forKey: .description)
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt)
        referenceImageAssetIds = try c.decodeIfPresent([String].self, forKey: .referenceImageAssetIds) ?? []
        lockedReferenceAssetId = try c.decodeIfPresent(String.self, forKey: .lockedReferenceAssetId)
        lockedVoiceId = try c.decodeIfPresent(String.self, forKey: .lockedVoiceId)
        voiceModel = try c.decodeIfPresent(String.self, forKey: .voiceModel)
        voiceSampleAssetIds = try c.decodeIfPresent([String].self, forKey: .voiceSampleAssetIds) ?? []
        voiceReferenceAssetId = try c.decodeIfPresent(String.self, forKey: .voiceReferenceAssetId)
        provenance = try c.decodeIfPresent(CharacterProvenance.self, forKey: .provenance)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

// MARK: - Location

/// A recurring setting/location in the production: reference images keep the
/// environment consistent across shots, mirroring `CharacterSpec` (no voice).
struct LocationSpec: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var description: String?
    /// The exact styled prompt reference images are generated from.
    var visualPrompt: String?
    var referenceImageAssetIds: [String]
    /// When set, this single reference is the location's canonical look.
    var lockedReferenceAssetId: String?
    /// The locked geography of the place (harness rule 49): 3-5 named landmarks
    /// and their fixed relative positions, e.g. "bar counter along the left
    /// wall; entrance door on the right; pool table center-back; neon sign
    /// above the door." Injected as "Fixed layout (never rearrange): …" into
    /// every video prompt for shots tagged with this location, so placement
    /// language ("at the counter", "by the door") resolves to the same physical
    /// layout in every generation.
    var spatialAnchors: String?
    /// The locked lighting of the place (harness storyboard pass-1 + anti-pattern
    /// 7): time of day, key/fill direction, colour temperature and mood, e.g.
    /// "late-afternoon sun through the west windows, warm key from screen-left,
    /// cool shadows, practical neon fill." Injected into storyboard panel prompts
    /// so consecutive panels of the same location match, and carried forward as
    /// the "match the previous panel's lighting" instruction.
    var lightingNotes: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        description: String? = nil,
        visualPrompt: String? = nil,
        referenceImageAssetIds: [String] = [],
        lockedReferenceAssetId: String? = nil,
        spatialAnchors: String? = nil,
        lightingNotes: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.visualPrompt = visualPrompt
        self.referenceImageAssetIds = referenceImageAssetIds
        self.lockedReferenceAssetId = lockedReferenceAssetId
        self.spatialAnchors = spatialAnchors
        self.lightingNotes = lightingNotes
        self.createdAt = createdAt
    }

    var effectiveVisualPrompt: String {
        if let p = visualPrompt, !p.isEmpty { return p }
        if let d = description, !d.isEmpty { return d }
        return name
    }

    /// Location references are an ANGLE LADDER of one coherent space
    /// (wide/medium/detail — harness `LOCATION_ANGLES`), not divergent takes,
    /// so a lock PRIORITIZES its angle rather than excluding the rest.
    /// (Characters differ: their refs are alternative looks, locked wins alone.)
    var activeReferenceAssetIds: [String] {
        if let locked = lockedReferenceAssetId, referenceImageAssetIds.contains(locked) {
            return [locked] + referenceImageAssetIds.filter { $0 != locked }
        }
        return referenceImageAssetIds
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, visualPrompt, referenceImageAssetIds, lockedReferenceAssetId, spatialAnchors, lightingNotes, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        visualPrompt = try c.decodeIfPresent(String.self, forKey: .visualPrompt)
        referenceImageAssetIds = try c.decodeIfPresent([String].self, forKey: .referenceImageAssetIds) ?? []
        lockedReferenceAssetId = try c.decodeIfPresent(String.self, forKey: .lockedReferenceAssetId)
        spatialAnchors = try c.decodeIfPresent(String.self, forKey: .spatialAnchors)
        lightingNotes = try c.decodeIfPresent(String.self, forKey: .lightingNotes)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

/// Ported from the harness `provenance.ts`: records how a generated reference image was
/// produced so the Seedance face-provenance gate (real vs. AI-generated faces) can be met.
struct CharacterProvenance: Codable, Sendable, Equatable {
    var generationModel: String?
    var editModels: [String]?
    var hasFace: Bool?

    init(generationModel: String? = nil, editModels: [String]? = nil, hasFace: Bool? = nil) {
        self.generationModel = generationModel
        self.editModels = editModels
        self.hasFace = hasFace
    }

    private enum CodingKeys: String, CodingKey { case generationModel, editModels, hasFace }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        generationModel = try c.decodeIfPresent(String.self, forKey: .generationModel)
        editModels = try c.decodeIfPresent([String].self, forKey: .editModels)
        hasFace = try c.decodeIfPresent(Bool.self, forKey: .hasFace)
    }
}
