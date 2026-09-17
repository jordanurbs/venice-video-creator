import Foundation
import Testing
@testable import VeniceVideoCreator

@Suite("Harness project import — scan")
struct HarnessProjectImporterTests {

    /// Build a minimal harness project on disk: series.json, one episode
    /// script, one rendered shot with panel + clip + video sidecar.
    private func makeFixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-fixture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let episodeDir = root.appendingPathComponent("episodes/episode-001/scene-001", isDirectory: true)
        try FileManager.default.createDirectory(at: episodeDir, withIntermediateDirectories: true)

        let series: [String: Any] = [
            "name": "Fixture Run",
            "slug": "fixture-run",
            "concept": "A test concept",
            "aesthetic": ["style": "Test style block", "palette": "amber"],
            "characters": [["name": "WREN", "description": "A courier"]],
            "locations": [["name": "Skybridge", "slug": "skybridge", "description": "A bridge"]],
            "episodes": [["number": 1, "title": "Pilot", "status": "scripted"]],
        ]
        let script: [String: Any] = [
            "episode": 1,
            "title": "Pilot",
            "totalDuration": "20s",
            "shots": [
                [
                    "shotNumber": 1,
                    "type": "establishing",
                    "duration": "12s",
                    "description": "Wide vista",
                    "panelDescription": "Static wide",
                    "characters": [],
                    "location": "skybridge",
                    "transition": "cut",
                ],
                [
                    "shotNumber": 2,
                    "type": "dialogue",
                    "duration": "8s",
                    "description": "Wren speaks",
                    "characters": ["WREN"],
                    "dialogue": ["character": "WREN", "line": "Let's go."],
                ],
            ],
        ]
        try JSONSerialization.data(withJSONObject: series)
            .write(to: root.appendingPathComponent("series.json"))
        try JSONSerialization.data(withJSONObject: script)
            .write(to: root.appendingPathComponent("episodes/episode-001/script.json"))

        // Shot 1 has a rendered panel + clip + sidecar; shot 2 has nothing.
        let sceneDir = root.appendingPathComponent("episodes/episode-001/scene-001", isDirectory: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: sceneDir.appendingPathComponent("shot-001.png"))
        try Data([0x00, 0x00, 0x00, 0x18]).write(to: sceneDir.appendingPathComponent("shot-001.mp4"))
        let sidecar: [String: Any] = ["video": ["model": "seedance-2-5", "prompt": "SHOT: wide"]]
        try JSONSerialization.data(withJSONObject: sidecar)
            .write(to: sceneDir.appendingPathComponent("shot-001.video.json"))

        return root
    }

    @Test func scansSeriesScriptAndMedia() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let scan = try HarnessProjectImporter.scan(projectURL: root)

        #expect(scan.seriesName == "Fixture Run")
        #expect(scan.episode == 1)
        #expect(scan.episodeTitle == "Pilot")
        #expect(scan.styleBlock == "Test style block")
        #expect(scan.shots.count == 2)

        let first = try #require(scan.shots.first)
        #expect(first.key == "001")
        #expect(first.durationSeconds == 12)
        #expect(first.locationSlug == "skybridge")
        #expect(first.clipPath != nil)
        #expect(first.panelPath != nil)
        #expect(first.renderModel == "seedance-2-5")

        let second = try #require(scan.shots.last)
        #expect(second.key == "002")
        #expect(second.clipPath == nil)
        #expect(second.dialogue.count == 1)
        #expect(second.dialogue[0].speaker == "WREN")
        #expect(second.characterNames == ["WREN"])

        #expect(scan.characters.count == 1)
        #expect(scan.locations.count == 1)
        #expect(scan.finalCutPath == nil)
    }

    @Test func preservesAdvancedCameraSidecar() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let frames: [[String: Any]] = [
            ["time": 0, "azimuth": 0, "elevation": 0, "distance": 1],
            ["time": 0.5, "azimuth": 30, "elevation": 5, "distance": 0.8],
            ["time": 1, "azimuth": 90, "elevation": 0, "distance": 1],
        ]
        let sidecar: [String: Any] = ["video": ["model": VideoModelCapabilities.multiAngleID, "camera_trajectory": frames]]
        try JSONSerialization.data(withJSONObject: sidecar).write(to: root.appendingPathComponent("episodes/episode-001/scene-001/shot-001.video.json"))
        let shot = try #require(HarnessProjectImporter.scan(projectURL: root).shots.first)
        #expect(shot.cameraTrajectory?.keyframes.count == 3)
        #expect(shot.cameraTrajectory?.keyframes[1].azimuth == 30)
        #expect(shot.cameraTrajectory?.validationError == nil)
    }

    @Test func rejectsNonHarnessFolder() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-harness-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        #expect(throws: HarnessProjectImporter.ImportError.self) {
            _ = try HarnessProjectImporter.scan(projectURL: empty)
        }
    }

    @Test func shotPlanRoundTripsHarnessSourceFields() throws {
        var plan = ShotPlan(title: "T")
        plan.harnessSourcePath = "/tmp/fixture-run"
        plan.harnessEpisode = 3
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(ShotPlan.self, from: data)
        #expect(decoded.harnessSourcePath == "/tmp/fixture-run")
        #expect(decoded.harnessEpisode == 3)
    }
}
