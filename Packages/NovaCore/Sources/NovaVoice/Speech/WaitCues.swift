import NovaKit

/// The fixed wait cues (`A/voice/WaitCues.kt`, SPEC-020). They say she is working on it, never that
/// anything is done (I-1).
public enum WaitCues {
    public static let progress = "收到，正在处理。"
    public static let delay = "还在处理，网络可能不太稳定，再等我一下。"
    public static let stalled = "网络有点慢，我再试一下。"
    public static let stallFailed = "网络不太好，刚才没办成，请再说一遍。"
    public static let resultOnScreen = "刚才网络断了一下，结果请看屏幕。"
    public static let reconnected = "刚才网络断了一下，请再说一遍。"
    public static let ackAction = progress
    public static let ackChat = "嗯，我想想。"
    public static let providerSlow = "网络有点慢，请稍等。"
    public static let verifying = "我确认一下，马上回答你。"
    public static let stillWaiting = delay
    public static let toolRoute = "正在搜索路线，稍等一下。"
    public static let toolQuery = "正在查询，稍等一下。"
    public static let toolMusic = "正在找歌，稍等一下。"
    public static let toolCamera = "正在看画面，稍等一下。"
    public static let toolDefault = "正在处理，稍等一下。"

    public static let all = [ackAction, ackChat, providerSlow, verifying, stillWaiting, toolRoute, toolQuery,
                             toolMusic, toolCamera, toolDefault, stalled, stallFailed, resultOnScreen, reconnected]

    public static func toolPhrase(_ tool: String) -> String {
        switch tool {
        case "navigate_to", "choose_navigation_option": toolRoute
        case "query_live_info": toolQuery
        case "play_music", "control_music": toolMusic
        case "describe_camera_view": toolCamera
        default: toolDefault
        }
    }

    /// The next threshold strictly after `elapsed` (3 s, 7 s, 12 s), or nil.
    public static func nextThreshold(after elapsed: NovaDuration, tuning: WaitCueTuning = WaitCueTuning()) -> NovaDuration? {
        [tuning.visualCue, tuning.spokenCue, tuning.delayLine].first { $0 > elapsed }
    }
}

/// A cue to show or speak: `visual` has no text.
public struct WaitCue: Sendable, Hashable {
    public enum Code: String, Sendable { case visual, progress, delay }
    public let code: Code
    public let text: String
}

/// One driver turn's wait-cue state (`WaitCueTurn`): from his end of speech until her reply is
/// audible. At most one visual, one progress and one delay line per turn.
public struct WaitCueTurn: Sendable {
    public private(set) var toolName: String?
    public private(set) var responseStarted = false
    public private(set) var toolOutstanding = false
    /// Her reply's words were queued or became audible: no cue may be spoken.
    public var replyUnderway = false
    /// The uplink segment looked like a cough or a knock (`SegmentVerdict.flagged`).
    public var suspiciousAudio = false
    public var stopped = false
    public private(set) var visualShown = false
    private var visualDone = false
    private var progressDone = false
    private var delayDone = false
    private let tuning: WaitCueTuning

    public init(tuning: WaitCueTuning = WaitCueTuning()) { self.tuning = tuning }

    public mutating func onToolCall(_ name: String) {
        if toolName == nil { toolName = name }
        toolOutstanding = true
    }
    public mutating func onResponseStarted() { responseStarted = true; toolOutstanding = false }
    public mutating func onToolResultDelivered() { toolOutstanding = false }
    public mutating func clearVisual() { visualShown = false }

    /// The model answered, or the audio looked like speech.
    public var hasEvidence: Bool { responseStarted || toolName != nil || !suspiciousAudio }

    /// The cue due at `elapsed` (marking it used), or nil. Call repeatedly until nil.
    public mutating func due(_ elapsed: NovaDuration) -> WaitCue? {
        guard hasEvidence, !replyUnderway, !stopped else { return nil }
        if !visualDone && elapsed >= tuning.visualCue {
            visualDone = true
            visualShown = true
            return WaitCue(code: .visual, text: "")
        }
        if !progressDone && elapsed >= tuning.spokenCue {
            progressDone = true
            // A wake-up that already missed 7 s says the delay once, not progress and then delay.
            if elapsed < tuning.delayLine { return WaitCue(code: .progress, text: WaitCues.progress) }
        }
        if !delayDone && elapsed >= tuning.delayLine {
            delayDone = true
            return WaitCue(code: .delay, text: WaitCues.delay)
        }
        return nil
    }
}
