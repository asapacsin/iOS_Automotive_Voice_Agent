import AVFAudio
import Foundation
import NovaPorts

/// The bundled track (F-13) when no audio file ships with the app: a calm 16-bar loop of soft sine
/// chords (I–vi–IV–V in C), generated once. Offline and royalty-free by construction.
enum BundledLoop {
    static let track = BundledTrack(resourceName: "nova_drive_loop")

    static func buffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let beat = 0.5
        // Chord roots and their triads, two bars of four beats each.
        let chords: [[Double]] = [[261.63, 329.63, 392.00], [220.00, 261.63, 329.63],
                                  [174.61, 220.00, 261.63], [196.00, 246.94, 293.66]]
        let beatsPerChord = 8
        let frames = Int(rate * beat) * beatsPerChord * chords.count * 2
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let out = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let beatFrames = Int(rate * beat)
        for i in 0..<frames {
            let beatIndex = i / beatFrames
            let chord = chords[(beatIndex / beatsPerChord) % chords.count]
            let t = Double(i) / rate
            let inBeat = Double(i % beatFrames) / Double(beatFrames)
            // Pad: the triad, quiet. Arpeggio: one chord tone per beat with a soft decay.
            var sample = chord.reduce(0) { $0 + sin(2 * .pi * $1 * t) } * 0.04
            let note = chord[beatIndex % chord.count] * 2
            sample += sin(2 * .pi * note * t) * 0.12 * exp(-4 * inBeat)
            out[i] = Float(sample)
        }
        return buffer
    }
}

/// `MusicPort` on the media lane (F-13). Playing is read back from the lane, never assumed (I-1).
public struct LaneMusicPlayer: MusicPort {
    private let audio: LiveAudio

    public init(audio: LiveAudio) { self.audio = audio }

    public func playBundled() async -> Bool {
        audio.playMedia(BundledLoop.track)
        return audio.mediaPlaying
    }

    public func stop() async { audio.stopMedia() }

    public var isPlaying: Bool { get async { audio.mediaPlaying } }
}
