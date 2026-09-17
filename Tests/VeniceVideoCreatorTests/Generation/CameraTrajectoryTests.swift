import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Camera trajectory")
struct CameraTrajectoryTests {
    @Test func boundaries() {
        var move = CameraTrajectory.stationary
        #expect(move.validationError == nil)
        move.keyframes[1].azimuth = 11_520
        move.keyframes[1].elevation = -90
        #expect(move.validationError == nil)
        move.keyframes[1].azimuth += 1
        #expect(move.validationError != nil)
        for field in [\CameraTrajectory.Keyframe.time, \.azimuth, \.elevation, \.distance] {
            for invalid in [Double.nan, .infinity, -.infinity] {
                var invalidMove = CameraTrajectory.stationary
                invalidMove.keyframes[0][keyPath: field] = invalid
                #expect(invalidMove.validationError != nil)
            }
        }
        for frames in [[], Array(repeating: move.keyframes[0], count: 1), Array(repeating: move.keyframes[0], count: 13)] {
            #expect(CameraTrajectory(keyframes: frames).validationError != nil)
        }
        move = .stationary
        move.keyframes[1].time = 0
        #expect(move.validationError != nil)
        move = .stationary
        move.keyframes[1].distance = 0
        #expect(move.validationError != nil)
        move = .stationary
        move.keyframes[1].elevation = 90.01
        #expect(move.validationError != nil)
        move = .stationary
        move.keyframes[1].time = 1.01
        #expect(move.validationError != nil)
    }

    @Test func countsAbsoluteTravelNotNetRotation() {
        let move = CameraTrajectory(keyframes: [
            .init(time: 0, azimuth: 0, elevation: 0, distance: 1),
            .init(time: 0.5, azimuth: 6000, elevation: 0, distance: 1),
            .init(time: 1, azimuth: 0, elevation: 0, distance: 1),
        ])
        #expect(move.validationError != nil)
    }

    @Test func advancedMoveRoundTripsWithoutFlattening() throws {
        let move = CameraTrajectory(keyframes: (0..<12).map {
            .init(time: Double($0) / 11, azimuth: Double($0) * 5, elevation: 0, distance: 1)
        })
        #expect(move.validationError == nil)
        let shot = Shot(cameraTrajectory: move)
        let decoded = try JSONDecoder().decode(Shot.self, from: JSONEncoder().encode(shot))
        #expect(decoded.cameraTrajectory == move)
        let input = GenerationInput(prompt: "", model: VideoModelCapabilities.multiAngleID, duration: 5, aspectRatio: "16:9", cameraTrajectory: move)
        #expect(try JSONDecoder().decode(GenerationInput.self, from: JSONEncoder().encode(input)) == input)
        #expect(try JSONDecoder().decode(Shot.self, from: Data("{}".utf8)).cameraTrajectory == nil)
        #expect(CameraTrajectory.validate(move, modelID: "minimax-h3-max-image-to-video") != nil)
        #expect(CameraTrajectory.validate(nil, modelID: VideoModelCapabilities.multiAngleID) != nil)
    }

    @Test func automaticResolutionIsNotMaximum() {
        let id = VideoModelCapabilities.multiAngleID
        #expect(VideoModelCapabilities.automaticResolution(id: id, allowed: ["1080P", "768P", "480P"]) == "768P")
        #expect(VideoModelCapabilities.preferredResolutionOrder(id: id, live: ["1080P", "768P", "480P"]) == ["768P", "480P", "1080P"])
        #expect(!VideoModelCapabilities.supportsCameraTrajectory(id: "unknown-multi-angle"))
    }
}

@Suite("Camera manifest compatibility")
struct CameraManifestCompatibilityTests {
    @Test func schemaOneOptionalFieldDefaultsOff() throws {
        let old = try JSONDecoder().decode(CapabilityManifest.VideoModelSpec.self, from: Data(#"{"id":"legacy"}"#.utf8))
        #expect(!old.supportsCameraTrajectory)
        let current = try JSONDecoder().decode(CapabilityManifest.VideoModelSpec.self, from: Data(#"{"id":"minimax-h3-max-multi-angle","supportsCameraTrajectory":true}"#.utf8))
        #expect(current.supportsCameraTrajectory)
    }

    @Test func multiAngleDoesNotInventTextFromSummary() {
        let shot = Shot(summary: "Orbit the subject", cameraTrajectory: .stationary)
        #expect(ShotPromptBuilder.videoPrompt(for: shot, model: VideoModelCapabilities.multiAngleID).isEmpty)
    }
}
