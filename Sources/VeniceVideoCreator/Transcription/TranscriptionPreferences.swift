import Foundation

/// User preference for which transcription backend to use.
///
/// On-device (Apple Speech) is the default — private, free, offline. Venice
/// cloud STT (`/audio/transcriptions`) is an opt-in alternative for languages
/// or accuracy Apple Speech doesn't cover well. Falls back to on-device on any
/// cloud error or when no Venice key is set.
@Observable
@MainActor
final class TranscriptionPreferences {
    static let shared = TranscriptionPreferences()

    private static let useVeniceKey = "transcriptionUseVenice"
    private static let modelKey = "transcriptionVeniceModel"

    /// Common Venice ASR model ids (see `GET /models?type=asr`).
    static let availableModels: [(id: String, name: String)] = [
        ("nvidia/parakeet-tdt-0.6b-v3", "Parakeet (fast, English)"),
        ("openai/whisper-large-v3", "Whisper Large v3 (multilingual)"),
        ("fal-ai/wizper", "Wizper"),
        ("elevenlabs/scribe-v2", "ElevenLabs Scribe v2"),
        ("stt-xai-v1", "xAI STT"),
    ]

    var useVenice: Bool {
        didSet { UserDefaults.standard.set(useVenice, forKey: Self.useVeniceKey) }
    }
    var veniceModel: String {
        didSet { UserDefaults.standard.set(veniceModel, forKey: Self.modelKey) }
    }

    private init() {
        useVenice = UserDefaults.standard.bool(forKey: Self.useVeniceKey)
        veniceModel = UserDefaults.standard.string(forKey: Self.modelKey)
            ?? Self.availableModels[0].id
    }

    /// Whether the Venice backend should actually be used right now.
    var veniceActive: Bool { useVenice && VeniceKeychain.hasKey }
}
