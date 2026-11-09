import AVFAudio
import Foundation
import NovaPorts

/// F-13 §14 items 4–6 (T-032b): an iTunes preview played through `LiveAudio`'s engine on the media lane, so
/// voice processing has it in the echo reference, it is ducked like the bundled track and every media-lane
/// stop stops it. The file (about 1 MB for 30 s) is downloaded into memory with no cache, decoded in memory
/// and scheduled once; nothing is written to disk. `play` returns at once; the handler's 6 s now-playing poll
/// covers the download and decode, so a slow or failed download is `NOT_PLAYING` (§14 item 8).
public final class EnginePreviewPlayer: PreviewPlayer, @unchecked Sendable {
    public static let downloadTimeout: TimeInterval = 5
    /// A 30 s AAC preview is about 1 MB; anything far larger is not a preview.
    public static let maxBytes = 8 * 1024 * 1024

    private let audio: LiveAudio
    private let onEnded: @Sendable () -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var generation = 0

    /// `onEnded`: the preview played to its end (item 6).
    public init(audio: LiveAudio, onEnded: @escaping @Sendable () -> Void) {
        self.audio = audio
        self.onEnded = onEnded
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = Self.downloadTimeout
        session = URLSession(configuration: config)
    }

    public func play(_ url: URL) async {
        await stop()
        let mine = lock.withLock { () -> Int in generation += 1; return generation }
        let audio = audio, onEnded = onEnded, session = session
        let work = Task.detached(priority: .userInitiated) { [weak self] in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.downloadTimeout)
            request.httpMethod = "GET"
            guard let fetched = try? await session.data(for: request),
                  (fetched.1 as? HTTPURLResponse)?.statusCode == 200, fetched.0.count <= Self.maxBytes,
                  !Task.isCancelled,
                  let pcm = PreviewDecoder.decode(fetched.0, to: audio.previewPCMFormat),
                  !Task.isCancelled, let self, self.lock.withLock({ self.generation == mine }) else { return }
            audio.playPreview(pcm, stillWanted: { [weak self] in
                self?.lock.withLock { self?.generation == mine } ?? false
            }) { [weak self] in
                guard let self, self.lock.withLock({ self.generation == mine }) else { return }
                onEnded()
            }
        }
        lock.withLock { task = work }
    }

    public func stop() async {
        let running = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            defer { task = nil }
            return task
        }
        running?.cancel()
        audio.stopPreview()
    }

    public var isPlaying: Bool { get async { audio.previewPlaying } }
}
