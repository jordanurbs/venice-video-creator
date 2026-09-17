import Foundation

/// Places a production's spoken lines onto a single dialogue lane with a global
/// no-overlap cursor, and reconciles that lane once real clip durations land
/// (harness rules 35/36, anti-pattern 19). The harness learned the hard way that
/// scheduling every line against ONE advancing cursor — never per-shot,
/// never from a planned estimate that is never corrected — is what keeps
/// narrator and character lines from piling onto the same frames.
///
/// Pure and Sendable so the placement math is unit-testable without an editor.
enum DialogueScheduler {

    /// One spoken line to place: its shot's timeline start (frames) and a rough
    /// spoken length (frames) used until the generated clip's real length lands.
    struct Line: Equatable, Sendable {
        var shotStartFrame: Int
        var estimatedFrames: Int
    }

    struct Placement: Equatable, Sendable {
        var startFrame: Int
        var estimatedFrames: Int
    }

    /// Schedules every line against ONE advancing cursor: a line begins no earlier
    /// than its shot's start (+`leadFrames`) and never before the previous line
    /// ends (+`gapFrames`). Lines are placed in the order given (plan/dialogue
    /// order), so narrator and character lines interleave without overlapping.
    static func schedule(lines: [Line], leadFrames: Int, gapFrames: Int) -> [Placement] {
        var out: [Placement] = []
        out.reserveCapacity(lines.count)
        var nextFree: Int? = nil
        for line in lines {
            let earliest = line.shotStartFrame + leadFrames
            let start = nextFree.map { max(earliest, $0) } ?? earliest
            out.append(Placement(startFrame: max(0, start), estimatedFrames: max(1, line.estimatedFrames)))
            nextFree = max(0, start) + max(1, line.estimatedFrames) + gapFrames
        }
        return out
    }

    /// Re-flows an ordered lane once measured durations are known so no two clips
    /// overlap. Each clip keeps its scheduled `desiredStart` unless the previous
    /// (now-measured) clip runs into it, in which case it slides forward by
    /// `gapFrames`. Order is preserved; earlier gaps (intentional silence between
    /// far-apart shots) survive.
    static func reflow(desiredStarts: [Int], durations: [Int], gapFrames: Int) -> [Int] {
        var out: [Int] = []
        out.reserveCapacity(desiredStarts.count)
        var prevEnd: Int? = nil
        for (desired, dur) in zip(desiredStarts, durations) {
            let start: Int
            if let prevEnd { start = max(desired, prevEnd + gapFrames) } else { start = desired }
            out.append(start)
            prevEnd = start + max(1, dur)
        }
        return out
    }

    /// Merges overlapping/adjacent windows (each padded by `padFrames`) into a
    /// sorted, disjoint set. Used to build a music/ambient bed's duck envelope.
    static func mergedWindows(_ windows: [ClosedRange<Int>], padFrames: Int) -> [ClosedRange<Int>] {
        let padded = windows
            .map { max(0, $0.lowerBound - padFrames)...($0.upperBound + padFrames) }
            .sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Int>] = []
        for w in padded {
            if let last = out.last, w.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, w.upperBound)
            } else {
                out.append(w)
            }
        }
        return out
    }

    /// A volume keyframe (clip-relative frame + level) for a music/ambient bed:
    /// full level at the head, dipping to `duckVolume` across every dialogue
    /// window with short `rampFrames` ramps in and out (harness auto-duck).
    /// Frames are clamped to `0...clipFrames`.
    static func duckKeyframes(
        windows: [ClosedRange<Int>],
        baseVolume: Double = 1.0,
        duckVolume: Double = 0.25,
        rampFrames: Int,
        clipFrames: Int
    ) -> [(frame: Int, value: Double)] {
        let windows = mergedWindows(windows, padFrames: 0).filter { $0.upperBound >= 0 && $0.lowerBound <= clipFrames }
        var merged: [ClosedRange<Int>] = []
        // Overlapping ramps must not raise the bed during the next spoken line.
        for window in windows {
            if let last = merged.last, window.lowerBound - last.upperBound <= max(0, rampFrames) * 2 {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, window.upperBound)
            } else { merged.append(window) }
        }
        guard !merged.isEmpty, clipFrames > 0 else { return [] }
        var points: [(frame: Int, value: Double)] = [(0, baseVolume)]
        func add(_ frame: Int, _ value: Double) {
            let f = Swift.min(clipFrames, Swift.max(0, frame))
            points.append((f, value))
        }
        for w in merged {
            add(w.lowerBound - rampFrames, baseVolume)
            add(w.lowerBound, duckVolume)
            add(w.upperBound, duckVolume)
            if w.upperBound < clipFrames { add(w.upperBound + rampFrames, baseVolume) }
        }
        if merged.last!.upperBound < clipFrames { add(clipFrames, baseVolume) }
        // Collapse to one point per frame, keeping the last write (later windows win).
        var byFrame: [Int: Double] = [:]
        var order: [Int] = []
        for p in points.sorted(by: { $0.frame < $1.frame }) {
            if byFrame[p.frame] == nil { order.append(p.frame) }
            byFrame[p.frame] = p.value
        }
        return order.map { ($0, byFrame[$0]!) }
    }
}
