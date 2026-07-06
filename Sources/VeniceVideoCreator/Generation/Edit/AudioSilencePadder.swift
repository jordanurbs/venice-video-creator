import AVFoundation

/// Pads an audio file with trailing silence up to a model's minimum `audio_url`
/// duration (e.g. Wan 2.7's 3s floor) using AVFoundation — no ffmpeg. Trailing
/// (not leading) silence keeps the speech at the clip's start where the mouth
/// motion belongs. The source file is never mutated; a padded copy is written to
/// a new temp file.
enum AudioSilencePadder {
    /// A padded temp-file URL when `url` is shorter than `minSeconds`, or nil when
    /// it already qualifies or can't be processed (caller then uploads the original).
    static func padIfShorter(url: URL, minSeconds: Double) async -> URL? {
        guard minSeconds > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0,
              duration.seconds < minSeconds,
              let sourceTrack = try? await asset.loadTracks(withMediaType: .audio).first
        else { return nil }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        do {
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: sourceTrack, at: .zero)
        } catch {
            return nil
        }
        // An empty range past the audio renders as trailing silence on export.
        let target = CMTime(seconds: minSeconds, preferredTimescale: 600)
        track.insertEmptyTimeRange(CMTimeRange(start: duration, end: target))

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("venice-audio-pad-\(UUID().uuidString).m4a")
        do {
            try await export.export(to: outURL, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: outURL)
            return nil
        }
        return outURL
    }
}
