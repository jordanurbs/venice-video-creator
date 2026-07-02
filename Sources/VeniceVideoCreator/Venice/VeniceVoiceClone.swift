import Foundation

/// A user-cloned voice (`vv_…` handle from Venice `/audio/voices`), usable as a
/// `voice` value on `/audio/speech` with the matching model family.
struct ClonedVoice: Codable, Sendable, Identifiable, Hashable {
    let id: String      // the `vv_…` handle
    let label: String
    let model: String   // the TTS model the clone was created with
}

@Observable
@MainActor
final class ClonedVoiceStore {
    static let shared = ClonedVoiceStore()

    private static let key = "clonedVoices"
    private(set) var voices: [ClonedVoice]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([ClonedVoice].self, from: data) {
            voices = decoded
        } else {
            voices = []
        }
    }

    func voices(forModel model: String) -> [ClonedVoice] {
        voices.filter { $0.model == model }
    }

    func add(_ voice: ClonedVoice) {
        voices.removeAll { $0.id == voice.id }
        voices.append(voice)
        persist()
    }

    func remove(_ voice: ClonedVoice) {
        voices.removeAll { $0.id == voice.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(voices) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Whether a TTS model supports voice cloning (Chatterbox HD zero-shot, MiniMax).
    static func isCloneCapable(_ modelId: String) -> Bool {
        let id = modelId.lowercased()
        return id.contains("chatterbox") || id.contains("minimax")
    }
}

extension VeniceAPI {
    /// Venice `/audio/voices` — clone a voice from an audio sample. Returns the
    /// `vv_…` handle for use as `voice` on `/audio/speech`.
    func cloneVoice(sampleFileURL: URL, name: String, model: String) async throws -> String {
        let data = try Data(contentsOf: sampleFileURL)
        var fields = ["model": model]
        if !name.isEmpty { fields["name"] = name }
        let request = makeMultipartRequest(
            path: "audio/voices",
            fields: fields,
            file: (
                field: "file",
                filename: sampleFileURL.lastPathComponent,
                contentType: Self.voiceSampleContentType(for: sampleFileURL),
                data: data
            )
        )
        let (respData, response) = try await self.data(for: request)
        try Self.assertOK(data: respData, response: response)
        let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
        guard let handle = Self.extractVoiceHandle(obj) else {
            throw VeniceError.decode("no voice handle in response")
        }
        return handle
    }

    private static func extractVoiceHandle(_ obj: [String: Any]) -> String? {
        let candidates: [Any?] = [
            obj["voiceId"], obj["voice_id"], obj["id"], obj["voice"], obj["handle"],
            (obj["data"] as? [String: Any])?["voiceId"],
            (obj["data"] as? [String: Any])?["id"],
            (obj["data"] as? [String: Any])?["voice"],
        ]
        for case let value as String in candidates.compactMap({ $0 }) where !value.isEmpty {
            return value
        }
        return nil
    }

    private static func voiceSampleContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav", "wave": return "audio/wav"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }
}
