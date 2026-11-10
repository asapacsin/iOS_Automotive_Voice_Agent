import NovaKit
import NovaPorts

/// F-05a §13 items 1-2 (T-016i): the one check just before conversation text is shown. Pure, display only: it
/// never changes what the guards, the stop phrase, the echo filter or the tools read (item 3).
public enum ScreenLanguage {
    public enum Verdict: String, Sendable, Hashable {
        case show, wait, hide
    }

    /// What the driver's line shows instead of hidden text (item 2).
    public static let unclearDriverLine = "（没听清）"
    /// Final Latin-only text up to this many `A-Z` / `0-9` characters shows (`OK`, `4S`).
    static let shortTokenLimit = 5

    /// `text` is the whole text so far; `final` is true once no more of it will come. `language` is the utterance's
    /// (SenseVoice's for the driver, `replyLanguage` for her reply; F-05a §14 item 3).
    public static func check(_ text: String, final: Bool, language: SpokenLanguage? = nil) -> Verdict {
        var han = false
        var latin = false
        var kana = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic || ReplyLanguage.isKana(scalar) {
            if ReplyLanguage.isHan(scalar) {
                han = true
            } else if ReplyLanguage.isLatin(scalar) {
                latin = true
            } else if ReplyLanguage.isKana(scalar) {
                kana = true
            } else if scalar.properties.generalCategory != .nonspacingMark {
                return .hide  // Hangul, Cyrillic, Devanagari, Arabic, Thai…, even inside a Chinese sentence
            }
        }
        // §14 item 3: a line with Kana shows when final; not final, it waits.
        if kana { return final ? .show : .wait }
        if han { return TranscriptLanguage.isChinese(text) || shortTokensOnly(text) ? .show : (final ? .hide : .wait) }
        if !latin { return .show }
        guard final else { return .wait }
        // §14 item 3: a final Latin-only line of an English utterance shows at any length.
        if language == .en { return .show }
        let kept = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        return kept.count <= shortTokenLimit && kept.allSatisfy(isToken) ? .show : .hide
    }

    /// A short-token character: `A-Z` or `0-9`, half or full width. Lowercase is a word, not a token (`Hola`).
    static func isToken(_ s: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(s) || ("0"..."9").contains(s) || (0xFF21...0xFF3A).contains(s.value) || (0xFF10...0xFF19).contains(s.value)
    }

    /// Row 1 lists 「4S店」 as `show`, but `isChinese` fails it (one Han, one Latin word: 50 % < 60 %). So Han text
    /// also shows when every Latin run is a short token (at most 5 `A-Z` / `0-9`) and there are no more runs than
    /// Han characters (「4S店」, 「OK，好的」, 「去SM广场」).
    static func shortTokensOnly(_ text: String) -> Bool {
        var han = 0
        var runs: [Int] = []
        var inRun = false
        for scalar in text.unicodeScalars {
            if ReplyLanguage.isHan(scalar) {
                han += 1
                inRun = false
            } else if isToken(scalar) {
                if inRun { runs[runs.count - 1] += 1 } else { runs.append(1) }
                inRun = true
            } else if scalar.properties.isAlphabetic {
                return false  // a lowercase, accented or other letter: a word, not a short token
            } else {
                inRun = false
            }
        }
        return han > 0 && runs.count <= han && runs.allSatisfy { $0 <= shortTokenLimit }
    }

    /// §14 item 3: her reply's language from its text: Kana → ja; Latin letters with no Han → en; else nil.
    /// §15 item 6 (T-016m): Latin-only text is `en` only when `latinAllowed` (the reply's language verdict is allowed).
    public static func replyLanguage(_ text: String, latinAllowed: Bool = true) -> SpokenLanguage? {
        var han = false, latin = false
        for scalar in text.unicodeScalars {
            if ReplyLanguage.isKana(scalar) { return .ja }
            if ReplyLanguage.isHan(scalar) { han = true } else if scalar.properties.isAlphabetic && ReplyLanguage.isLatin(scalar) { latin = true }
        }
        return latin && !han && latinAllowed ? .en : nil
    }

    /// The driver's line for final text: itself, or 「（没听清）」 when hidden.
    public static func driverLine(_ text: String, language: SpokenLanguage? = nil) -> (line: String, hidden: Bool) {
        check(text, final: true, language: language) == .hide ? (unclearDriverLine, true) : (text, false)
    }

    /// The driver's line for the whole text so far; `wait` shows nothing yet.
    public static func driverDisplay(_ text: String, final: Bool, language: SpokenLanguage? = nil) -> (line: String?, hidden: Bool) {
        switch check(text, final: final, language: language) {
        case .show: (text, false)
        case .wait: ("", false)
        case .hide: (unclearDriverLine, true)
        }
    }

    /// The camera fallback sentence (F-20a), shown and spoken instead of a hidden answer.
    public static let cameraFallback = "刚才没看清楚，再问我一次吧。"

    /// The camera answer as shown and spoken: itself, or the fallback sentence when hidden.
    public static func cameraLine(_ answer: String) -> (line: String, hidden: Bool) {
        check(answer, final: true, language: replyLanguage(answer)) == .hide ? (cameraFallback, true) : (answer, false)
    }

    /// Item 5: the record keeps the first 80 characters.
    public static func recordText(_ text: String) -> String { String(text.prefix(80)) }
}
