import AVFoundation
import Foundation
import NovaPorts

/// F-13 §14 items 4–6 (T-032b): streams one iTunes preview URL with `AVPlayer`. Nothing is written to disk
/// (no download task, no asset cache). Playing is read from `timeControlStatus`, never assumed (I-1).
public final class StreamingPreviewPlayer: PreviewPlayer, @unchecked Sendable {
    private let lock = NSLock()
    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private let audio: LiveAudio
    private let onEnded: @Sendable () -> Void

    /// `onEnded`: the preview finished by itself (item 6).
    public init(audio: LiveAudio, onEnded: @escaping @Sendable () -> Void) {
        self.audio = audio
        self.onEnded = onEnded
    }

    public func play(_ url: URL) async {
        await stop()
        await MainActor.run {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.automaticallyWaitsToMinimizeStalling = true
            let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item,
                                                                  queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { await self.stop(); self.onEnded() }
            }
            let observation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
                self?.audio.reportStreamedMedia(p.timeControlStatus == .playing)
            }
            self.lock.withLock {
                self.player = player
                self.endObserver = observer
                self.statusObservation = observation
            }
            player.play()
        }
    }

    public func stop() async {
        let (player, observer, observation) = lock.withLock {
            defer { self.player = nil; endObserver = nil; statusObservation = nil }
            return (self.player, endObserver, statusObservation)
        }
        guard let player else { return }
        observation?.invalidate()
        await MainActor.run {
            player.pause()
            player.replaceCurrentItem(with: nil)
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        audio.reportStreamedMedia(false)
    }

    public var isPlaying: Bool {
        get async {
            guard let player = lock.withLock({ self.player }) else { return false }
            return await MainActor.run { player.timeControlStatus == .playing }
        }
    }
}
