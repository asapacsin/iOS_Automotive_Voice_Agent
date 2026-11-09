import Synchronization

/// F-13 §18 item 2 (T-032f): the preview's PCM, owned by the app. One writer (the download task) and one reader
/// (`LiveAudio`'s source-node render block). Interleaved stereo float frames, allocated once; `seconds` of audio
/// at most (40 s for a 30 s preview), frames beyond that are dropped.
///
/// The reader never blocks, allocates, frees or logs: it reads atomics and copies frames. Writers and `reset` share
/// a `Mutex` among themselves only (the reader never takes it). A reset raises the generation and empties the
/// buffer; a write or finish under an older generation is ignored. A read that raced a reset is validated against
/// the generation after its copy and gives zeros instead (seqlock style), so a frame read is always from the
/// current generation, or zero.
public final class PreviewRing: @unchecked Sendable {
    public enum WriteResult: Sendable, Hashable {
        /// Every frame was kept.
        case written
        /// The generation is not the current one: nothing was kept.
        case stale
        /// The buffer was full: some frames were dropped. Reported once per generation; later drops are `.full`.
        case overflow
        case full
    }

    public struct ReadResult: Sendable, Hashable {
        /// Frames copied from the buffer; the rest of the block was zeros.
        public let frames: Int
        /// This read took the last frame of a finished buffer (once per generation).
        public let drainedNow: Bool
    }

    public let capacityFrames: Int
    public let sampleRate: Double
    private let storage: UnsafeMutablePointer<Float>
    /// generation << 32 | finished << 31 | frames written.
    private let writeState = Atomic<UInt64>(0)
    /// generation << 32 | frames read. Stored by the reader only.
    private let readState = Atomic<UInt64>(0)
    /// The generation the reader may play (0: none).
    private let active = Atomic<UInt64>(0)
    /// The generation whose finished buffer was read to its end (0: none).
    private let drained = Atomic<UInt64>(0)
    private let writers = Mutex(false)  // overflow reported for the current generation

    private static let finishedBit: UInt64 = 1 << 31
    private static let countMask: UInt64 = (1 << 31) - 1

    public init(seconds: Double = 40, sampleRate: Double = 44_100) {
        self.sampleRate = sampleRate
        capacityFrames = Int(seconds * sampleRate)
        storage = .allocate(capacity: capacityFrames * 2)
        storage.initialize(repeating: 0, count: capacityFrames * 2)
    }

    deinit { storage.deallocate() }

    private static func pack(_ generation: Int, _ finished: Bool, _ count: Int) -> UInt64 {
        UInt64(UInt32(truncatingIfNeeded: generation)) << 32 | (finished ? finishedBit : 0) | UInt64(count)
    }

    private static func generation(_ s: UInt64) -> UInt64 { s >> 32 }
    private static func count(_ s: UInt64) -> Int { Int(s & countMask) }

    // MARK: Writer side (download task, mediaQueue)

    /// Empties the buffer for `generation` (greater than the last one). Not playing until `activate`.
    public func reset(generation: Int) {
        active.store(0, ordering: .releasing)
        writers.withLock { reported in
            reported = false
            writeState.store(Self.pack(generation, false, 0), ordering: .releasing)
        }
    }

    /// The reader plays `generation` (when it is the current one).
    public func activate(generation: Int) {
        active.store(UInt64(UInt32(truncatingIfNeeded: generation)), ordering: .releasing)
    }

    /// The reader plays nothing (zeros).
    public func deactivate() { active.store(0, ordering: .releasing) }

    /// Appends `count` frames given as two planes.
    public func write(generation: Int, left: UnsafePointer<Float>, right: UnsafePointer<Float>, count: Int) -> WriteResult {
        write(generation: generation, count: count) { target, offset, n in
            for i in 0..<n {
                target[2 * i] = left[offset + i]
                target[2 * i + 1] = right[offset + i]
            }
        }
    }

    /// Appends interleaved stereo frames.
    public func write(generation: Int, interleaved: [Float]) -> WriteResult {
        interleaved.withUnsafeBufferPointer { source in
            write(generation: generation, count: source.count / 2) { target, offset, n in
                target.update(from: source.baseAddress! + 2 * offset, count: 2 * n)
            }
        }
    }

    private func write(generation: Int, count: Int,
                       copy: (_ target: UnsafeMutablePointer<Float>, _ offset: Int, _ frames: Int) -> Void) -> WriteResult {
        writers.withLock { reported in
            let s = writeState.load(ordering: .acquiring)
            guard Self.generation(s) == UInt64(UInt32(truncatingIfNeeded: generation)), s & Self.finishedBit == 0 else {
                return .stale
            }
            let written = Self.count(s)
            let n = min(max(count, 0), capacityFrames - written)
            if n > 0 {
                copy(storage + 2 * written, 0, n)
                writeState.store(Self.pack(generation, false, written + n), ordering: .releasing)
            }
            guard n < count else { return .written }
            if reported { return .full }
            reported = true
            return .overflow
        }
    }

    /// The download ended: once the reader has taken the last frame, the buffer is drained.
    public func finish(generation: Int) {
        writers.withLock { _ in
            let s = writeState.load(ordering: .acquiring)
            guard Self.generation(s) == UInt64(UInt32(truncatingIfNeeded: generation)) else { return }
            writeState.store(s | Self.finishedBit, ordering: .releasing)
        }
    }

    /// The finished buffer of `generation` was read to its end. Read by the mediaQueue timer, never the reader.
    public func isDrained(generation: Int) -> Bool {
        let g = drained.load(ordering: .acquiring)
        return g != 0 && g == UInt64(UInt32(truncatingIfNeeded: generation))
    }

    /// Frames written to the current generation.
    public var writtenFrames: Int { Self.count(writeState.load(ordering: .acquiring)) }

    // MARK: Reader side (render block): atomics and a copy only

    /// Fills `frames` frames of both planes: from the buffer while the active generation has frames, zeros after.
    public func read(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> ReadResult {
        var got = 0
        var drainedNow = false
        let playing = active.load(ordering: .acquiring)
        let s = writeState.load(ordering: .acquiring)
        if playing != 0, Self.generation(s) == playing {
            var r = readState.load(ordering: .relaxed)
            if Self.generation(r) != playing { r = playing << 32 }
            let read = Self.count(r)
            let written = Self.count(s)
            let n = min(frames, max(written - read, 0))
            let source = storage + 2 * read
            for i in 0..<n {
                left[i] = source[2 * i]
                right[i] = source[2 * i + 1]
            }
            // A reset during the copy may have refilled these frames for a newer generation: give zeros.
            if Self.generation(writeState.load(ordering: .acquiring)) == playing,
               active.load(ordering: .acquiring) == playing {
                got = n
                readState.store(playing << 32 | UInt64(read + n), ordering: .relaxed)
                if s & Self.finishedBit != 0, read + n == written, drained.load(ordering: .relaxed) != playing {
                    drained.store(playing, ordering: .releasing)
                    drainedNow = true
                }
            }
        }
        for i in got..<max(frames, got) {
            left[i] = 0
            right[i] = 0
        }
        return ReadResult(frames: got, drainedNow: drainedNow)
    }

    /// Interleaved read for tests and tools (allocates; not for the render block).
    public func read(frames: Int) -> (samples: [Float], result: ReadResult) {
        var l = [Float](repeating: 0, count: frames), r = l
        let result = l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in read(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames) }
        }
        var out = [Float](repeating: 0, count: 2 * frames)
        for i in 0..<frames {
            out[2 * i] = l[i]
            out[2 * i + 1] = r[i]
        }
        return (out, result)
    }
}
