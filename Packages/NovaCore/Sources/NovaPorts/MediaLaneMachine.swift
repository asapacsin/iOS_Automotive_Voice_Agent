/// F-13 §18 items 3–6 (T-032f): the media lane as a pure state machine. `LiveAudio` runs each command on its serial
/// `mediaQueue` and carries out the effects in order. A preview stop is a buffer reset and a counter; no effect ever
/// stops, resets or schedules a node for the preview. Only the bundled loop has a node (`*BundledNode`).
public struct MediaLaneMachine: Sendable, Hashable {
    public enum State: Sendable, Hashable {
        case idle
        case bundled
        case previewLoading(generation: Int)
        case previewPlaying(generation: Int)
    }

    public enum Effect: Sendable, Hashable {
        /// The lane's `PlaybackEvent.mediaPlaying`.
        case mediaPlaying(Bool)
        /// `PreviewRing.reset(generation:)`.
        case resetBuffer(generation: Int)
        /// `PreviewRing.activate(generation:)`.
        case activate(generation: Int)
        /// `PreviewRing.deactivate()`.
        case deactivate
        case stopBundledNode
        /// Schedule the loop and play; the result comes back through `bundledStarted(playing:)`.
        case playBundledNode
        /// Engine restart: play the bundled node again.
        case replayBundledNode
        /// The 250 ms drained check (item 4).
        case startTimer
        case cancelTimer
        /// The preview of `generation` played to its end: run its `onEnd` (§14 item 6).
        case ended(generation: Int)
    }

    public private(set) var state: State = .idle
    private var generation = 0
    private var finished = false

    public init() {}

    private var previewGeneration: Int? {
        switch state {
        case .previewLoading(let g), .previewPlaying(let g): g
        case .idle, .bundled: nil
        }
    }

    public var previewPlaying: Bool { if case .previewPlaying = state { true } else { false } }
    public var playing: Bool { state == .bundled || previewPlaying }
    /// A preview is loading or playing.
    public var hasPreview: Bool { previewGeneration != nil }

    /// Stops whatever is on the lane.
    public mutating func stop() -> [Effect] {
        switch state {
        case .idle:
            return []
        case .bundled:
            state = .idle
            return [.stopBundledNode, .mediaPlaying(false)]
        case .previewLoading, .previewPlaying:
            return stopPreview()
        }
    }

    /// Stops a preview only (the bundled loop keeps playing). A new generation, so a late write is ignored.
    public mutating func stopPreview() -> [Effect] {
        guard previewGeneration != nil else { return [] }
        let wasPlaying = previewPlaying
        generation += 1
        state = .idle
        finished = false
        var effects: [Effect] = [.deactivate, .resetBuffer(generation: generation), .cancelTimer]
        if wasPlaying { effects.append(.mediaPlaying(false)) }
        return effects
    }

    /// A new preview: stops the lane, then a fresh buffer. Returns the generation as the token.
    public mutating func begin() -> (generation: Int, effects: [Effect]) {
        var effects = stop()
        generation += 1
        finished = false
        state = .previewLoading(generation: generation)
        effects.append(.resetBuffer(generation: generation))
        return (generation, effects)
    }

    /// `PreviewStartRule` said start. Nothing when the preview was stopped or replaced.
    public mutating func start(_ token: Int) -> [Effect] {
        guard state == .previewLoading(generation: token) else { return [] }
        state = .previewPlaying(generation: token)
        return [.activate(generation: token), .mediaPlaying(true), .startTimer]
    }

    /// The download of `token` ended.
    public mutating func finish(_ token: Int) {
        if previewGeneration == token { finished = true }
    }

    /// The timer saw the buffer of `token` drained. Only a finished download ends the preview; otherwise a stall.
    public mutating func drained(_ token: Int) -> [Effect] {
        guard state == .previewPlaying(generation: token), finished else { return [] }
        return stopPreview() + [.ended(generation: token)]
    }

    /// 「放首歌」: a repeated play over the running loop reports false then true; a preview is stopped first.
    public mutating func playBundled() -> [Effect] {
        if state == .bundled { return [.mediaPlaying(false), .mediaPlaying(true)] }
        return stop() + [.playBundledNode]
    }

    /// The bundled node was read back after `playBundledNode`.
    public mutating func bundledStarted(playing: Bool) -> [Effect] {
        guard playing, state == .idle else { return [] }
        state = .bundled
        return [.mediaPlaying(true)]
    }

    /// `AVAudioEngineConfigurationChange`: the preview keeps its buffer and generation; the bundled node replays.
    public func restart() -> [Effect] {
        state == .bundled ? [.replayBundledNode] : []
    }
}

/// F-13 §18 item 7: a slow media-lane command, numbers only. Pure.
public enum MediaLaneLine {
    public enum Command: String, Sendable, CaseIterable {
        case begin, start, stop, end
        case bundledPlay = "bundled_play"
        case bundledStop = "bundled_stop"
        case restart
    }

    /// Over 200 ms waiting for the queue or running.
    public static let slowMs = 200

    /// The line, or nil when the command was not slow.
    public static func slow(_ command: Command, waitMs: Int, runMs: Int) -> String? {
        guard waitMs > slowMs || runMs > slowMs else { return nil }
        return "music lane slow cmd=\(command.rawValue) wait_ms=\(waitMs) run_ms=\(runMs)"
    }
}
