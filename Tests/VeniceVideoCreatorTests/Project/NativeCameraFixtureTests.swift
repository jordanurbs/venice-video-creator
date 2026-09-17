import AppKit
import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Native camera acceptance fixture")
@MainActor
struct NativeCameraFixtureTests {
    private func writeFixture(to url: URL) throws {
        let move = CameraTrajectory(keyframes: [
            .init(time: 0, azimuth: 10, elevation: 5, distance: 1),
            .init(time: 0.5, azimuth: 45, elevation: 15, distance: 0.8),
            .init(time: 1, azimuth: 90, elevation: 20, distance: 1.2),
        ])
        var manifest = MediaManifest()
        manifest.entries = [.init(id: "native-panel", name: "Camera fixture panel", type: .image,
                                  source: .project(relativePath: "media/panel.png"), duration: 5,
                                  sourceWidth: 640, sourceHeight: 360)]
        manifest.shotPlan = ShotPlan(title: "Native Camera Acceptance", resolution: "768P", defaultModel: VideoModelCapabilities.multiAngleID, shots: [
            Shot(id: "native-camera", slug: "Camera endpoints", summary: "Inspect all six camera endpoints. Preserve the middle keyframe.", cameraTrajectory: move, status: .storyboarded, storyboardAssetId: "native-panel")
        ])
        let timeline = Fixtures.timeline(tracks: [Fixtures.videoTrack(clips: [Fixtures.clip(mediaRef: "native-panel", mediaType: .image, start: 0, duration: 150)])])
        try VideoProject.writeProjectPackage(.init(
            timeline: JSONEncoder().encode(timeline), manifest: JSONEncoder().encode(manifest),
            generationLog: nil, thumbnail: nil, chatSessionFiles: []
        ), to: url, sourceURL: nil)
        let media = url.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let context = try #require(CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 640 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.15, green: 0.3, blue: 0.65, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 1, green: 0.65, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 270, y: 130, width: 100, height: 100))
        let image = try #require(context.makeImage())
        let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try png.write(to: media.appendingPathComponent("panel.png"))
    }

    @Test func cameraSurvivesActualPackageWriteRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("camera-package-\(UUID()).venice")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(to: url)
        let package = try VideoProject.readProjectPackage(at: url)
        #expect(!package.manifestUnreadable)
        #expect(package.manifest?.shotPlan?.shots[0].cameraTrajectory?.keyframes.count == 3)
        #expect(package.manifest?.shotPlan?.shots[0].cameraTrajectory?.keyframes[1].azimuth == 45)
        #expect(NSImage(contentsOf: url.appendingPathComponent("media/panel.png")) != nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["VENICE_NATIVE_FIXTURE_PATH"] != nil))
    func writeRetainedNativeFixture() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VENICE_NATIVE_FIXTURE_PATH"])
        guard !FileManager.default.fileExists(atPath: path) else { throw ToolError("Native fixture destination already exists.") }
        try writeFixture(to: URL(fileURLWithPath: path, isDirectory: true))
    }
}
