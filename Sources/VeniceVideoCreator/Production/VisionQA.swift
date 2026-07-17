import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Two-pass storyboard/video QA (ported from the harness): sends panel/frame images plus a
/// rubric to a vision-capable Venice chat model and parses a structured verdict. Kept off the
/// generation path so it can be reused by `qa_shot` and (later) the orchestrator's auto-QA.
enum VisionQA {
    struct Result: Sendable, Equatable {
        var score: Double        // 0…1
        var pass: Bool
        var issues: [String]
        var summary: String
    }

    enum QAError: LocalizedError {
        case noVisionModel
        case noImages
        case emptyResponse
        var errorDescription: String? {
            switch self {
            case .noVisionModel: return "No vision-capable Venice model is available. Enable one in Settings → Models."
            case .noImages: return "Nothing to review — the storyboard panel or video isn't ready yet."
            case .emptyResponse: return "The QA model returned an empty response."
            }
        }
    }

    /// Runs the rubric against `images` (JPEG data) and returns a parsed verdict.
    static func evaluate(
        images: [Data],
        rubric: String,
        api: VeniceAPI,
        model: String
    ) async throws -> Result {
        guard !images.isEmpty else { throw QAError.noImages }

        var content: [[String: Any]] = [["type": "text", "text": rubric]]
        for data in images {
            content.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(data.base64EncodedString())"],
            ])
        }
        let body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "max_tokens": 700,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": content],
            ],
            "venice_parameters": ["include_venice_system_prompt": false],
        ]
        let obj = try await api.postJSON(path: "chat/completions", body: body)
        guard let text = Self.firstMessageText(obj), !text.isEmpty else {
            throw QAError.emptyResponse
        }
        return Self.parse(text)
    }

    // MARK: - Model selection

    /// Prefers the user's agent model when it supports vision, else the first enabled
    /// vision-capable text model.
    @MainActor
    static func selectModel() -> String? {
        let vision = ModelCatalog.shared.textModels.filter { $0.supportsVision }
        if let agentId = ModelPreferences.shared.agentModelId,
           vision.contains(where: { $0.id == agentId }) {
            return agentId
        }
        return vision.first?.id
    }

    // MARK: - Frame extraction

    /// Samples up to `count` frames evenly across a video, downscaled to `maxEdge`, as JPEG.
    static func videoFrames(url: URL, count: Int = 3, maxEdge: CGFloat = 768) async -> [Data] {
        let asset = AVURLAsset(url: url)
        guard let durationTime = try? await asset.load(.duration) else { return [] }
        let duration = durationTime.seconds
        guard duration > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let n = max(1, count)
        // Even samples avoiding exact 0 and end.
        let times: [CMTime] = (0..<n).map { i in
            let frac = (Double(i) + 0.5) / Double(n)
            return CMTime(seconds: duration * frac, preferredTimescale: 600)
        }
        var out: [Data] = []
        for await result in generator.images(for: times) {
            guard case .success(_, let image, _) = result else { continue }
            if let data = jpeg(from: image) { out.append(data) }
        }
        return out
    }

    /// Loads an image file downscaled to `maxEdge` as JPEG.
    static func imageJPEG(url: URL, maxEdge: CGFloat = 768) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else { return nil }
        return jpeg(from: cg)
    }

    static func jpeg(from image: CGImage, quality: CGFloat = 0.7) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Prompt + parsing

    private static let systemPrompt = """
    You are a strict film QA reviewer. You are given one or more frames (a storyboard panel \
    and/or frames sampled from a generated shot) plus the director's intent. Judge how well the \
    image(s) satisfy the intent: subject and action present and correct, framing/composition, \
    character consistency (if characters are named), visible artifacts or deformities, text \
    legibility, and overall usability for a finished video.

    Respond with ONLY a JSON object, no prose, in exactly this shape:
    {"score": 0.0-1.0, "pass": true|false, "issues": ["short issue", ...], "summary": "one or two sentences"}
    Set pass=false when the shot has a blocking problem (wrong subject/action, bad artifacts, \
    off-model character). Keep issues concrete and actionable for a re-generation or edit.
    """

    private static func firstMessageText(_ obj: [String: Any]) -> String? {
        guard let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any] else { return nil }
        if let text = message["content"] as? String { return text }
        // Some responses shape content as an array of parts.
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        return nil
    }

    /// Extracts the JSON verdict from a possibly-noisy model response.
    private static func parse(_ text: String) -> Result {
        let json = extractJSONObject(text) ?? [:]
        let score = (json["score"] as? Double)
            ?? (json["score"] as? NSNumber)?.doubleValue
            ?? (json["score"] as? Int).map(Double.init)
            ?? 0
        let pass = (json["pass"] as? Bool) ?? (score >= 0.7)
        let issues = (json["issues"] as? [Any])?.compactMap { $0 as? String } ?? []
        let summary = (json["summary"] as? String)
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(score: max(0, min(1, score)), pass: pass, issues: issues, summary: summary)
    }

    private static func extractJSONObject(_ text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(text[start...end])
        guard let data = slice.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}
