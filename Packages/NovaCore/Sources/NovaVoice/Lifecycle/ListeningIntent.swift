import NovaKit

/// Local phrase classification (F-02 §6, `A/voice/ListeningIntent.kt:21`). Only a whole utterance
/// matches: 「闭嘴吧，我想问个问题」 goes to the model. 「算了/取消」 are never intercepted.
public enum ListeningIntent: String, Sendable, Hashable, CaseIterable {
    case shutUp, goToSleep, passToModel

    /// What is open around the utterance. Session-ending phrases reach the model while either holds.
    public struct Context: Sendable, Hashable {
        public var pickerOpen: Bool
        public var taskPending: Bool
        public init(pickerOpen: Bool = false, taskPending: Bool = false) {
            self.pickerOpen = pickerOpen
            self.taskPending = taskPending
        }
    }

    /// Phrases from the spec. The full Android phrase table is an open EVIDENCE_REQUEST (STATUS.md).
    static let shutUpPhrases: Set<String> = ["闭嘴"]
    static let sleepPhrases: Set<String> = ["休眠", "停止监听"]
    /// Never intercepted, in any context (contracts/voice-agent.md §2).
    static let cancelPhrases: Set<String> = ["算了", "取消"]

    public static func classify(_ utterance: String, context: Context = Context()) -> ListeningIntent {
        let text = stripped(utterance)
        if cancelPhrases.contains(text) { return .passToModel }
        let core = withoutTrailingParticles(text)
        // 「闭嘴」 only stops her voice, so it stays local even while a choice is open.
        if shutUpPhrases.contains(core) { return .shutUp }
        // Sleeping would drop an open picker or pending task, so then the model decides.
        if sleepPhrases.contains(core) { return context.isBusyWithChoice ? .passToModel : .goToSleep }
        return .passToModel
    }

    /// Drops whitespace and punctuation (「闭嘴！」 -> 「闭嘴」).
    static func stripped(_ utterance: String) -> String {
        String(String.UnicodeScalarView(utterance.unicodeScalars.filter { !ignorable($0) })).lowercased()
    }

    /// 「休眠吧」 -> 「休眠」. Applied only after the cancel check, so 「算了」 is never shortened.
    static func withoutTrailingParticles(_ text: String) -> String {
        var scalars = Array(text.unicodeScalars)
        while scalars.count > 2, let last = scalars.last, trailingParticles.contains(last) { scalars.removeLast() }
        return String(String.UnicodeScalarView(scalars))
    }

    private static let trailingParticles: Set<Unicode.Scalar> = ["吧", "啊", "呀", "了", "啦"]

    private static func ignorable(_ s: Unicode.Scalar) -> Bool {
        s.properties.isWhitespace || s.properties.generalCategory.isPunctuation
    }
}

extension ListeningIntent.Context {
    /// While a picker is open or a task pends, a short command is about that choice, not the session.
    var isBusyWithChoice: Bool { pickerOpen || taskPending }
}

private extension Unicode.GeneralCategory {
    var isPunctuation: Bool {
        switch self {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation, .mathSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}
