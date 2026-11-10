#if canImport(NaturalLanguage)
import NaturalLanguage
import NovaPorts

/// F-05a §15 item 1 (T-016m): Apple's on-device `NLLanguageRecognizer`, no download. A new recognizer per call and
/// no `languageConstraints`, so a Portuguese or Spanish reply is reported as itself, never forced into en/zh/ja.
public struct AppleLanguageIdentifier: LanguageIdentifier {
    public init() {}

    public func hypotheses(_ text: String) -> [LanguageHypothesis] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: 3)
            .map { LanguageHypothesis(language: $0.key.rawValue, probability: $0.value) }
            .sorted { $0.probability != $1.probability ? $0.probability > $1.probability : $0.language < $1.language }
    }
}
#endif
