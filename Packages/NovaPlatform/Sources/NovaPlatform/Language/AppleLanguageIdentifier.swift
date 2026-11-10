import NaturalLanguage
import NovaPorts

/// F-05a §15 item 1 (T-016m): her reply's language from Apple's on-device `NLLanguageRecognizer`. A new recognizer
/// per call (none is shared across threads), no `languageConstraints`, so Portuguese is reported as `pt`, not
/// forced to one of the allowed languages. Codes are BCP-47 (`en`, `pt`, `zh-Hans`).
public struct AppleLanguageIdentifier: LanguageIdentifier {
    public init() {}

    public func hypotheses(_ text: String) -> [LanguageHypothesis] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
            .map { LanguageHypothesis(language: $0.key.rawValue, probability: $0.value) }
            .sorted { $0.probability > $1.probability }
    }
}
