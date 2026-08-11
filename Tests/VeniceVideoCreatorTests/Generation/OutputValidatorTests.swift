import Foundation
import Testing
@testable import VeniceVideoCreator

/// Post-render output validation (harness validate-video-outputs): reject the two
/// known failure modes — portrait-when-landscape-requested and truncated files —
/// so they hit the retry path instead of landing on the timeline.
@Suite("OutputValidator")
struct OutputValidatorTests {

    @Test func landscapeOutputPassesForLandscapePlan() {
        let r = OutputValidator.validate(
            displayWidth: 1920, displayHeight: 1080,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "16:9"
        )
        #expect(r.ok)
    }

    @Test func portraitOutputFailsForLandscapePlan() {
        let r = OutputValidator.validate(
            displayWidth: 1080, displayHeight: 1920,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "16:9"
        )
        #expect(!r.ok)
        #expect(r.reason?.contains("portrait") == true)
    }

    @Test func portraitPlanAcceptsPortraitOutput() {
        let r = OutputValidator.validate(
            displayWidth: 1080, displayHeight: 1920,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "9:16"
        )
        #expect(r.ok)
    }

    @Test func truncatedFileFails() {
        let r = OutputValidator.validate(
            displayWidth: 1920, displayHeight: 1080,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 4_096, targetAspectRatio: "16:9"
        )
        #expect(!r.ok)
        #expect(r.reason?.contains("truncated") == true)
    }

    @Test func shortDurationFailsUnderEightyPercent() {
        let r = OutputValidator.validate(
            displayWidth: 1920, displayHeight: 1080,
            durationSeconds: 3.5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "16:9"
        )
        #expect(!r.ok)
        // 4.0s (80% of 5) is the floor; 3.5s is under.
        #expect(r.reason?.contains("under 80%") == true)
    }

    @Test func durationAtEightyPercentPasses() {
        let r = OutputValidator.validate(
            displayWidth: 1920, displayHeight: 1080,
            durationSeconds: 4.0, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "16:9"
        )
        #expect(r.ok)
    }

    @Test func squareOutputToleratedForSquarePlan() {
        let square = OutputValidator.validate(
            displayWidth: 1024, displayHeight: 1024,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "1:1"
        )
        #expect(square.ok)
        // But a square output when 16:9 was asked is a mismatch.
        let mismatch = OutputValidator.validate(
            displayWidth: 1024, displayHeight: 1024,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "16:9"
        )
        #expect(!mismatch.ok)
    }

    @Test func unparseableAspectSkipsOrientationCheck() {
        let r = OutputValidator.validate(
            displayWidth: 1080, displayHeight: 1920,
            durationSeconds: 5, requestedDurationSeconds: 5,
            fileSizeBytes: 2_000_000, targetAspectRatio: "auto"
        )
        #expect(r.ok)
    }
}
