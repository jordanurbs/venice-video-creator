import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("MiniMax request contracts")
@MainActor
struct MiniMaxRequestTests {
    static func model(_ id: String) throws -> VideoModelConfig {
        let inherits = MiniMaxVideoContract.inheritsAspect(id)
        let catalog = VeniceModelMapper.map([[
            "id": id, "type": "video", "model_spec": [
                "constraints": [
                    "model_type": inherits ? "image-to-video" : "text-to-video",
                    "durations": (5...15).map { "\($0)s" },
                    "resolutions": id == VideoModelCapabilities.multiAngleID ? ["1080P", "768P", "480P"] : ["480P", "768P"],
                    "aspect_ratios": inherits ? [] : ["16:9", "9:16", "1:1"],
                ],
            ],
        ]])
        let entry = try #require(catalog.entries.first)
        guard case .video(let caps) = entry.uiCapabilities else { throw ToolError("Missing video capabilities") }
        return VideoModelConfig(entry: entry, caps: caps)
    }

    @Test func allSixBodiesUseExactLaneFields() throws {
        for id in MiniMaxVideoContract.lanes.sorted() {
            let model = try Self.model(id)
            let i2v = MiniMaxVideoContract.inheritsAspect(id)
            let r2v = id.contains("reference-to-video")
            let multi = id == VideoModelCapabilities.multiAngleID
            let params = VideoGenerationParams(
                prompt: multi ? "" : "A car passes through a canyon.", duration: 5,
                aspectRatio: "16:9", resolution: model.automaticResolution,
                startFrameURL: i2v ? "fixture-start" : nil,
                referenceImageURLs: r2v ? (1...9).map { "fixture-ref-\($0)" } : [],
                referenceAudioURLs: r2v ? ["fixture-audio"] : [],
                cameraTrajectory: multi ? .stationary : nil
            )
            let body = try VeniceGenerationRunner.videoRequestBody(model: id, params: params, catalogModel: model)
            #expect(JSONSerialization.isValidJSONObject(body))
            #expect(body["model"] as? String == id)
            #expect(body["resolution"] as? String == "768P")
            #expect(body["duration"] as? String == "5s")
            #expect((body["image_url"] != nil) == i2v)
            #expect((body["reference_image_urls"] != nil) == r2v)
            #expect((body["audio_url"] != nil) == r2v)
            #expect((body["aspect_ratio"] == nil) == i2v)
            #expect((body["camera_trajectory"] != nil) == multi)
            #expect((body["prompt"] == nil) == multi)
            #expect(body["audio"] == nil)
            #expect(body["end_image_url"] == nil)
            if multi {
                let frames = try #require(body["camera_trajectory"] as? [[String: Any]])
                #expect(frames.count == 2)
                #expect(frames[0]["time"] as? Double == 0)
                #expect(frames[1]["time"] as? Double == 1)
            }
        }
    }

    @Test func invalidInputsFailBeforeQueue() throws {
        let id = VideoModelCapabilities.multiAngleID
        let model = try Self.model(id)
        let missingImage = VideoGenerationParams(prompt: "", duration: 5, aspectRatio: "16:9", resolution: "768P", cameraTrajectory: .stationary)
        #expect(throws: ToolError.self) {
            try VeniceGenerationRunner.videoRequestBody(model: id, params: missingImage, catalogModel: model)
        }
        let unsupported = VideoGenerationParams(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "768P", cameraTrajectory: .stationary)
        #expect(throws: ToolError.self) {
            try VeniceGenerationRunner.videoRequestBody(model: "minimax-h3-max-text-to-video", params: unsupported, catalogModel: nil)
        }
        let endImage = VideoGenerationParams(prompt: "", duration: 5, aspectRatio: "16:9", resolution: "768P", startFrameURL: "start", endFrameURL: "end", cameraTrajectory: .stationary)
        #expect(throws: ToolError.self) {
            try VeniceGenerationRunner.videoRequestBody(model: id, params: endImage, catalogModel: model)
        }
        #expect(model.validate(duration: 5, aspectRatio: "16:9", resolution: "1080P") == nil)
        #expect(model.validate(duration: 4, aspectRatio: "16:9", resolution: "768P") != nil)
        #expect(model.validate(duration: 16, aspectRatio: "16:9", resolution: "768P") != nil)
    }

    @Test func strictMiniMaxCombinationsAreRejected() {
        let t2v = "minimax-h3-max-text-to-video"
        let r2v = "minimax-h3-max-reference-to-video"
        let cases: [(String, VideoGenerationParams)] = [
            (t2v, .init(prompt: "A car passes.", duration: 4, aspectRatio: "16:9", resolution: "768P")),
            (t2v, .init(prompt: "A car passes.", duration: 16, aspectRatio: "16:9", resolution: "768P")),
            (t2v, .init(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "1080P")),
            (t2v, .init(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "768P", startFrameURL: "image")),
            (r2v, .init(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "768P")),
            (r2v, .init(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "768P", referenceImageURLs: Array(repeating: "image", count: 10))),
            (r2v, .init(prompt: "A car passes.", duration: 5, aspectRatio: "16:9", resolution: "768P", referenceImageURLs: ["image"], referenceAudioURLs: ["a", "b"])),
        ]
        for (id, params) in cases {
            #expect(throws: ToolError.self) {
                try VeniceGenerationRunner.videoRequestBody(model: id, params: params, catalogModel: nil)
            }
        }
    }

    @Test func modelMetadataEncodesOptionalResolution() throws {
        let model = try Self.model(VideoModelCapabilities.multiAngleID)
        let info = ToolExecutor.videoModelInfo(model)
        #expect(JSONSerialization.isValidJSONObject(info))
        #expect(info["automaticResolution"] as? String == "768P")
        #expect(info["supportsCameraTrajectory"] as? Bool == true)
        let catalog = VeniceModelMapper.map([["id": "fixture-no-resolution", "type": "video"]])
        let entry = try #require(catalog.entries.first)
        guard case .video(let caps) = entry.uiCapabilities else { throw ToolError("Missing video capabilities") }
        let noResolution = ToolExecutor.videoModelInfo(VideoModelConfig(entry: entry, caps: caps))
        #expect(JSONSerialization.isValidJSONObject(noResolution))
        #expect(noResolution["automaticResolution"] is NSNull)
    }

    @Test func submissionPreservesCameraRecipeAndBackendParameters() throws {
        let id = VideoModelCapabilities.multiAngleID
        let model = try Self.model(id)
        let input = GenerationInput(prompt: "", model: id, duration: 5, aspectRatio: "16:9", resolution: "768P", cameraTrajectory: .stationary)
        let frame = MediaAsset(url: URL(fileURLWithPath: "/tmp/fixture.png"), type: .image, name: "Frame")
        let submission = VideoGenerationSubmission.make(genInput: input, model: model, inputAssets: .init(frames: [frame]), placeholderDuration: 5, generateAudio: true)
        #expect(submission.genInput.cameraTrajectory == .stationary)
        guard case .video(let params) = submission.buildParams(["uploaded-frame"]) else {
            Issue.record("Expected video parameters")
            return
        }
        #expect(params.cameraTrajectory == .stationary)
        #expect(params.startFrameURL == "uploaded-frame")
        #expect(params.aspectRatio == "16:9")
    }
}
