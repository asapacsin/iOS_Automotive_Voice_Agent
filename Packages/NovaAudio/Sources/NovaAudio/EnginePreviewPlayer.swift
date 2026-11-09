import AVFAudio
import Foundation
import NovaPorts

/// F-13 §16 items 1, 5 and §17 items 1–5 (T-032e): an iTunes preview played through `LiveAudio`'s engine on the media
/// lane, so voice processing has it in the echo reference, it is ducked like the bundled track and every media-lane
/// stop stops it. The response is read as it arrives: a `moov`-first file is parsed and converted by `PreviewStreamer`
/// and written in pieces of about 0.5 s into `LiveAudio`'s preview buffer (§18 items 1–2, T-032f), which its source
/// node reads; playing starts at 1.0 s written or at the end of the download (`PreviewStartRule`). A stop empties the
/// buffer; nothing here stops a node. A `mdat`-first file is kept in memory and decoded at
/// the end by `PreviewDecoder` (§17 item 2). Nothing is written to disk; no `URLCache`. `play` returns at once; the
/// handler's 6 s now-playing poll is the proof. The stage of a failure is kept in `lastFailure`.
public final class EnginePreviewPlayer: PreviewPlayer, @unchecked Sendable {
    /// §17 item 3: an idle timeout (no byte for 5 s), not a limit on the whole download.
    public static let downloadTimeout: TimeInterval = 5
    /// A 30 s AAC preview is about 1 MB; anything far larger is not a preview.
    public static let maxBytes = 8 * 1024 * 1024
    /// Bytes handed to the parser at a time.
    static let chunkBytes = 16 * 1024

    private let audio: LiveAudio
    private let onEnded: @Sendable () -> Void
    private let session: URLSession
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var failure: PreviewFailure?
    private var progressValue = PreviewProgress()

    /// `onEnded`: the preview played to its end, or was cut by a failure after it started (item 6).
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
        let mine = lock.withLock { () -> Int in
            generation += 1
            failure = nil
            progressValue = PreviewProgress()
            return generation
        }
        let work = Task<Void, Never>.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.run(url, mine: mine, asked: ContinuousClock.now)
        }
        lock.withLock { if generation == mine { task = work } else { work.cancel() } }
    }

    public func stop() async {
        let running = lock.withLock { () -> Task<Void, Never>? in
            generation += 1
            // §17 item 5: a stop is `stopped` only when nothing else failed first.
            if failure == nil { failure = .stopped }
            defer { task = nil }
            return task
        }
        running?.cancel()
        audio.stopPreview()
    }

    public var isPlaying: Bool { get async { audio.previewPlaying } }

    public var lastFailure: PreviewFailure? { get async { lock.withLock { failure } } }

    public var progress: PreviewProgress { get async { lock.withLock { progressValue } } }

    // MARK: The download task

    private func wanted(_ mine: Int) -> Bool { !Task.isCancelled && lock.withLock { generation == mine } }

    private func fail(_ stage: PreviewFailure, _ mine: Int) {
        lock.withLock { if generation == mine, failure == nil { failure = stage } }
    }

    private func update(_ mine: Int, _ change: (inout PreviewProgress) -> Void) {
        lock.withLock { if generation == mine { change(&progressValue) } }
    }

    private static func ms(since start: ContinuousClock.Instant) -> Int {
        let d = ContinuousClock.now - start
        return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func stage(for error: Error) -> PreviewFailure {
        (error as? URLError)?.code == .timedOut ? .downloadTimeout : .downloadNetwork
    }

    private func run(_ url: URL, mine: Int, asked: ContinuousClock.Instant) async {
        let audio = audio
        guard wanted(mine) else { return }
        guard let token = audio.beginPreviewStream() else { return fail(.engine, mine) }
        // A stop that came between the check above and the begin: this preview is not wanted.
        guard wanted(mine) else { return audio.stopPreview(token: token) }
        let format = audio.previewPCMFormat
        var kept = Data()
        var layout = PreviewLayout.needMore
        var scheduledFrames: AVAudioFramePosition = 0
        var started = false
        var refused = false
        var tooLong = false
        var laneStopped = false
        var refusal: PreviewFailure { laneStopped ? .stopped : .engine }

        // Writes one piece into the buffer; starts playing by the start rule.
        func schedule(_ pcm: AVAudioPCMBuffer, downloadEnded: Bool) {
            guard !refused, !tooLong, wanted(mine) else { return }
            switch audio.writePreview(pcm, token: token) {
            case .written:
                scheduledFrames += AVAudioFramePosition(pcm.frameLength)
            case .overflow, .full:
                // §18 item 2: the buffer keeps 40 s; the preview ends there (`cut stage=too_long`).
                tooLong = true
                scheduledFrames = AVAudioFramePosition(audio.previewFramesWritten)
            case .stale:
                // The lane was stopped or replaced (a bundled play, 「别放了」): `stopped`, not an engine failure.
                laneStopped = true
                refused = true
                return
            }
            startIfDue(downloadEnded: downloadEnded || tooLong)
        }
        func startIfDue(downloadEnded: Bool) {
            guard !started, !refused, scheduledFrames > 0,
                  PreviewStartRule.shouldStart(scheduledSeconds: Double(scheduledFrames) / format.sampleRate,
                                               downloadEnded: downloadEnded) else { return }
            guard audio.startPreviewStream(token: token, stillWanted: { [weak self] in
                self?.lock.withLock { self?.generation == mine } ?? false
            }) else {
                refused = true
                return
            }
            started = true
            let at = Self.ms(since: asked)
            update(mine) { $0.startMs = at }
        }
        let streamer = PreviewStreamer(output: format) { pcm in schedule(pcm, downloadEnded: false) }

        // Before the node started, a failure is `failed` and the lane is cleared; after, the scheduled audio plays
        // out and the preview ends (`cut`, item 3).
        func give(up stage: PreviewFailure) {
            guard wanted(mine) else { return }
            fail(stage, mine)
            if started {
                audio.finishPreviewStream(token: token) { [weak self] in self?.endedIfMine(mine) }
            } else {
                audio.stopPreview(token: token)
            }
        }
        func feed(_ chunk: Data) {
            kept.append(chunk)
            update(mine) { $0.bytes = kept.count }
            if layout == .needMore {
                layout = PreviewLayout.scan(kept)
                if layout != .needMore { update(mine) { $0.layout = layout } }
                if layout == .streamable { streamer.parse(kept) }
            } else if layout == .streamable {
                streamer.parse(chunk)
            }
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.downloadTimeout)
        request.httpMethod = "GET"
        var chunk = Data()
        do {
            let (bytes, response) = try await session.bytes(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else { return give(up: .downloadHTTP(status)) }
            chunk.reserveCapacity(Self.chunkBytes)
            for try await byte in bytes {
                if kept.isEmpty, chunk.isEmpty {
                    let at = Self.ms(since: asked)
                    update(mine) { $0.firstByteMs = at }
                }
                chunk.append(byte)
                guard chunk.count >= Self.chunkBytes else { continue }
                guard kept.count + chunk.count <= Self.maxBytes else { return give(up: .tooLarge) }
                feed(chunk)
                chunk.removeAll(keepingCapacity: true)
                guard wanted(mine) else { return }
                if refused { return give(up: refusal) }
                if tooLong { return give(up: .tooLong) }
            }
            guard kept.count + chunk.count <= Self.maxBytes else { return give(up: .tooLarge) }
            if !chunk.isEmpty { feed(chunk) }
        } catch {
            // The failed line counts every byte that arrived, also the part of a chunk not yet fed.
            let arrived = kept.count + chunk.count
            update(mine) { $0.bytes = arrived }
            return give(up: Self.stage(for: error))
        }
        guard wanted(mine) else { return }
        if refused { return give(up: refusal) }

        // The download ended.
        if layout == .needMore {
            layout = .wholeFile
            update(mine) { $0.layout = .wholeFile }
        }
        if layout == .streamable { streamer.finish() }
        // §17 item 2: a `mdat`-first file, or a stream nothing could be scheduled from, goes to the whole-file decoder.
        if scheduledFrames == 0, !refused {
            if layout == .streamable { update(mine) { $0.layout = .wholeFile } }
            guard let pcm = PreviewDecoder.decode(kept, to: format) else { return give(up: .parse) }
            guard wanted(mine) else { return }
            schedule(pcm, downloadEnded: true)
        }
        startIfDue(downloadEnded: true)
        guard wanted(mine) else { return }
        if refused || !started { return give(up: refused ? refusal : .engine) }
        if tooLong { return give(up: .tooLong) }
        // The parser stopped partway: what was scheduled plays, then the preview is cut with stage `parse`.
        if layout == .streamable, streamer.failed { return give(up: .parse) }
        audio.finishPreviewStream(token: token) { [weak self] in self?.endedIfMine(mine) }
    }

    private func endedIfMine(_ mine: Int) {
        guard lock.withLock({ generation == mine }) else { return }
        onEnded()
    }
}
