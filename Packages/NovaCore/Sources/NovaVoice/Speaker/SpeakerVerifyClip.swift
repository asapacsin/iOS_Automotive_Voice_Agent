import Foundation
import NovaKit
import NovaPorts

/// F-04b §14 item 1 (T-013h): the one clip rule for 校准 and the live check. The first `minVerifySpeech` of the frames,
/// in order; all of them when there is less, if that is at least `minScoreSpeech`; nil below that. Frames are 10 ms,
/// as in `SpeakerHold`, which uses the same `SpeakerTuning`. Pure.
public enum SpeakerVerifyClip {
    public static func frames(_ frames: [PCMFrame16k], tuning: SpeakerTuning = SpeakerTuning()) -> [PCMFrame16k]? {
        let n = Int(tuning.minVerifySpeech.milliseconds / 10)
        if frames.count >= n { return Array(frames.prefix(n)) }
        return NovaDuration.milliseconds(Int64(frames.count) * 10) >= tuning.minScoreSpeech ? frames : nil
    }

    /// §14 items 3–4: `minVerifySpeech` in ms (the scores file's `clipMs=`, the profile's `calibrationClipMs`).
    public static func clipMs(_ tuning: SpeakerTuning = SpeakerTuning()) -> Int { Int(tuning.minVerifySpeech.milliseconds) }
}

/// §14 items 6–7: the saved calibration as 设置 and 校准 show it, from the profile, in the phone's time zone. Pure.
public enum SpeakerCalibrationSummary {
    /// nil when there is nothing saved to show (no threshold, or a status that shows no calibration).
    public static func text(profile: SpeakerProfile?, status: SpeakerLockStatus, timeZone: TimeZone = .current)
        -> String? {
        guard let profile, let threshold = profile.threshold, let at = profile.calibratedAt else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.month, .day], from: at)
        let date = "\(day.month ?? 0)月\(day.day ?? 0)日"
        let t = String(format: "%.2f", threshold)
        switch status {
        case .ready where profile.calibrationClipMs == nil:
            // §15 item 3: calibrated before §14 on whole lines; the old file has no line counts.
            return "已校准：\(date)，阈值 \(t)（整句校准）"
        case .ready:
            return "已校准：\(date)，阈值 \(t)（录入的人 \(profile.calibrationDriverLines ?? 0) 句，"
                + "其他人 \(profile.calibrationOtherLines ?? 0) 句）"
        case .recalibrate:
            return "上次校准：\(date)，阈值 \(t)（旧方法，已停用）"
        default:
            return nil
        }
    }
}

/// §14 item 8: what the screen says when the lock drops a sentence or a wake word. Text only: no sound, no driver line,
/// no turn. Pure.
public enum SpeakerRejectionNotice {
    public static let speech = "没听出是录入的声音，这句没有发送"
    public static let wake = "没听出是录入的声音，没有唤醒"
    /// Shown for 3 s; a new one restarts it.
    public static let duration = NovaDuration.seconds(3)

    /// The notice for one check line, nil for none. Lines exist only with the lock on, so lock off shows nothing.
    /// Speech: rejected or unknown. Wake: not accepted. Stop phrases: nothing.
    public static func text(for line: SpeakerCheckLine) -> String? {
        switch (line.kind, line.result) {
        case (_, .accepted): nil
        case (.speech, _): speech
        case (.wake, _): wake
        case (.stop, _): nil
        }
    }
}

/// §14 item 8: one notice at a time for 3 s; a new one restarts the 3 s and replaces it (never stacks); while the
/// §6 item 11 chip shows, that chip wins. Time is the caller's clock. Pure.
public struct SpeakerNoticeBoard: Sendable, Hashable {
    public private(set) var current: String?
    private var until = NovaDuration.zero

    public init() {}

    public mutating func show(_ text: String, now: NovaDuration) {
        current = text
        until = now + SpeakerRejectionNotice.duration
    }

    public func visible(now: NovaDuration, chipShowing: Bool) -> String? {
        guard !chipShowing, let current, now < until else { return nil }
        return current
    }
}
