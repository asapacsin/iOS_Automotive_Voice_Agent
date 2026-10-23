import NovaKit

/// Local interception of listening-control phrases (F-02 §6), ported from `A/voice/ListeningIntent.kt`
/// (evidence batch 1, commit 9c53929). Whole utterances only: 「关闭小诺」 sleeps, 「关闭导航」 does not.
///
/// Precedence, highest first: a task command → model; sleep phrases; shut-up phrases; contextual
/// phrases (「不用了」「没事了」) sleep only when no picker is open and no task pends. 「算了」「取消」
/// are in no set, so they always reach the model.
public enum ListeningIntent: String, Sendable, Hashable, CaseIterable {
    case shutUp, goToSleep, passToModel

    public struct Context: Sendable, Hashable {
        /// A destination or route list waits for the driver's choice.
        public var pickerOpen: Bool
        /// A tool is still running or its result has not been answered yet.
        public var taskPending: Bool
        public init(pickerOpen: Bool = false, taskPending: Bool = false) {
            self.pickerOpen = pickerOpen
            self.taskPending = taskPending
        }
    }

    static let sleep: Set<String> = [
        "sleep", "gotosleep", "stoplistening", "thatsall", "thatisall",
        "休眠", "进入休眠", "小诺休眠", "睡觉", "去睡觉", "睡吧", "去睡吧", "小诺睡觉", "小诺睡吧",
        "关闭小诺", "小诺关闭", "关掉小诺", "别听了", "不要听了", "停止监听", "停止聆听",
        "休息吧", "小诺休息吧", "你休息吧", "去休息吧", "小诺休息",
    ]
    static let shutUpPhrases: Set<String> = [
        "shutup", "bequiet", "keepquiet", "keepsilent", "staysilent", "stoptalking", "silence", "quiet",
        "闭嘴", "小诺闭嘴", "安静", "安静点", "安静一点", "保持安静", "别说话", "不要说话", "别出声", "不要出声",
        "别吵", "别吵了", "少说话", "别说了", "不要说了", "别讲了", "不要讲了",
    ]
    /// Could also mean "cancel this task"; they end listening only when no task could consume them.
    static let contextual: Set<String> = ["close", "nevermind", "不用了", "不需要了", "没事了"]
    static let politeSuffixes = ["谢谢你", "谢谢", "thanks", "thankyou", "please", "now", "吧", "啦", "了", "啊", "一下"]
    static let politePrefixes = ["你好小诺", "小诺", "好的", "好", "ok", "okay", "hey"]
    static let fillers = Set("嗯啊哦呃额唔哈呀噢喔诶欸ummhah")

    public static func classify(_ utterance: String, context: Context = Context()) -> ListeningIntent {
        let phrase = normalise(utterance)
        if phrase.isEmpty { return .passToModel }
        if matches(phrase, sleep) { return .goToSleep }
        if matches(phrase, shutUpPhrases) { return .shutUp }
        if matches(phrase, contextual) {
            return context.pickerOpen || context.taskPending ? .passToModel : .goToSleep
        }
        return .passToModel
    }

    /// A user turn that counts as activity for the inactivity timer; 「嗯」 or noise does not.
    public static func isMeaningful(_ utterance: String) -> Bool {
        let p = normalise(utterance)
        return p.count >= 2 && p.contains { !fillers.contains($0) }
    }

    /// Also tries the phrase with a leading address / trailing courtesy removed (「小诺，别听了吧」).
    static func matches(_ phrase: String, _ set: Set<String>) -> Bool {
        if set.contains(phrase) { return true }
        var p = phrase
        if let prefix = politePrefixes.first(where: { p.hasPrefix($0) && p.count > $0.count }) {
            p = String(p.dropFirst(prefix.count))
        }
        if set.contains(p) { return true }
        for _ in 0..<2 {
            if politeSuffixes.contains(where: { p.hasSuffix($0) && p.count > $0.count && set.contains(String(p.dropLast($0.count))) }) {
                return true
            }
            if let suffix = politeSuffixes.first(where: { p.hasSuffix($0) && p.count > $0.count }) {
                p = String(p.dropLast(suffix.count))
            }
            if set.contains(p) { return true }
        }
        return false
    }

    /// Lower-cased letters and digits only (`’` and `'` dropped).
    static func normalise(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
