import NovaPorts

/// F-08 §14 item 1 (T-022a): the fixed stop set, listed once. The keyword spotter gets `keywordsFile`; the
/// transcript check (`ListeningIntent`) adds the same texts to its shut-up phrases. Changing it is a spec change.
public enum StopPhrases {
    public struct Phrase: Sendable, Hashable {
        public let text: String
        /// sherpa-onnx Mandarin KWS tokens: pinyin initials and tone-marked finals, space separated.
        public let tokens: [String]
    }

    public static let all: [Phrase] = [
        Phrase(text: "别说了", tokens: ["b", "ié", "sh", "uō", "l", "e"]),
        Phrase(text: "不要说了", tokens: ["b", "ù", "y", "ào", "sh", "uō", "l", "e"]),
        Phrase(text: "别说啦", tokens: ["b", "ié", "sh", "uō", "l", "a"]),
        Phrase(text: "停", tokens: ["t", "íng"]),
        // 一 before a fourth tone is read yí.
        Phrase(text: "停一下", tokens: ["t", "íng", "y", "í", "x", "ià"]),
        Phrase(text: "闭嘴", tokens: ["b", "ì", "z", "uǐ"]),
        Phrase(text: "安静", tokens: ["ān", "j", "ìng"]),
    ]

    /// Mandarin initials of the KWS token set; every other token must be a final with its tone mark (or neutral).
    public static let initials: Set<String> = [
        "b", "p", "m", "f", "d", "t", "n", "l", "g", "k", "h", "j", "q", "x", "zh", "ch", "sh", "r", "z", "c", "s", "y", "w",
    ]

    /// One line per phrase, `tokens @label`, the label being the phrase's index (sherpa-onnx keywords file).
    public static var keywordsFile: String {
        all.enumerated().map { "\($0.element.tokens.joined(separator: " ")) @\($0.offset)" }.joined(separator: "\n") + "\n"
    }

    /// The index of a whole-utterance stop phrase, for the log; nil for the transcript check's extra phrases.
    public static func index(of utterance: String) -> Int? {
        let phrase = ListeningIntent.normalise(utterance)
        return all.firstIndex { $0.text == phrase }
    }
}

/// F-08 §14 item 2: the on-phone keyword spotter (sherpa-onnx `KeywordSpotter` in NovaAsrSherpa).
public protocol StopPhraseSpotter: AnyObject {
    /// One capture frame; a hit when a stop phrase ended in it.
    func accept(_ frame: PCMFrame16k) -> StopPhraseHit?
    /// The playback window closed: forget the stream.
    func reset()
}

public struct StopPhraseHit: Sendable, Hashable {
    /// Index into `StopPhrases.all`.
    public let phrase: Int
    /// The spotter's confidence, 0–100, for the log.
    public let score: Int
    public init(phrase: Int, score: Int) {
        self.phrase = phrase
        self.score = score
    }
}

/// F-08 §14 item 3: the spotter hears frames only inside the gate's stop-phrase window (her reply plus its echo
/// tail); outside it, it is not fed and cannot fire.
public struct StopPhraseFeeder: Sendable {
    private var open = false
    public init() {}

    public mutating func frame(_ frame: PCMFrame16k, inWindow: Bool, spotter: any StopPhraseSpotter) -> StopPhraseHit? {
        guard inWindow else {
            if open { spotter.reset() }
            open = false
            return nil
        }
        open = true
        return spotter.accept(frame)
    }
}
