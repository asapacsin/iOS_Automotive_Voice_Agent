import NovaPorts

/// Cuts 16 kHz mono samples, delivered in chunks of any size, into exact 10 ms frames (F-03:
/// 160 samples = 320 bytes). The NovaAudio converter output feeds it; leftovers wait for the next chunk.
public struct AudioFramer10ms: Sendable {
    private var pending: [Int16] = []

    public init() {}

    /// Samples held back until a full frame is available (always < 160).
    public var bufferedSamples: Int { pending.count }

    public mutating func append(_ samples: [Int16]) -> [PCMFrame16k] {
        pending += samples
        let size = PCMFrame16k.samplesPerFrame
        let whole = pending.count / size
        guard whole > 0 else { return [] }
        let frames = (0..<whole).map { i in
            PCMFrame16k(samples: Array(pending[(i * size)..<((i + 1) * size)]))!
        }
        pending.removeFirst(whole * size)
        return frames
    }

    /// Drops a partial frame (capture stopped or restarted).
    public mutating func reset() { pending.removeAll(keepingCapacity: true) }
}
