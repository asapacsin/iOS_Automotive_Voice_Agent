import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

/// A detector that answers from a table; unknown text has no guess.
struct FakeDetector: LanguageIdentifier {
    let answers: [String: LanguageHypothesis]
    init(_ answers: [String: (String, Double)] = [:]) {
        self.answers = answers.mapValues { LanguageHypothesis(language: $0.0, probability: $0.1) }
    }
    func hypotheses(_ text: String) -> [LanguageHypothesis] { answers[text].map { [$0] } ?? [] }
}

private func played(_ effects: [AgentEffect]) -> Int {
    effects.filter { if case .playReplyAudio = $0 { true } else { false } }.count
}

private func texts(_ effects: [AgentEffect]) -> [String] {
    effects.compactMap { if case .provider(.text(let turns, _)) = $0 { turns.last?.text } else { nil } }
}

private func lines(_ effects: [AgentEffect]) -> [ReplyLanguageLine] {
    effects.compactMap { if case .languageLine(let l) = $0 { l } else { nil } }
}

private func fallbacks(_ effects: [AgentEffect]) -> [String] {
    effects.compactMap { if case .speakGuidance(let text, _) = $0 { text } else { nil } }
}

@Suite("T-016m F-05a §15 her reply is checked for its language in code before she says it")
struct ReplyLanguageCheckTests {
    static let portuguese = "Tudo bem, em que posso ajudar você?"
    static let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])

    @Test("T-016m F-05a §15 row 1: Chinese, Japanese and Latin inside them are allowed; another script is blocked")
    func scripts() {
        let d = FakeDetector()
        #expect(ReplyLanguageCheck.verdict("现在是上午九点零一分。", final: false, detector: d) == .allowed)
        #expect(ReplyLanguageCheck.verdict("はい、22度です", final: false, detector: d) == .allowed)
        #expect(ReplyLanguageCheck.verdict("안녕하세요", final: false, detector: d) == .blocked)
        #expect(ReplyLanguageCheck.verdict("OK，好的", final: false, detector: d) == .allowed)
        // One Han letter is not yet two: 「4S店」 is decided at the end of the reply.
        #expect(ReplyLanguageCheck.verdict("4S店", final: false, detector: d) == .undecided)
        #expect(ReplyLanguageCheck.verdict("4S店", final: true, detector: d) == .allowed)
    }

    @Test("T-016m F-05a §15 row 2: Latin-only from 12 letters is judged by the detector while it comes")
    func longLatin() {
        let d = FakeDetector([Self.portuguese: ("pt", 0.9), "Sure, it's 22 degrees now": ("en", 0.9),
                              "Disculpa, no entendí": ("es", 0.8), "Hmm let me think": ("en", 0.4)])
        #expect(ReplyLanguageCheck.verdict(Self.portuguese, final: false, detector: d) == .blocked)
        #expect(ReplyLanguageCheck.verdict("Sure, it's 22 degrees now", final: false, detector: d) == .allowed)
        #expect(ReplyLanguageCheck.verdict("Disculpa, no entendí", final: false, detector: d) == .blocked)
        #expect(ReplyLanguageCheck.verdict("Hmm let me think", final: false, detector: d) == .undecided)
        #expect(ReplyLanguageCheck.verdict("Tudo bem", final: false, detector: d) == .undecided)  // under 12, still coming
    }

    @Test("T-016m F-05a §15 row 3: at the end, short Latin-only text is blocked only for another language at 0.8")
    func shortFinal() {
        let d = FakeDetector(["OK": ("en", 0.3), "Sure": ("en", 0.9), "Jardin": ("fr", 0.85), "Tudo bem": ("pt", 0.6)])
        #expect(ReplyLanguageCheck.verdict("OK", final: true, detector: d) == .allowed)
        #expect(ReplyLanguageCheck.verdict("Sure", final: true, detector: d) == .allowed)
        #expect(ReplyLanguageCheck.verdict("Jardin", final: true, detector: d) == .blocked)
        #expect(ReplyLanguageCheck.verdict("Tudo bem", final: true, detector: d) == .allowed)
    }

    /// Gemini 原声, connected, the local recognizer heard the driver say 「不知道。」.
    static func asked(_ detector: FakeDetector = FakeDetector([portuguese: ("pt", 0.9)]),
                      heard: String = "不知道。") -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false, languageIdentifier: detector)
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.send(.driverWords(.final(heard)))
        return d
    }

    @Test("T-016m F-05a §15 row 4: Portuguese after 200 ms of audio: nothing released, voided, one re-ask without heard words")
    func portugueseVoided() {
        var d = Self.asked()
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        #expect(played(d.realtime(.replyAudio(t, Self.pcm))) == 0)
        d.now = d.now + .milliseconds(200)
        let out = d.realtime(.replyText(t, Self.portuguese))
        #expect(played(out) == 0 && d.state.view.subtitle.isEmpty)
        #expect(out.contains { if case .flushPlayback = $0 { true } else { false } })  // the void
        // F-05a §16 item 5 (T-016n): the re-ask never carries the heard words.
        #expect(texts(out) == ["[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。请用中文简短地请司机再说一遍。"])
        #expect(lines(out).contains(.correction))
        #expect(lines(out).contains(.check(turn: 1, verdict: .blocked, language: "pt", probability: 0.9, heldMs: 200)))
        // Nothing of the voided turn plays later.
        #expect(played(d.realtime(.replyAudio(t, Self.pcm)) + d.realtime(.audioDone(t))) == 0)
    }

    @Test("T-016m F-05a §15 row 5: audio released when the Chinese text allows it, or at 800 ms with verdict=released")
    func hold() {
        var d = Self.asked()
        d.realtime(.responseStarted(TurnID(1)))
        #expect(played(d.realtime(.replyAudio(TurnID(1), Self.pcm))) == 0)
        d.now = d.now + .milliseconds(300)
        let allowed = d.realtime(.replyText(TurnID(1), "现在是上午九点。"))
        #expect(played(allowed) == 1)
        #expect(lines(allowed) == [.check(turn: 1, verdict: .allowed, language: nil, probability: 0, heldMs: 300)])
        d.realtime(.audioDone(TurnID(1)))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))

        var e = Self.asked()
        e.realtime(.responseStarted(TurnID(1)))
        #expect(played(e.realtime(.replyAudio(TurnID(1), Self.pcm))) == 0)
        let released = e.fire(.language)
        #expect(played(released) == 1)
        #expect(lines(released) == [.check(turn: 1, verdict: .released, language: nil, probability: 0, heldMs: 800)])
    }

    @Test("T-016m F-05a §15 row 6: blocked again or no reply in 6 s says the fallback line once; a new utterance cancels it")
    func fallbackLine() {
        // Blocked again.
        var d = Self.asked()
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.replyText(TurnID(1), Self.portuguese))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.realtime(.responseStarted(TurnID(2)))
        let again = d.realtime(.replyText(TurnID(2), Self.portuguese))
        #expect(fallbacks(again) == ["没听清，请再说一遍"])
        #expect(lines(again).contains(.fallback(turn: 2, reason: .blockedAgain)))
        #expect(d.state.view.subtitle == "没听清，请再说一遍")
        #expect(texts(again).isEmpty)  // no second re-ask
        d.realtime(.responseDone(TurnID(2), outcome: .completed))
        d.realtime(.responseStarted(TurnID(3)))
        #expect(fallbacks(d.realtime(.replyText(TurnID(3), Self.portuguese))).isEmpty)  // at most once
        #expect(fallbacks(d.fire(.fallback)).isEmpty)

        // No reply within 6 s.
        var e = Self.asked()
        e.realtime(.responseStarted(TurnID(1)))
        e.realtime(.replyText(TurnID(1), Self.portuguese))
        e.realtime(.responseDone(TurnID(1), outcome: .completed))
        let late = e.fire(.fallback)
        #expect(fallbacks(late) == ["没听清，请再说一遍"])
        #expect(lines(late) == [.fallback(turn: 1, reason: .noReply)])

        // A new utterance before 6 s.
        var f = Self.asked()
        f.realtime(.responseStarted(TurnID(1)))
        f.realtime(.replyText(TurnID(1), Self.portuguese))
        f.realtime(.responseDone(TurnID(1), outcome: .completed))
        f.send(.speechStarted(recentSpeech: true))
        f.send(.speechStopped)
        f.send(.driverWords(.final("现在几点")))
        #expect(fallbacks(f.fire(.fallback)).isEmpty)
    }

    @Test("T-016n F-05a §16 row 6 (§15 row 7): any utterance gets the second re-ask text exactly, heard=none")
    func reaskTexts() {
        let none = "[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。请用中文简短地请司机再说一遍。"
        #expect(CorrectionReason.wrongLanguage.instruction == none)
        var d = Self.asked()
        d.realtime(.responseStarted(TurnID(1)))
        let out = d.realtime(.replyText(TurnID(1), Self.portuguese))
        #expect(texts(out) == [none] && lines(out).contains(.correction))
        #expect(!texts(out)[0].contains("不知道"))
    }

    @Test("T-016m F-05a §15 row 8: record lines exactly as item 7, with no reply or driver words")
    func recordLines() {
        #expect(ReplyLanguageLine.check(turn: 7, verdict: .blocked, language: "pt", probability: 0.9, heldMs: 200).logLine
            == "lang-check turn=7 verdict=blocked lang=pt p=0.90 held_ms=200")
        #expect(ReplyLanguageLine.check(turn: 1, verdict: .released, language: nil, probability: 0, heldMs: 800).logLine
            == "lang-check turn=1 verdict=released lang=none p=0.00 held_ms=800")
        #expect(ReplyLanguageLine.check(turn: 2, verdict: .allowed, language: "zh-Hans", probability: 1, heldMs: 0).logLine
            == "lang-check turn=2 verdict=allowed lang=zh-Hans p=1.00 held_ms=0")
        #expect(ReplyLanguageLine.correction.logLine == "correction WRONG_LANGUAGE heard=none")
        #expect(ReplyLanguageLine.fallback(turn: 3, reason: .blockedAgain).logLine == "fallback-line turn=3 reason=blocked_again")
        #expect(ReplyLanguageLine.fallback(turn: 3, reason: .noReply).logLine == "fallback-line turn=3 reason=no_reply")
        var r = ConversationRecorder()
        #expect(r.add(.languageLine(.check(turn: 1, verdict: .allowed, language: "en", probability: 0.734, heldMs: 12)), atMs: 5)
            == ["5 lang-check turn=1 verdict=allowed lang=en p=0.73 held_ms=12"])
        // The lines of a whole blocked turn carry neither her words nor the driver's.
        var d = Self.asked()
        d.realtime(.responseStarted(TurnID(1)))
        let all = lines(d.realtime(.replyText(TurnID(1), Self.portuguese)) + d.fire(.fallback))
        #expect(!all.isEmpty)
        for l in all { #expect(!l.logLine.contains("Tudo") && !l.logLine.contains("不知道")) }
    }
}
