import NovaPorts

/// F-05a §15 item 2 (T-016m): the language verdict on her reply text so far. Pure; the detector is injected.
/// Replaces the Latin pass of `ReplyLanguage.isNotAllowed`: a Latin-only reply must also be English.
public enum ReplyLanguageCheck {
    public enum Verdict: String, Sendable, Hashable {
        case allowed, blocked, undecided
    }

    /// Latin-only text at or above this many letters is judged by the detector while it still comes.
    static let longLatinLetters = 12
    /// While the reply comes: `en` at or above this is allowed; another top language at or above it is blocked.
    static let streamingProbability = 0.5
    /// At the end, Latin-only under 12 letters is blocked only for another top language at or above this.
    static let finalShortProbability = 0.8

    /// `text` is the whole reply so far; `final` is true at its end (`audioDone`), where `undecided` resolves.
    public static func verdict(_ text: String, final: Bool, detector: any LanguageIdentifier) -> Verdict {
        var hanKana = 0
        var latin = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic || ReplyLanguage.isKana(scalar) {
            if ReplyLanguage.isHan(scalar) || ReplyLanguage.isKana(scalar) {
                hanKana += 1
            } else if ReplyLanguage.isLatin(scalar) {
                latin += 1
            } else if scalar.properties.generalCategory != .nonspacingMark {
                return .blocked  // Hangul, Cyrillic, Devanagari…: at once, as before
            }
        }
        // Chinese or Japanese; Latin words inside them are allowed (「4S店」 at the end, 「OK，好的」).
        if hanKana >= 2 { return .allowed }
        let latinOnly = hanKana == 0 && latin > 0
        if latinOnly, latin >= longLatinLetters {
            let top = detector.hypotheses(text).first
            if let top, top.probability >= streamingProbability {
                return isEnglish(top) ? .allowed : .blocked
            }
            if !final { return .undecided }
        } else if !final {
            return .undecided
        }
        // The end of the reply: short Latin-only text is blocked only on a confident other language.
        if latinOnly, latin < longLatinLetters, let top = detector.hypotheses(text).first,
           !isEnglish(top), top.probability >= finalShortProbability {
            return .blocked
        }
        return .allowed
    }

    static func isEnglish(_ h: LanguageHypothesis) -> Bool { h.language == "en" || h.language.hasPrefix("en-") }
}

/// F-05a §15 item 7: the record and log lines of the language check. Codes and numbers only, never words (I-8).
public enum ReplyLanguageLine: Sendable, Hashable {
    public enum Reached: String, Sendable, Hashable { case allowed, blocked, released }
    public enum FallbackReason: String, Sendable, Hashable { case blockedAgain = "blocked_again", noReply = "no_reply" }

    /// `lang-check turn= verdict= lang= p= held_ms=`; `language` nil writes `none`.
    case check(turn: Int, verdict: Reached, language: String?, probability: Double, heldMs: Int)
    /// `correction WRONG_LANGUAGE heard=none` (F-05a §16 item 5: the re-ask never carries heard words).
    case correction
    /// `fallback-line turn= reason=`.
    case fallback(turn: Int, reason: FallbackReason)

    public var kind: String {
        switch self {
        case .check: "lang-check"
        case .correction: "correction"
        case .fallback: "fallback-line"
        }
    }

    public var fields: String {
        switch self {
        case .check(let turn, let verdict, let language, let p, let ms):
            "turn=\(turn) verdict=\(verdict.rawValue) lang=\(language.map(Self.code) ?? "none") p=\(Self.twoDecimals(p)) held_ms=\(ms)"
        case .correction: "WRONG_LANGUAGE heard=none"
        case .fallback(let turn, let reason): "turn=\(turn) reason=\(reason.rawValue)"
        }
    }

    /// The same line for `RuntimeLog`: the kind and the fields; no reply or driver words are in either.
    public var logLine: String { "\(kind) \(fields)" }

    /// A detector code is letters, digits and `-` only, so nothing else can reach a line.
    static func code(_ language: String) -> String {
        let kept = language.unicodeScalars.filter { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-" }
        let code = String(String.UnicodeScalarView(kept.prefix(16)))
        return code.isEmpty ? "none" : code
    }

    static func twoDecimals(_ p: Double) -> String {
        let hundredths = Int((min(max(p, 0), 1) * 100).rounded())
        return "\(hundredths / 100).\(hundredths % 100 < 10 ? "0" : "")\(hundredths % 100)"
    }
}
