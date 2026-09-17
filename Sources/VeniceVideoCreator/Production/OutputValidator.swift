import AVFoundation
import CoreGraphics
import Foundation

/// Post-render sanity checks on a downloaded video output (harness
/// `validate-video-outputs`, anti-patterns 5/10). The queue can report success
/// for a file that is unusable: a reference-to-video model may return PORTRAIT
/// when the aspect ratio was dropped, and a truncated/tiny file decodes as a
/// valid-but-empty asset. Catching this here lets the orchestrator treat the
/// take as a failed attempt and hit its existing retry path instead of placing a
/// broken clip on the timeline.
enum OutputValidator {
    struct Result: Equatable {
        let ok: Bool
        let reason: String?
        static let pass = Result(ok: true, reason: nil)
        static func fail(_ reason: String) -> Result { Result(ok: false, reason: reason) }
    }

    enum Orientation: String { case landscape, portrait, square }

    /// Classify a width/height ratio. A near-1 ratio is square (some models emit
    /// 1:1); the tolerance keeps a 1024×1024 output from reading as "landscape".
    static func orientation(width: Double, height: Double, tolerance: Double = 0.05) -> Orientation {
        guard width > 0, height > 0 else { return .square }
        let ratio = width / height
        if abs(ratio - 1) <= tolerance { return .square }
        return ratio > 1 ? .landscape : .portrait
    }

    /// The orientation an `"W:H"` aspect string implies, or nil when unparseable.
    static func expectedOrientation(aspectRatio: String) -> Orientation? {
        let parts = aspectRatio.split(separator: ":")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else {
            return nil
        }
        return orientation(width: w, height: h)
    }

    /// Pure validation over measured facts (testable without a real file).
    /// - Parameters:
    ///   - displayWidth/Height: the track's natural size AFTER its preferred
    ///     transform (so a rotated portrait file reads as portrait).
    ///   - durationFloorFraction: minimum share of the requested duration the
    ///     output must reach (0.8 = 80%, per the handoff).
    static func validate(
        displayWidth: Double,
        displayHeight: Double,
        durationSeconds: Double,
        requestedDurationSeconds: Double,
        fileSizeBytes: Int64,
        targetAspectRatio: String,
        minFileSizeBytes: Int64 = 10_000,
        durationFloorFraction: Double = 0.8
    ) -> Result {
        guard displayWidth.isFinite, displayHeight.isFinite, durationSeconds.isFinite, durationSeconds > 0 else {
            return .fail("output has invalid decoded dimensions or duration")
        }
        if fileSizeBytes < minFileSizeBytes {
            return .fail("output file is only \(fileSizeBytes) bytes — likely truncated or empty")
        }
        guard displayWidth > 0, displayHeight > 0 else {
            return .fail("output has no decodable video track")
        }
        if let expected = expectedOrientation(aspectRatio: targetAspectRatio) {
            let actual = orientation(width: displayWidth, height: displayHeight)
            // A square output is tolerated only when the plan itself asked square.
            if actual != expected {
                return .fail("output is \(actual.rawValue) but the plan requested \(targetAspectRatio) (\(expected.rawValue))")
            }
        }
        if requestedDurationSeconds > 0,
           durationSeconds < requestedDurationSeconds * durationFloorFraction {
            return .fail(String(
                format: "output is %.1fs, under 80%% of the requested %.0fs",
                durationSeconds, requestedDurationSeconds
            ))
        }
        return .pass
    }

    static func validate(
        url: URL,
        requestedDurationSeconds: Double,
        targetAspectRatio: String
    ) async -> Result {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize < 10_000 {
            return .fail("output file is only \(fileSize) bytes — likely truncated or empty")
        }

        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return .fail("no video track in the downloaded output")
        }
        guard let naturalSize = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration) else {
            return .fail("could not decode video properties — retry validation before placement")
        }
        let rect = CGRect(origin: .zero, size: naturalSize).applying(transform)
        return validate(
            displayWidth: abs(rect.width),
            displayHeight: abs(rect.height),
            durationSeconds: duration.seconds,
            requestedDurationSeconds: requestedDurationSeconds,
            fileSizeBytes: fileSize,
            targetAspectRatio: targetAspectRatio
        )
    }
}
