import NovaPorts

/// F-24 §16 item 1 (T-020b): joins 10 ms uplink frames into one Gemini message per 100 ms (1,600 samples,
/// 3,200 bytes), so a held utterance released at once is about 60 messages instead of about 590. The owner
/// sends what is held early (`flush`) when the gate closes, at `activityEnd` or `audioStreamEnd`, before any
/// non-audio message and on mute, so nothing is reordered or lost. Pure; bytes are never changed.
public struct AudioChunker: Sendable {
    /// Google's Live API guides: audio in chunks of 100 ms.
    public static let framesPerMessage = 10

    private var frames: [PCMFrame16k] = []

    public init() {}

    public var isEmpty: Bool { frames.isEmpty }

    /// Adds one frame; returns a full 100 ms message when one is ready.
    public mutating func add(_ frame: PCMFrame16k) -> [PCMFrame16k]? {
        frames.append(frame)
        guard frames.count >= Self.framesPerMessage else { return nil }
        return flush()
    }

    /// Whatever is held, now (nil when nothing is).
    public mutating func flush() -> [PCMFrame16k]? {
        guard !frames.isEmpty else { return nil }
        defer { frames.removeAll(keepingCapacity: true) }
        return frames
    }
}
