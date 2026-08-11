import AVFoundation
import Observation

/// Lightweight one-at-a-time audio player for inspector rows (character voice
/// samples, audition takes). Playing a new asset stops the previous one; the
/// row that started playback observes `playingAssetId` for its play/stop icon.
///
/// Deliberately separate from `VideoEngine`: routing inspector clicks into the
/// preview player loaded an mp3 into a black video canvas with no feedback —
/// samples should just play on click, where the user clicked.
@Observable
@MainActor
final class InspectorAudioPlayer {
    static let shared = InspectorAudioPlayer()

    private(set) var playingAssetId: String?
    private let player = AVPlayer()
    private var endObserver: NSObjectProtocol?

    private init() {}

    func isPlaying(_ assetId: String) -> Bool { playingAssetId == assetId }

    func toggle(assetId: String, url: URL) {
        if playingAssetId == assetId {
            stop()
            return
        }
        play(assetId: assetId, url: url)
    }

    func play(assetId: String, url: URL) {
        stop()
        let item = AVPlayerItem(url: url)
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        player.replaceCurrentItem(with: item)
        player.seek(to: .zero)
        player.play()
        playingAssetId = assetId
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        playingAssetId = nil
    }
}
