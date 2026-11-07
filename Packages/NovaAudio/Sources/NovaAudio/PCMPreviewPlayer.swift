import AVFAudio
import Foundation
import NovaPorts

/// F-07 §14 item 2 (T-020a): plays one 试听 buffer in 设置, outside any session. Main actor only.
@MainActor
public final class PCMPreviewPlayer {
    private var player: AVAudioPlayer?

    public init() {}

    public func play(_ pcm: PCMBuffer) throws {
        let player = try AVAudioPlayer(data: Self.wav(pcm))
        self.player = player
        player.play()
    }

    /// A 16-bit mono WAV around the PCM.
    public nonisolated static func wav(_ pcm: PCMBuffer) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let rate = UInt32(pcm.sampleRate), size = UInt32(pcm.samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + size); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(size)
        for s in pcm.samples { u16(UInt16(bitPattern: s)) }
        return d
    }
}
