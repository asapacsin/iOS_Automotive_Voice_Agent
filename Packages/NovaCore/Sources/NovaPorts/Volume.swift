import Foundation
import NovaKit

/// F-13a §3: the app's two volumes of its own. `media` is the song (bundled loop and preview); `voice` is her voice,
/// navigation guidance and the cue. The phone's volume is the ceiling; the app never changes it (§3 item 4).
public enum VolumeTarget: String, Sendable, Hashable, CaseIterable {
    case media, voice

    /// §3 item 1–2: media 0–10; voice 2–10, so she stays audible for confirmations and safety lines.
    public var range: ClosedRange<Int> { self == .media ? 0...VolumeLevels.maximum : 2...VolumeLevels.maximum }
    public var minimum: Int { range.lowerBound }
    /// `level` moved into `range`.
    public func clamp(_ level: Int) -> Int { Swift.min(Swift.max(level, range.lowerBound), range.upperBound) }

    /// §3 item 1: the UserDefaults keys.
    public var settingsKey: String { self == .media ? "volumeMedia" : "volumeVoice" }
}

/// F-13a §3 item 1: both levels, integers, default 10 (today's sound). The gain of level `n` is `n / 10`.
public struct VolumeLevels: Sendable, Hashable {
    public static let maximum = 10

    public private(set) var media: Int
    public private(set) var voice: Int

    /// Out-of-range values are clamped into each target's range.
    public init(media: Int = maximum, voice: Int = maximum) {
        self.media = VolumeTarget.media.clamp(media)
        self.voice = VolumeTarget.voice.clamp(voice)
    }

    public subscript(target: VolumeTarget) -> Int {
        get { target == .media ? media : voice }
        set {
            switch target {
            case .media: media = target.clamp(newValue)
            case .voice: voice = target.clamp(newValue)
            }
        }
    }

    public static func gain(_ level: Int) -> Double { Double(level) / Double(maximum) }
    public var mediaGain: Double { Self.gain(media) }
    public var voiceGain: Double { Self.gain(voice) }

    /// §3 item 1: the saved levels; a missing or unreadable value is the default 10.
    public static func saved(in store: any SettingsStore) -> VolumeLevels {
        func level(_ target: VolumeTarget) -> Int {
            store.string(target.settingsKey).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? maximum
        }
        return VolumeLevels(media: level(.media), voice: level(.voice))
    }

    public func save(_ target: VolumeTarget, in store: any SettingsStore) {
        store.set(String(self[target]), for: target.settingsKey)
    }
}

/// F-13a §3 item 3: the reply node's gain. The F-08 §17 item 11 barge-in dip multiplies the voice gain instead of
/// replacing it; restored (and after a flush) it is the voice gain, never 1.
public enum ReplyGain {
    /// `dipDb` nil: not dipped.
    public static func value(voiceGain: Double, dipDb: Double?) -> Double {
        guard let dipDb else { return voiceGain }
        return voiceGain * pow(10, -dipDb / 20)
    }
}

/// F-13a §3 items 3–4: where the app's own gains go (NovaAudio). Never the phone's volume.
public protocol VolumeOutput: Sendable {
    /// Applies both lane gains at once; called before a tool result is sent (§4 item 5).
    func apply(_ levels: VolumeLevels)
    /// `AVAudioSession.outputVolume` (0...1), read only to word the answer (§4 item 5); nil when unknown.
    var phoneVolume: Double? { get }
}
