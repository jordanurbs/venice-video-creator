import Foundation

enum MiniMaxVideoContract {
    static let lanes: Set<String> = [
        "minimax-h3-max-text-to-video", "minimax-h3-max-image-to-video",
        "minimax-h3-max-reference-to-video", "minimax-h3-max-turbo-text-to-video",
        "minimax-h3-max-turbo-image-to-video", VideoModelCapabilities.multiAngleID,
    ]

    static func inheritsAspect(_ model: String) -> Bool {
        lanes.contains(model) && (model.contains("image-to-video") || model == VideoModelCapabilities.multiAngleID)
    }

    static func validate(model: String, params: VideoGenerationParams) throws {
        guard lanes.contains(model) else { return }
        guard (5...15).contains(params.duration) else { throw ToolError("MiniMax H3 Max requires an integer duration from 5 to 15 seconds.") }
        let resolutions = model == VideoModelCapabilities.multiAngleID ? ["1080P", "768P", "480P"] : ["768P", "480P"]
        if let resolution = params.resolution, !resolutions.contains(resolution) {
            throw ToolError("Model '\(model)' supports \(resolutions.joined(separator: ", ")), not '\(resolution)'.")
        }
        guard params.endFrameURL == nil, params.sourceVideoURL == nil, params.referenceVideoURLs.isEmpty else {
            throw ToolError("MiniMax H3 Max does not accept an end frame or video input.")
        }
        if inheritsAspect(model) {
            guard params.startFrameURL != nil else { throw ToolError("Model '\(model)' requires a starting image.") }
            guard params.referenceImageURLs.isEmpty, params.referenceAudioURLs.isEmpty else {
                throw ToolError("Model '\(model)' accepts a starting image, not reference images or audio.")
            }
        } else if model == "minimax-h3-max-reference-to-video" {
            guard params.startFrameURL == nil, (1...9).contains(params.referenceImageURLs.count), params.referenceAudioURLs.count <= 1 else {
                throw ToolError("Max R2V requires 1–9 reference images, at most one audio reference, and no starting frame.")
            }
        } else {
            guard params.startFrameURL == nil, !params.hasAnyReferences else {
                throw ToolError("Model '\(model)' accepts text only. Select an image- or reference-to-video lane for image input.")
            }
        }
        if model != VideoModelCapabilities.multiAngleID, params.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolError("Enter a video prompt.")
        }
    }
}
