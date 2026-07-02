import AVFoundation
import AppKit

/// Grabs a single decoded frame from a video file as PNG data, used to turn a
/// clip's final frame into a still that can seed image-to-video generation.
enum LastFrameExtractor {
    static func pngData(url: URL, atSeconds: Double) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard (try? await asset.loadTracks(withMediaType: .video).first) != nil else { return nil }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // The last frame can sit slightly past the requested time; allow a small
        // tolerance so the generator returns the nearest decodable frame.
        let tolerance = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        var seconds = max(0, atSeconds)
        if let duration = try? await asset.load(.duration), duration.seconds > 0 {
            seconds = min(seconds, max(0, duration.seconds - 0.05))
        }
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}
