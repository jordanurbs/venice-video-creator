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
    var defaultShotSeconds: Double
    var shots: [Shot]
    var characters: [CharacterSpec]
    var updatedAt: Date

    init(
        title: String = "Untitled Production",
        logline: String? = nil,
        aspectRatio: String = "16:9",
        resolution: String = "1080p",
        defaultModel: String? = nil,
        defaultShotSeconds: Double = 5,
        shots: [Shot] = [],
        characters: [CharacterSpec] = [],
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.logline = logline
        self.aspectRatio = aspectRatio
        self.resolution = resolution
        self.defaultModel = defaultModel
        self.defaultShotSeconds = defaultShotSeconds
        self.shots = shots
        self.characters = characters
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case title, logline, aspectRatio, resolution, defaultModel, defaultShotSeconds, shots, characters, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled Production"
        logline = try c.decodeIfPresent(String.self, forKey: .logline)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio) ?? "16:9"
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution) ?? "1080p"
        defaultModel = try c.decodeIfPresent(String.self, forKey: .defaultModel)
        defaultShotSeconds = try c.decodeIfPresent(Double.self, forKey: .defaultShotSeconds) ?? 5
        shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        characters = try c.decodeIfPresent([CharacterSpec].self, forKey: .characters) ?? []
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    func shot(id: String) -> Shot? { shots.first { $0.id == id } }
    func character(id: String) -> CharacterSpec? { characters.first { $0.id == id } }

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
    /// The prompt actually sent to the video model.
    var prompt: String
    var durationSeconds: Double
    var motionLevel: ShotMotionLevel
    var transition: ShotTransition
    /// Optional per-shot video model override (Venice slug); falls back to the plan default.
    var modelOverride: String?
    var characterIds: [String]
    var dialogue: [ShotDialogue]
    /// How to treat the video model's own audio track once the clip is placed.
    var nativeAudio: ShotNativeAudio
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
        durationSeconds: Double = 5,
        motionLevel: ShotMotionLevel = .moderate,
        transition: ShotTransition = .cut,
        modelOverride: String? = nil,
        characterIds: [String] = [],
        dialogue: [ShotDialogue] = [],
        nativeAudio: ShotNativeAudio = .keep,
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
        self.durationSeconds = durationSeconds
        self.motionLevel = motionLevel
        self.transition = transition
        self.modelOverride = modelOverride
        self.characterIds = characterIds
        self.dialogue = dialogue
        self.nativeAudio = nativeAudio
        self.status = status
        self.storyboardAssetId = storyboardAssetId
        self.videoAssetId = videoAssetId
        self.takes = takes
        self.qaSummary = qaSummary
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case id, slug, summary, prompt, durationSeconds, motionLevel, transition
        case modelOverride, characterIds, dialogue, nativeAudio, status
        case storyboardAssetId, videoAssetId, takes, qaSummary, failureReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        slug = try c.decodeIfPresent(String.self, forKey: .slug)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        prompt = try c.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds) ?? 5
        motionLevel = try c.decodeIfPresent(ShotMotionLevel.self, forKey: .motionLevel) ?? .moderate
        transition = try c.decodeIfPresent(ShotTransition.self, forKey: .transition) ?? .cut
        modelOverride = try c.decodeIfPresent(String.self, forKey: .modelOverride)
        characterIds = try c.decodeIfPresent([String].self, forKey: .characterIds) ?? []
        dialogue = try c.decodeIfPresent([ShotDialogue].self, forKey: .dialogue) ?? []
        nativeAudio = try c.decodeIfPresent(ShotNativeAudio.self, forKey: .nativeAudio) ?? .keep
        status = try c.decodeIfPresent(ShotStatus.self, forKey: .status) ?? .planned
        storyboardAssetId = try c.decodeIfPresent(String.self, forKey: .storyboardAssetId)
        videoAssetId = try c.decodeIfPresent(String.self, forKey: .videoAssetId)
        takes = try c.decodeIfPresent([ShotTake].self, forKey: .takes) ?? []
        qaSummary = try c.decodeIfPresent(String.self, forKey: .qaSummary)
        failureReason = try c.decodeIfPresent(String.self, forKey: .failureReason)
    }

    /// Dialogue lines the video model should hear (on-screen speech), excluding
    /// voice-over/narration which would make the model synthesize a competing narrator.
    var onScreenDialogue: [ShotDialogue] { dialogue.filter { !$0.voiceOver } }
    var voiceOverDialogue: [ShotDialogue] { dialogue.filter { $0.voiceOver } }
    var hasVoiceOver: Bool { dialogue.contains { $0.voiceOver } }
}

// MARK: - Enums

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

    init(
        id: String = UUID().uuidString,
        videoAssetId: String? = nil,
        model: String? = nil,
        createdAt: Date = Date(),
        note: String? = nil,
        qaScore: Double? = nil,
        qaSummary: String? = nil
    ) {
        self.id = id
        self.videoAssetId = videoAssetId
        self.model = model
        self.createdAt = createdAt
        self.note = note
        self.qaScore = qaScore
        self.qaSummary = qaSummary
    }

    private enum CodingKeys: String, CodingKey { case id, videoAssetId, model, createdAt, note, qaScore, qaSummary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        videoAssetId = try c.decodeIfPresent(String.self, forKey: .videoAssetId)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        note = try c.decodeIfPresent(String.self, forKey: .note)
        qaScore = try c.decodeIfPresent(Double.self, forKey: .qaScore)
        qaSummary = try c.decodeIfPresent(String.self, forKey: .qaSummary)
    }
}

// MARK: - Character

/// A recurring on-screen character: reference images for visual consistency (Seedance R2V)
/// and a locked TTS voice for its dialogue. Provenance records how the references were made
/// so the Seedance face gate can be satisfied.
struct CharacterSpec: Codable, Sendable, Equatable, Identifiable {
    let id: String
    var name: String
    var description: String?
    var referenceImageAssetIds: [String]
    var lockedVoiceId: String?
    /// Audio model slug the locked voice belongs to (e.g. "seed-audio-1-0").
    var voiceModel: String?
    var provenance: CharacterProvenance?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String = "",
        description: String? = nil,
        referenceImageAssetIds: [String] = [],
        lockedVoiceId: String? = nil,
        voiceModel: String? = nil,
        provenance: CharacterProvenance? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.referenceImageAssetIds = referenceImageAssetIds
        self.lockedVoiceId = lockedVoiceId
        self.voiceModel = voiceModel
        self.provenance = provenance
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, description, referenceImageAssetIds, lockedVoiceId, voiceModel, provenance, createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description)
        referenceImageAssetIds = try c.decodeIfPresent([String].self, forKey: .referenceImageAssetIds) ?? []
        lockedVoiceId = try c.decodeIfPresent(String.self, forKey: .lockedVoiceId)
        voiceModel = try c.decodeIfPresent(String.self, forKey: .voiceModel)
        provenance = try c.decodeIfPresent(CharacterProvenance.self, forKey: .provenance)
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
