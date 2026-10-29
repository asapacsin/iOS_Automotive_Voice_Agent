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

/// What the guards may read, all of it inside AgentCore (ios-architecture §8): app state and timing. F-05a §6
/// (owner rule 2026-10-29): **never the driver's transcript** — Gemini hears the audio and its tool call is the
/// decision; the transcript is for the screen only.
public struct GuardContext: Sendable, Hashable {
    /// Speech onsets so far: the driver turn being answered (repeat-in-turn); 0 before the first.
    public var turn: Int
    /// Utterances the uplink gate closed so far (F-04a `activityEnd`), counted from audio, never from text.
    public var closedTurns: Int
    public var now: NovaInstant
    /// `navigatingNow()`: a route is being driven.
    public var navigating: Bool
    /// `guidanceRunningNow()`: guidance itself runs (no pre-guidance phase).
    public var guidanceRunning: Bool
    /// A destination or route list waits for a choice.
    public var listOpen: Bool
    /// Saved places that are set (`SavedPlaces`); nil when AgentCore does not know them, in which case
    /// the navigation executor decides 家/公司 itself from the store.
    public var savedPlaces: Set<PlaceSlot>?
    /// F-15a §2.5: the route list is on screen (`awaitingRouteSelection`): a pick there starts guidance.
    public var routeChoiceOpen: Bool
    /// `closedTurns` when the route list appeared.
    public var routeListTurn: Int
    /// The call came from a tap on the screen (I-6): the tap itself is the request.
    public var fromTap: Bool

    public init(turn: Int = 0, closedTurns: Int = 0, now: NovaInstant = .zero, navigating: Bool = false,
                guidanceRunning: Bool = false, listOpen: Bool = false, savedPlaces: Set<PlaceSlot>? = nil,
                routeChoiceOpen: Bool = false, routeListTurn: Int = 0, fromTap: Bool = false) {
        self.turn = turn
        self.closedTurns = closedTurns
        self.now = now
        self.navigating = navigating
        self.guidanceRunning = guidanceRunning
        self.listOpen = listOpen
        self.savedPlaces = savedPlaces
        self.routeChoiceOpen = routeChoiceOpen
        self.routeListTurn = routeListTurn
        self.fromTap = fromTap
    }
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

/// Whether a validated call may run (F-09, revised by F-05a §6). Each returns a code, or nil to let the call
/// through. Code, not prompt (I-11). The Android guards that read the driver's words (P56 sunroof, P57 driver-side
/// window, P61 nearby question, P66 speech output, vague exit, ambiguous referent, named media) are superseded:
/// a bad transcript must not veto a correct call. What they protected now comes from arguments, state and timing:
/// a named song cannot reach `control_music` (its only field is `action`; `play_music` takes titles), sunroof and
/// the other parts have no tool, a place asked for while guiding is listed over the route (NavigationController),
/// and ending the guidance runs on the call with no confirmation (T-016e).
public enum ToolCallGuards {
    static let temperatureOrFan: Set<String> = ["adjust_temperature", "set_temperature", "adjust_fan", "set_fan"]

    /// F-15a §2.5 (revised): a pick on the route list starts guidance only in a later driver turn than the one in
    /// which the list appeared, so the model chaining "pick destination → pick route" without the driver speaking
    /// again starts nothing. Turns are counted by the uplink gate, never from text. Taps are never refused (I-6).
    public static func navigationNotRequested(_ call: ToolCall, _ c: GuardContext) -> ToolErrorCode? {
        guard call.name == "choose_navigation_option", c.routeChoiceOpen, !c.fromTap else { return nil }
        return c.closedTurns > c.routeListTurn ? nil : .navigationNotRequested
    }

    /// 「回家」 with no home saved: refuse rather than search for 家 (`savedPlaceMissing`). Reads the argument.
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
