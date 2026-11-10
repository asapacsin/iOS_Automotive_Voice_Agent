/// F-05a §15 item 1 (T-016m): one language guess for a text, a BCP-47 code (`en`, `pt`, `zh-Hans`) and its probability.
public struct LanguageHypothesis: Sendable, Hashable {
    public let language: String
    public let probability: Double

    public init(language: String, probability: Double) {
        self.language = language
        self.probability = probability
    }
}

/// F-05a §15 item 1: the on-device language detector (adapter `AppleLanguageIdentifier` in NovaPlatform, Apple's
/// `NLLanguageRecognizer` with no constraints). Injected, so NovaCore stays pure and the tests use a fake.
public protocol LanguageIdentifier: Sendable {
    /// At most 3 hypotheses, most probable first; empty when the detector has no guess.
    func hypotheses(_ text: String) -> [LanguageHypothesis]
}

/// No detector: no guess for any text (unit tests that do not need one, and before the app injects one).
public struct NoLanguageIdentifier: LanguageIdentifier {
    public init() {}
    public func hypotheses(_ text: String) -> [LanguageHypothesis] { [] }
}
