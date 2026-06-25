import Foundation

enum VideoToAudioEditKind {
    case music
    case sfx

    var title: String {
        switch self {
        case .music: "Generate Music"
        case .sfx: "Generate SFX"
        }
    }

    var providerName: String {
        switch self {
        case .music: "Music"
        case .sfx: "SFX"
        }
    }

    var action: EditAction {
        switch self {
        case .music: .generateMusic
        case .sfx: .generateSFX
        }
    }

    var iconName: String {
        switch self {
        case .music: "music.note"
        case .sfx: "waveform"
        }
    }

    var description: String {
        switch self {
        case .music: "Generate music from a prompt for this clip"
        case .sfx: "Generate a sound effect from a prompt"
        }
    }

    var timelineActionName: String {
        switch self {
        case .music: "Add Music"
        case .sfx: "Add Sound Effects"
        }
    }

    /// Preferred Venice model id for this kind, when available.
    var preferredModelId: String {
        switch self {
        case .music: "lyria-3-pro"
        case .sfx: "elevenlabs-sound-effects-v2"
        }
    }

    var category: AudioModelConfig.Category {
        switch self {
        case .music: .music
        case .sfx: .sfx
        }
    }

    /// Resolve a Venice model for this kind. Venice audio is text-conditioned
    /// (no video-to-audio), so we just pick a model of the matching category —
    /// the preferred id if present, otherwise the first of that category.
    @MainActor
    var model: AudioModelConfig? {
        if let preferred = AudioModelConfig.allModels.first(where: { $0.id == preferredModelId }) {
            return preferred
        }
        return AudioModelConfig.allModels.first { $0.category == category }
    }
}
