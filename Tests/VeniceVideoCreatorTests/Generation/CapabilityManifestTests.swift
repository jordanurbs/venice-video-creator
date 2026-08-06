import Foundation
import Testing
@testable import VeniceVideoCreator

/// Decoding + gating tests for the harness capability manifest.
@Suite("CapabilityManifest decoding")
struct CapabilityManifestTests {

    private func manifestJSON(
        schemaVersion: Int = 1,
        extraTopLevel: String = ""
    ) -> Data {
        let json = """
        {
          "schemaVersion": \(schemaVersion),
          "harnessVersion": "2.15.0",
          "generatedAt": "2026-08-06T00:00:00Z",
          \(extraTopLevel)
          "videoModels": [
            {"id": "seedance-2-0-enhanced-reference-to-video", "audioInput": true, "supportsEndImage": false, "supportsReferenceImages": true},
            {"id": "wan-2-7-image-to-video", "audioInput": true, "supportsEndImage": false, "supportsReferenceImages": false, "minAudioInputSec": 3},
            {"id": "kling-2.6-pro-image-to-video", "audioInput": false, "supportsEndImage": true, "supportsReferenceImages": false},
            {"id": "minimax-h3-reference-to-video", "audioInput": true, "supportsEndImage": false, "supportsReferenceImages": true}
          ],
          "capabilitySets": {
            "elements": [],
            "referenceImages": ["seedance-2-0-enhanced-reference-to-video", "minimax-h3-reference-to-video"],
            "sceneImages": [],
            "endImage": ["kling-2.6-pro-image-to-video"],
            "imageTags": ["seedance-2-0-enhanced-reference-to-video", "minimax-h3-reference-to-video"],
            "audioInput": ["seedance-2-0-enhanced-reference-to-video", "wan-2-7-image-to-video", "minimax-h3-reference-to-video"],
            "perReferenceAudio": [],
            "referenceAudio": ["seedance-2-0-enhanced-reference-to-video"]
          },
          "budgets": {
            "maxReferenceImagesByModel": {"seedance-2-0-enhanced-reference-to-video": 9, "minimax-h3-reference-to-video": 9},
            "defaultMaxReferenceImages": 4,
            "videoPromptCharLimit": 2500
          },
          "defaults": {
            "multiShotModel": "seedance-2-0-enhanced-reference-to-video",
            "lipSyncModel": "wan-2-7-image-to-video"
          }
        }
        """
        return Data(json.utf8)
    }

    @Test func decodesSupportedSchema() throws {
        let m = try JSONDecoder().decode(CapabilityManifest.self, from: manifestJSON())
        #expect(m.harnessVersion == "2.15.0")
        #expect(m.videoModels.count == 4)
        #expect(m.capabilitySets.audioInput.contains("seedance-2-0-enhanced-reference-to-video"))
        #expect(m.budgets.maxReferenceImagesByModel["minimax-h3-reference-to-video"] == 9)
        #expect(m.defaults.multiShotModel == "seedance-2-0-enhanced-reference-to-video")
        #expect(m.minAudioInputSeconds(id: "wan-2-7-image-to-video") == 3)
        #expect(m.knownIds.contains("kling-2.6-pro-image-to-video"))
    }

    @Test func rejectsFutureSchemaVersion() {
        // A manifest from a future harness must be rejected, never partially
        // interpreted — mis-reading a shape change could enable a paid
        // capability a model doesn't have.
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(CapabilityManifest.self, from: manifestJSON(schemaVersion: 99))
        }
    }

    @Test func ignoresUnknownFields() throws {
        let data = manifestJSON(extraTopLevel: #""someFutureField": {"nested": true},"#)
        let m = try JSONDecoder().decode(CapabilityManifest.self, from: data)
        #expect(m.videoModels.count == 4)
    }

    @Test func bundledSnapshotDecodesAndCoversKeyModels() throws {
        // The snapshot committed from the harness must parse and carry the
        // families the app routes on. Locate it relative to this source file
        // (tests run from the package, not the app bundle).
        let sourceDir = URL(fileURLWithPath: #filePath)
        let root = sourceDir
            .deletingLastPathComponent()  // Generation/
            .deletingLastPathComponent()  // VeniceVideoCreatorTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // package root
        let snapshot = root.appendingPathComponent("Sources/VeniceVideoCreator/Resources/Capabilities/capabilities.json")
        let data = try Data(contentsOf: snapshot)
        let m = try JSONDecoder().decode(CapabilityManifest.self, from: data)
        #expect(m.schemaVersion == 1)
        #expect(m.videoModels.count > 50)
        for id in [
            "seedance-2-0-enhanced-reference-to-video",
            "minimax-h3-reference-to-video",
            "wan-3-0-reference-to-video",
            "wan-2-7-image-to-video",
        ] {
            #expect(m.knownIds.contains(id), "bundled snapshot missing \(id)")
        }
        // Spot-check probe-verified facts the app depends on.
        #expect(m.capabilitySets.audioInput.contains("seedance-2-0-enhanced-reference-to-video"))
        #expect(m.capabilitySets.imageTags.contains("minimax-h3-reference-to-video"))
        #expect(m.budgets.maxReferenceImagesByModel["seedance-2-0-enhanced-reference-to-video"] == 9)
        #expect(!m.capabilitySets.endImage.contains("wan-2-7-image-to-video"))
    }
}
