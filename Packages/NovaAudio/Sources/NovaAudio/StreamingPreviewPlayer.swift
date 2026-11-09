import AVFoundation
import Foundation
import NovaPorts

/// F-13 §14 items 4–6 (T-032b): streams one iTunes preview URL with `AVPlayer`. Nothing is written to disk
/// (no download task, no asset cache). Playing is read from `timeControlStatus`, never assumed (I-1).
/// OWNER: the player is outside the voice-processing engine, so the preview is not in the echo reference
/// and is not ducked like the bundled track (STATUS, T-032b).
public final class StreamingPreviewPlayer: PreviewPlayer, @unchecked Sendable {
    /// Main-actor state only: every read and write is inside `MainActor.run`.
    private final class State: @unchecked Sendable {
        var player: AVPlayer?
        var item: AVPlayerItem?
        var endObserver: NSObjectProtocol?
        var statusObservation: NSKeyValueObservation?
    }

    private let state = State()
    private let audio: LiveAudio
    private let onEnded: @Sendable () -> Void

    /// `onEnded`: the preview finished by itself (item 6).
    public init(audio: LiveAudio, onEnded: @escaping @Sendable () -> Void) {
        self.audio = audio
        self.onEnded = onEnded
        // Session end, barge-in and 停 on the media lane stop the preview too.
        audio.onMediaStop { [weak self] in Task { await self?.stop() } }
    }

    public func play(_ url: URL) async {
        await stop()
        let state = state, audio = audio, onEnded = onEnded
        await MainActor.run {
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            state.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                                       object: item, queue: .main) { _ in
                MainActor.assumeIsolated {
                    // Only the item still playing ends; a stale notification never stops the next preview.
                    guard state.item === item else { return }
                    Self.tearDown(state)
                    audio.reportStreamedMedia(false)
                    onEnded()
                }
            }
            state.statusObservation = player.observe(\.timeControlStatus, options: [.new]) { p, _ in
                audio.reportStreamedMedia(p.timeControlStatus == .playing)
            }
            state.player = player
            state.item = item
            player.play()
        }
    }

    public func stop() async {
        let state = state
        let stopped = await MainActor.run { () -> Bool in
            guard state.player != nil else { return false }
            Self.tearDown(state)
            return true
        }
        if stopped { audio.reportStreamedMedia(false) }
    }

    @MainActor private static func tearDown(_ state: State) {
        state.statusObservation?.invalidate()
        state.player?.pause()
        state.player?.replaceCurrentItem(with: nil)
        if let observer = state.endObserver { NotificationCenter.default.removeObserver(observer) }
        state.player = nil
        state.item = nil
        state.endObserver = nil
        state.statusObservation = nil
    }

    public var isPlaying: Bool {
        get async {
            let state = state
            return await MainActor.run { state.player?.timeControlStatus == .playing }
        }
    }
}
