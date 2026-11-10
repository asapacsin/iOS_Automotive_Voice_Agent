import NovaPorts

/// F-05a §15 item 2 (T-016m): the verdict on her reply text so far. Pure; the detector is injected. Replaces the
/// Latin pass of `ReplyLanguage.isNotAllowed`: Latin text must be English by the detector, not just by its script.
public enum ReplyLanguageCheck {
    public enum Verdict: String, Sendable, Hashable {
        case allowed, blocked, undecided
    }

    public struct Result: Sendable, Hashable {
        public let verdict: Verdict
        /// The detector's top hypothesis (nil: none, or not asked).
        public let language: String?
        public let probability: Double
    }

    /// Latin-only text of at least this many letters is judged while it is still coming.
    public static let latinLetters = 12
    /// Long Latin text: the top hypothesis decides at this probability.
    public static let longProbability = 0.5
    /// Short Latin text at the end of the reply: blocked only when another language is this likely.
    public static let shortProbability = 0.8

    /// `text` is the whole reply text so far; `final` is true at `audioDone` (nothing more comes).
    public static func check(_ text: String, final: Bool, detector: any LanguageIdentifier) -> Result {
        var cjk = 0
        var latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic || ReplyLanguage.isKana(scalar) {
            if ReplyLanguage.isHan(scalar) || ReplyLanguage.isKana(scalar) {
                cjk += 1
            } else if ReplyLanguage.isLatin(scalar) {
                latin += 1
            } else if scalar.properties.generalCategory != .nonspacingMark {
                return Result(verdict: .blocked, top: top(text, detector))  // Hangul, Cyrillic, …: at once
            }
        }
        if cjk >= 2 { return Result(verdict: .allowed, top: top(text, detector)) }
        guard cjk == 0, latin > 0 else {
            // One Han or Kana letter (「4S店」 so far), or no letters yet: wait; at the end it is allowed.
            return Result(verdict: final ? .allowed : .undecided, top: final ? top(text, detector) : nil)
        }
        let best = top(text, detector)
        let english = best?.language == "en"
        let p = best?.probability ?? 0
        if latin >= latinLetters {
            if p >= longProbability { return Result(verdict: english ? .allowed : .blocked, top: best) }
            return Result(verdict: final ? .allowed : .undecided, top: best)
        }
        guard final else { return Result(verdict: .undecided, top: best) }
        return Result(verdict: !english && p >= shortProbability ? .blocked : .allowed, top: best)
    }

    private static func top(_ text: String, _ detector: any LanguageIdentifier) -> LanguageHypothesis? {
        detector.hypotheses(text).max { $0.probability < $1.probability }
    }
}

extension ReplyLanguageCheck.Result {
    init(verdict: ReplyLanguageCheck.Verdict, top: LanguageHypothesis?) {
        self.init(verdict: verdict, language: top?.language, probability: top?.probability ?? 0)
    }
}
