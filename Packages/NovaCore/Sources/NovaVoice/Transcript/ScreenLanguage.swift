import NovaKit

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

    /// `text` is the whole text so far; `final` is true once no more of it will come.
    public static func check(_ text: String, final: Bool) -> Verdict {
        var han = false
        var latin = false
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            if TranscriptLanguage.isHan(scalar) || ReplyLanguage.isHan(scalar) {
                han = true
            } else if TranscriptLanguage.isLatin(scalar) {
                latin = true
            } else if scalar.properties.generalCategory != .nonspacingMark {
                return .hide  // Hangul, Kana, Cyrillic, Devanagari, Arabic, Thai…, even inside a Chinese sentence
            }
        }
        if han { return TranscriptLanguage.isChinese(text) || shortTokensOnly(text) ? .show : (final ? .hide : .wait) }
        if !latin { return .show }
        guard final else { return .wait }
        let kept = text.unicodeScalars.filter { !$0.properties.isWhitespace }
        let short = kept.count <= shortTokenLimit && kept.allSatisfy {
            ("A"..."Z").contains($0) || ("a"..."z").contains($0) || ("0"..."9").contains($0)
        }
        return short ? .show : .hide
    }

    /// Row 1 lists 「4S店」 as `show`, but `isChinese` fails it (one Han, one Latin word: 50 % < 60 %). So Han text
    /// also shows when every Latin run is a short token (at most 5 `A-Z` / `0-9`) and there are no more runs than
    /// Han characters (「4S店」, 「OK，好的」, 「去SM广场」).
    static func shortTokensOnly(_ text: String) -> Bool {
        var han = 0
        var runs: [Int] = []
        var inRun = false
        for scalar in text.unicodeScalars {
            if TranscriptLanguage.isHan(scalar) || ReplyLanguage.isHan(scalar) {
                han += 1
                inRun = false
            } else if ("A"..."Z").contains(scalar) || ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if inRun { runs[runs.count - 1] += 1 } else { runs.append(1) }
                inRun = true
            } else if scalar.properties.isAlphabetic {
                return false  // an accented or other Latin letter: not a short token
            } else {
                inRun = false
            }
        }
        return han > 0 && runs.count <= han && runs.allSatisfy { $0 <= shortTokenLimit }
    }

    /// The driver's line for final text: itself, or 「（没听清）」 when hidden.
    public static func driverLine(_ text: String) -> (line: String, hidden: Bool) {
        check(text, final: true) == .hide ? (unclearDriverLine, true) : (text, false)
    }

    /// The driver's line for the whole text so far: nil keeps the line as it is (`wait`).
    public static func driverDisplay(_ text: String, final: Bool) -> (line: String?, hidden: Bool) {
        switch check(text, final: final) {
        case .show: (text, false)
        case .wait: (nil, false)
        case .hide: (unclearDriverLine, true)
        }
    }

    /// The camera fallback sentence (F-20a), shown and spoken instead of a hidden answer.
    public static let cameraFallback = "刚才没看清楚，再问我一次吧。"

    /// The camera answer as shown and spoken: itself, or the fallback sentence when hidden.
    public static func cameraLine(_ answer: String) -> (line: String, hidden: Bool) {
        check(answer, final: true) == .hide ? (cameraFallback, true) : (answer, false)
    }

    /// Item 5: the record keeps the first 80 characters.
    public static func recordText(_ text: String) -> String { String(text.prefix(80)) }
}
