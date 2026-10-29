import Foundation
import NovaKit
import NovaPorts

/// `A/voice/TranscriptText.kt`: drops whitespace runs that touch CJK characters or CJK / full-width
/// punctuation (Gemini character-spaces transcripts: 「帮 我 把 天 窗 打 开 。」); Latin spacing stays.
public enum TranscriptText {
    private static let spaceAtCJK = ICURegex(#"(?<=[　-〿一-鿿＀-￯])[\s　]+|[\s　]+(?=[　-〿一-鿿＀-￯])"#)

    public static func normalize(_ text: String) -> String {
        spaceAtCJK.replace(text, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// What the guards may read, all of it inside AgentCore (ios-architecture §8): the words of the
/// utterance being answered and the navigation mirror. Android reads the same from `DriverContext`.
public struct GuardContext: Sendable, Hashable {
    /// `DriverContext.currentRequestText()`.
    public var requestText: String
    /// Epoch of the last transcript, and of the last speech onset (`capabilityEpoch`). Words are this
    /// turn's only when `currentEpoch > 0 && currentEpoch >= capabilityEpoch`.
    public var currentEpoch: Int
    public var capabilityEpoch: Int
    /// `navigatingNow()`: a route is being driven.
    public var navigating: Bool
    /// `guidanceRunningNow()`: guidance itself runs (no pre-guidance phase).
    public var guidanceRunning: Bool
    /// A destination or route list waits for a choice.
    public var listOpen: Bool
    /// Saved places that are set (`SavedPlaces`); nil when AgentCore does not know them, in which case
    /// the navigation executor decides 家/公司 itself from the store.
    public var savedPlaces: Set<PlaceSlot>?
    /// F-05a §6: false when this turn's transcript could not be read (Gemini's guess was not Chinese).
    public var wordsReliable: Bool

    public init(requestText: String = "", currentEpoch: Int = 0, capabilityEpoch: Int = 0, navigating: Bool = false,
                guidanceRunning: Bool = false, listOpen: Bool = false, savedPlaces: Set<PlaceSlot>? = nil,
                wordsReliable: Bool = true) {
        self.requestText = requestText
        self.currentEpoch = currentEpoch
        self.capabilityEpoch = capabilityEpoch
        self.navigating = navigating
        self.guidanceRunning = guidanceRunning
        self.listOpen = listOpen
        self.savedPlaces = savedPlaces
        self.wordsReliable = wordsReliable
    }

    /// A transcript older than the speech onset is the previous turn's and is not used.
    var wordsAreCurrent: Bool { currentEpoch > 0 && currentEpoch >= capabilityEpoch }
    var said: String { TranscriptText.normalize(requestText) }
}

/// `A/nav/SavedPlaces.kt` slots.
public enum PlaceSlot: String, Sendable, Hashable, CaseIterable {
    case home, work

    static let homeTerms = ["回家", "返家", "我家", "家里", "家裡", "我屋企", "返屋企", "屋企", "家",
                            "go home", "home", "drive home", "take me home"]
    static let workTerms = ["回公司", "去公司", "上班", "返工", "我公司", "公司", "单位", "單位", "办公室", "辦公室",
                            "go to work", "work", "office", "the office"]
    static let stripped = ["导航去", "导航到", "导航", "帶我", "带我", "送我", "我要", "我想", "麻烦", "帮我", "幫我",
                           "请", "請", "现在", "現在", "立刻", "马上", "馬上", "吧", "啦", "喇", "了", "呀", "啊", "咯",
                           "。", "，", "！", "!", "?", "？", " "]

    /// `SavedPlaces.slotFor`: the whole utterance after filler is removed, never a substring
    /// (「家乐福」 is a supermarket).
    public static func slot(for spoken: String) -> PlaceSlot? {
        let core = strip(spoken)
        if core.isEmpty { return nil }
        if homeTerms.contains(where: { $0.caseInsensitiveCompare(core) == .orderedSame }) { return .home }
        if workTerms.contains(where: { $0.caseInsensitiveCompare(core) == .orderedSame }) { return .work }
        return nil
    }

    private static func strip(_ spoken: String) -> String {
        var text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            for token in stripped {
                if text.count > token.count, text.lowercased().hasPrefix(token.lowercased()) {
                    text = String(text.dropFirst(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
                if text.count > token.count, text.lowercased().hasSuffix(token.lowercased()) {
                    text = String(text.dropLast(token.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                    changed = true
                }
            }
        }
        return text
    }
}

/// `A/ToolCallGuards.kt`: whether a validated call may run, given what the driver said. Each returns
/// a code, or nil to let the call through. Code, not prompt (I-11).
public enum ToolCallGuards {
    // MARK: Vocabulary (Android constants, verbatim)

    static let endVerbs = "结束|退出|停止|停|取消|关闭|关掉|关|终止"
    static let nearEnd = ICURegex("(\(endVerbs))(一?下)?[了掉吧]{0,2}(这个|这次|本次|此次|当前的?|现在的?)?(导航|路线|行程)|(导航|路线|行程).{0,2}(\(endVerbs))")
    static let explicitNoNav = ICURegex("不(要|用|想|需要)?导航了?|别再?导航")
    static let nounRefused = ICURegex(#"(导航|路线|行程)(不要|不用|不需要)了?[吧啊呀]?[。！!，,\s]*$"#)
    static let negatedEnd = ICURegex("(不要|不用|不需要|不想|别再?|(?<!要)不)(\(endVerbs))")
    static let continueNav = ICURegex("继续(导航|路线|行程)|(导航|路线|行程)(还在)?继续|停车")
    static let navSound = ICURegex("(导航|路线)(的)?(声音|音量|播报|语音|提示音?)")
    static let traditional: [Character: Character] = ["導": "导", "結": "结", "關": "关", "閉": "闭", "終": "终",
                                                      "線": "线", "繼": "继", "續": "续", "別": "别", "須": "须"]
    static let stopTalking = ICURegex(
        #"(?i)(别|不要|不用|停止|停下|先别|少|甭).{0,2}(说|讲|出声|吵)|(别|不要|少).{0,2}(啰嗦|唠叨|叨叨|念)|(不许|不准).{0,2}(说|讲|出声)|闭嘴|住嘴|住口|闭上嘴|安静|嘘|shut\s*up|stop\s*talking|be\s*quiet"#)
    static let resumeTalking = ICURegex("(继续|接着|恢复).{0,2}(说|讲)|可以(说话|说了|讲了|出声)|说吧|说话吧")
    static let speechTraditional = traditional.merging(["說": "说", "講": "讲", "靜": "静", "聲": "声", "復": "复",
                                                        "續": "续", "噓": "嘘"]) { $1 }
    /// `ListeningIntent.SHUT_UP` entries the regexes above do not already cover (normalised: letters only).
    static let shutUpWords: Set<String> = ["keepquiet", "keepsilent", "staysilent", "silence", "quiet"]
    static let goIntent = ICURegex("导航|带我去|带我到|开过去|开去|前往|就去|改去|换(个|成)?(目的地|地方)|去(最近|附近|那|这)")
    static let onTheWay = ICURegex("路上|沿途|沿路|前面|前方")
    static let question = ICURegex("吗|有没有|哪里有|哪儿有|在哪|多远|[?？]")
    /// `UtteranceIntentResolver` cues for `SUNROOF_DOORS_LIGHTS_WIPERS` and `BODY_WINDOW`.
    static let unsupportedPartWords = ["后备箱", "天窗", "天幕", "车门", "车灯", "雨刷"]
    static let windowWords = ["车窗", "窗户", "开窗", "关窗"]
    static let driverSide = ["我这一侧", "我这半边", "我这边", "我这侧"]
    static let otherWindow = ["副驾驶", "副驾", "乘客", "右前", "左后", "右后", "后排", "后窗", "全部", "所有", "四个",
                              "两边", "两侧", "后面", "后边", "后头", "后座", "前排", "右边", "右侧", "别的", "其他",
                              "其它", "大家", "每扇", "每个窗"]
    /// `DestinationQuery.NEARBY_PREFIXES`.
    static let nearbyPrefixes = ["离我最近的", "离我最近", "距离我最近的", "最近的一家", "附近的一家", "我附近的", "我周围的",
                                 "我旁边的", "这附近的", "这周围的", "附近的", "附近", "周围的", "周围", "周边的", "周边",
                                 "最近的", "最近", "旁边的", "旁边", "就近的", "就近", "nearest", "nearby", "closest"]
    /// `ActionClaimGuard` media tables.
    static let mediaNouns = ["音乐", "歌", "曲"]
    static let genericMediaTokens = ICURegex("播放|音乐|歌曲|随便|随意|来点|来首|一下|一首|放|听|来|首|点|歌|曲|吧|我|想|要|给|帮|个|的|了|啊|呢|请|下")
    static let mediaPunctuation: Set<Character> = ["，", "。", "！", "？", "、", ",", ".", "!", "?", " ", "\t", "　"]
    static let temperatureOrFan: Set<String> = ["adjust_temperature", "set_temperature", "adjust_fan", "set_fan"]

    // MARK: Guards, in dispatch order

    /// A named song on `control_music{play}`: the bundled track is not what was asked (I-2).
    public static func unsupportedMedia(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "control_music", call.arguments["action"]?.stringValue == "play" else { return nil }
        return isSpecificMediaRequest(c.requestText) ? .mediaLibraryUnsupported : nil
    }

    /// 「打开天窗」 answered with `control_window` (P56): refuse, never a nearby action.
    public static func sunroofOnWindowTool(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "control_window", c.wordsAreCurrent else { return nil }
        let said = c.said
        guard unsupportedPartWords.contains(where: said.contains) else { return nil }
        let rest = unsupportedPartWords.reduce(said) { $0.replacingOccurrences(of: $1, with: "") }
        return windowWords.contains(where: rest.contains) || rest.contains("窗") ? nil : .unsupportedBodyPart
    }

    /// Mid-drive 「附近有加油站吗」 must not replace the route (P61).
    public static func nearbyQuestionWhileNavigating(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "navigate_to", c.navigating, c.wordsAreCurrent else { return nil }
        let said = c.said
        let destination = call.arguments["destination"]?.stringValue ?? ""
        let nearby = isNearbyRequest(said) || isNearbyRequest(destination) || onTheWay.matches(said)
        guard nearby, question.matches(said), !goIntent.matches(said) else { return nil }
        return .nearbyQuestionWhileNavigating
    }

    /// Mid-drive 「算了」 with no list open does not end the drive; only an explicit end does.
    public static func vagueExitWhileNavigating(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "exit_navigation_mode", c.guidanceRunning, !c.listOpen, c.wordsAreCurrent else { return nil }
        return isExplicitEnd(c.said) ? nil : .vagueExitWhileNavigating
    }

    /// Tools a guard lets run only because of the driver's words (allow-type). F-15a's start guard joins them.
    static let allowedByWordsOnly: Set<String> = ["set_speech_output"]

    /// F-05a §6: words that could not be read never count as permission. Block-type guards are not affected.
    public static func wordsUnclear(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard allowedByWordsOnly.contains(call.name), c.wordsAreCurrent, !c.wordsReliable else { return nil }
        return .wordsUnclear
    }

    /// `set_speech_output` runs only when this turn's words ask to stop or resume talking (P66).
    public static func speechOutputNotRequested(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "set_speech_output", c.wordsAreCurrent else { return nil }
        return isSpeechOutputRequest(c.said) ? nil : .speechOutputNotRequested
    }

    /// A relative change whose target nobody stated (「再低一点」 after seat and temperature). The
    /// resolver is F-10's `ContextResolver` (T-030); until it exists no call is refused here.
    public static func ambiguousReferent(_ call: ToolCall, _ c: GuardContext,
                                         clarify: (String) -> [String]?) -> (ToolErrorCode, [String])? {
        guard let action = call.arguments["action"]?.stringValue else { return nil }
        let relative = switch call.name {
        case "control_seat": action == "adjust_height"
        case "control_window": action == "adjust"
        default: action == "adjust_temperature" || action == "adjust_fan"
        }
        guard relative, c.wordsAreCurrent, let options = clarify(c.requestText), !options.isEmpty else { return nil }
        return (.ambiguousReferent, options)
    }

    /// 「我这边的窗户」 answered with `window=all` (P57): narrowed to `driver`. Returns the new window or nil.
    public static func driverSideWindow(_ call: ToolCall, _ c: GuardContext) -> String? {
        guard call.name == "control_window", c.wordsAreCurrent else { return nil }
        let window = call.arguments["window"]?.stringValue
        if let window, window != "all" { return nil }
        let said = c.said
        guard driverSide.contains(where: said.contains), !otherWindow.contains(where: said.contains) else { return nil }
        return "driver"
    }

    /// 「回家」 with no home saved: refuse rather than search for 家 (`savedPlaceMissing`).
    public static func savedPlaceMissing(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "navigate_to", let destination = call.arguments["destination"]?.stringValue,
              let saved = c.savedPlaces, let slot = PlaceSlot.slot(for: destination), !saved.contains(slot) else { return nil }
        return slot == .home ? .homeNotSet : .workNotSet
    }

    /// A temperature or fan change that succeeded with the climate off: say so, do not switch it on.
    public static func withPowerAdvice(_ call: ToolCall, _ result: ToolResult) -> ToolResult {
        guard result.ok, result.data["power_on"] == .bool(false),
              let action = call.arguments["action"]?.stringValue, temperatureOrFan.contains(action) else { return result }
        return ToolResult(ok: true, code: nil, data: result.data, advice: ToolFailureAdvice.climateOff)
    }

    // MARK: Text tests

    static func isExplicitEnd(_ text: String) -> Bool {
        let simplified = String(text.map { traditional[$0] ?? $0 })
        let said = navSound.replace(continueNav.replace(negatedEnd.replace(simplified, with: "#"), with: "#"), with: "#")
        return explicitNoNav.matches(said) || nounRefused.matches(said) || nearEnd.matches(said)
    }

    static func isSpeechOutputRequest(_ text: String) -> Bool {
        let said = String(text.map { speechTraditional[$0] ?? $0 })
        let letters = String(said.lowercased().filter { $0.isLetter || $0.isNumber })
        if shutUpWords.contains(letters) { return true }
        return stopTalking.matches(said) || resumeTalking.matches(said)
    }

    static func isNearbyRequest(_ spoken: String) -> Bool {
        let text = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        return nearbyPrefixes.contains(where: text.contains)
    }

    /// `ActionClaimGuard.isSpecificMediaRequest(text, mediaIntentKnown = true)`.
    static func isSpecificMediaRequest(_ text: String) -> Bool {
        guard mediaNouns.contains(where: text.contains) else { return false }
        return !genericMediaTokens.replace(text, with: "").filter { !mediaPunctuation.contains($0) }.isEmpty
    }
}

/// Small ICU-regex wrapper (Foundation only, as NovaCore allows).
struct ICURegex: @unchecked Sendable, Hashable {
    // NSRegularExpression is immutable and documented thread-safe.
    let pattern: String
    private let regex: NSRegularExpression

    init(_ pattern: String) {
        self.pattern = pattern
        // Patterns are compile-time constants covered by the guard tests; a bad one must fail loudly.
        // swiftlint:disable:next force_try
        regex = try! NSRegularExpression(pattern: pattern)
    }

    func matches(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    func replace(_ text: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    static func == (a: ICURegex, b: ICURegex) -> Bool { a.pattern == b.pattern }
    func hash(into h: inout Hasher) { h.combine(pattern) }
}
