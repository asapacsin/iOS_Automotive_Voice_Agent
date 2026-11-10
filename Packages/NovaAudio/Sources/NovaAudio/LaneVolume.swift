import AVFAudio
import Foundation
import NovaPorts

/// F-13a §3 items 3–4 (T-032g): the app's volume output. The levels outlive a session; the session's `LiveAudio`
/// gets them as soon as it is attached and on every change. The phone's volume is only read, never set.
public final class LaneVolume: VolumeOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var levels = VolumeLevels()
    private weak var audio: LiveAudio?

    public init() {}

    /// A session's engine (nil when it stops). It is given the current levels at once.
    public func attach(_ audio: LiveAudio?) {
        let levels = lock.withLock { () -> VolumeLevels in
            self.audio = audio
            return self.levels
        }
        audio?.setLaneGains(media: levels.mediaGain, voice: levels.voiceGain)
    }

    public func apply(_ levels: VolumeLevels) {
        let audio = lock.withLock { () -> LiveAudio? in
            self.levels = levels
            return self.audio
        }
        audio?.setLaneGains(media: levels.mediaGain, voice: levels.voiceGain)
    }

    /// §3 item 4: read only to word the answer (§4 item 5).
    public var phoneVolume: Double? { Double(AVAudioSession.sharedInstance().outputVolume) }
}
