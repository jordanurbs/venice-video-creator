import Foundation
import Testing
@testable import VeniceVideoCreator

/// Global no-overlap dialogue scheduler (harness rules 35/36, anti-pattern 19):
/// every spoken line rides ONE advancing cursor and measured durations re-flow
/// the lane instead of overlapping.
@Suite("DialogueScheduler")
struct DialogueSchedulerTests {

    @Test func singleGlobalCursorNoOverlap() {
        // Two shots both starting at frame 0 (e.g. before video placement is
        // read) must NOT pile lines on top of each other.
        let lines = [
            DialogueScheduler.Line(shotStartFrame: 0, estimatedFrames: 30),
            DialogueScheduler.Line(shotStartFrame: 0, estimatedFrames: 20),
            DialogueScheduler.Line(shotStartFrame: 0, estimatedFrames: 25),
        ]
        let out = DialogueScheduler.schedule(lines: lines, leadFrames: 0, gapFrames: 3)
        #expect(out[0].startFrame == 0)
        #expect(out[1].startFrame == 33)   // 0 + 30 + gap 3
        #expect(out[2].startFrame == 56)   // 33 + 20 + gap 3
        // No two placed spans overlap.
        for i in 1..<out.count {
            #expect(out[i].startFrame >= out[i - 1].startFrame + out[i - 1].estimatedFrames)
        }
    }

    @Test func respectsShotStartWhenAhead() {
        // A later shot placed far ahead keeps its own start, not the cursor.
        let lines = [
            DialogueScheduler.Line(shotStartFrame: 0, estimatedFrames: 30),
            DialogueScheduler.Line(shotStartFrame: 200, estimatedFrames: 30),
        ]
        let out = DialogueScheduler.schedule(lines: lines, leadFrames: 0, gapFrames: 3)
        #expect(out[1].startFrame == 200)
    }

    @Test func reflowRipplesWhenClipRunsLong() {
        // Scheduled starts assumed 30-frame clips; the first actually lands at
        // 90 frames, so the second must slide forward instead of overlapping.
        let desired = [0, 33, 66]
        let measured = [90, 30, 30]
        let out = DialogueScheduler.reflow(desiredStarts: desired, durations: measured, gapFrames: 3)
        #expect(out[0] == 0)
        #expect(out[1] == 93)  // pushed past 0 + 90 + gap
        #expect(out[2] == 126) // 93 + 30 + gap
    }

    @Test func reflowKeepsIntentionalGaps() {
        // When measured durations fit, far-apart shots keep their silence.
        let desired = [0, 300]
        let measured = [30, 30]
        let out = DialogueScheduler.reflow(desiredStarts: desired, durations: measured, gapFrames: 3)
        #expect(out == [0, 300])
    }

    @Test func duckKeyframesDipUnderEachWindow() {
        let kfs = DialogueScheduler.duckKeyframes(
            windows: [10...40, 100...130], baseVolume: 1.0, duckVolume: 0.25,
            rampFrames: 3, clipFrames: 200
        )
        // Starts at full volume, dips inside a window, recovers between.
        #expect(kfs.first?.value == 1.0)
        let atWindow = kfs.first { $0.frame == 10 }
        #expect(atWindow?.value == 0.25)
        let recovered = kfs.first { $0.frame == 43 }  // 40 + ramp
        #expect(recovered?.value == 1.0)
    }

    @Test func duckKeyframesMergeAdjacentWindows() {
        // Overlapping windows collapse to one dip.
        let merged = DialogueScheduler.mergedWindows([0...50, 40...90], padFrames: 0)
        #expect(merged.count == 1)
        #expect(merged[0] == 0...90)
    }

    @Test func closeSpeechWindowsHoldTheDuckAcrossOverlappingRamps() {
        let points = DialogueScheduler.duckKeyframes(windows: [0...60, 63...123], rampFrames: 9, clipFrames: 300)
        #expect(points.filter { $0.frame <= 123 }.allSatisfy { $0.value == 0.25 })
        #expect(points.first { $0.frame == 132 }?.value == 1)
    }

    @Test func speechAtTheCutDoesNotRampUpAcrossTheEntireClip() {
        let points = DialogueScheduler.duckKeyframes(windows: [0...300], rampFrames: 9, clipFrames: 300)
        #expect(points.allSatisfy { $0.value == 0.25 })
        #expect(points.last?.frame == 300)
    }
}
