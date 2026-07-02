import AVFoundation
import Foundation

extension VeniceAPI {
    /// Venice `/audio/transcriptions` — cloud STT. Returns a `TranscriptionResult`
    /// shaped like the on-device transcriber so it slots into captions + search.
    /// `fileURL` must be an upload-ready audio file (wav/m4a/mp3/…); callers
    /// extract/export from video first.
    func transcribeAudio(
        fileURL: URL,
        model: String,
        language: String? = nil
    ) async throws -> TranscriptionResult {
        let data = try Data(contentsOf: fileURL)
        var fields: [String: String] = [
            "model": model,
            "response_format": "json",
            "timestamps": "true",
        ]
        if let language, !language.isEmpty { fields["language"] = language }
        let request = makeMultipartRequest(
            path: "audio/transcriptions",
            fields: fields,
            file: (
                field: "file",
                filename: fileURL.lastPathComponent,
                contentType: Self.audioContentType(for: fileURL),
                data: data
            )
        )
        let (respData, response) = try await self.data(for: request)
        try Self.assertOK(data: respData, response: response)
        guard let obj = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] else {
            throw VeniceError.decode("could not parse transcription response")
        }
        return Self.parseTranscription(obj, language: language)
    }

    private static func audioContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "wav", "wave": return "audio/wav"
        case "flac": return "audio/flac"
        case "m4a", "mp4", "aac": return "audio/mp4"
        case "mp3": return "audio/mpeg"
        case "ogg": return "audio/ogg"
        case "webm": return "audio/webm"
        default: return "application/octet-stream"
        }
    }

    /// Best-effort parse across the model-specific timestamp schemas.
    private static func parseTranscription(_ obj: [String: Any], language: String?) -> TranscriptionResult {
        let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        func time(_ any: Any?) -> Double? {
            if let d = any as? Double { return d }
            if let i = any as? Int { return Double(i) }
            if let n = any as? NSNumber { return n.doubleValue }
            return nil
        }

        var segments: [TranscriptionSegment] = []
        if let rawSegments = obj["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                let segText = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !segText.isEmpty, let start = time(seg["start"]), let end = time(seg["end"]) else { continue }
                segments.append(TranscriptionSegment(text: segText, start: start, end: end))
            }
        }

        var words: [TranscriptionWord] = []
        // Words may be top-level or nested per segment.
        func collectWords(_ raw: [[String: Any]]) {
            for w in raw {
                let t = (w["word"] as? String ?? w["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !t.isEmpty else { continue }
                words.append(TranscriptionWord(text: t, start: time(w["start"]), end: time(w["end"])))
            }
        }
        if let rawWords = obj["words"] as? [[String: Any]] {
            collectWords(rawWords)
        } else if let rawSegments = obj["segments"] as? [[String: Any]] {
            for seg in rawSegments {
                if let segWords = seg["words"] as? [[String: Any]] { collectWords(segWords) }
            }
        }

        // If no segment timing came back, emit one spanning segment so callers
        // (captions/search) still have something to anchor.
        if segments.isEmpty, !text.isEmpty {
            let end = words.compactMap(\.end).max() ?? 0
            segments = [TranscriptionSegment(text: text, start: 0, end: end)]
        }

        return TranscriptionResult(
            text: text,
            language: language,
            words: words,
            segments: segments
        )
    }
}
