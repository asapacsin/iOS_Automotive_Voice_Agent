import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

/// A detector with fixed answers: the top hypothesis for each exact text (prefixes of a streamed text included).
struct FakeLanguageIdentifier: LanguageIdentifier {
    var answers: [String: (String, Double)] = [:]
    func hypotheses(_ text: String) -> [LanguageHypothesis] {
        guard let (code, p) = answers[text] else { return [] }
        return [LanguageHypothesis(language: code, probability: p)]
    }
}

@Suite("T-016m F-05a §15 her reply's language is checked in code")
struct ReplyLanguageCheckTests {
    static func verdict(_ text: String, final: Bool, _ answer: (String, Double)? = nil) -> ReplyLanguageCheck.Verdict {
        let fake = FakeLanguageIdentifier(answers: answer.map { [text: $0] } ?? [:])
        return ReplyLanguageCheck.check(text, final: final, detector: fake).verdict
    }

    @Test("T-016m row 1: Chinese, Japanese, Hangul, 「4S店」, 「OK，好的」 → allowed, allowed, blocked, allowed, allowed")
    func scripts() {
        #expect(Self.verdict("现在是上午九点零一分。", final: false) == .allowed)
        #expect(Self.verdict("はい、22度です", final: false) == .allowed)
        #expect(Self.verdict("안녕하세요", final: false) == .blocked)
        #expect(Self.verdict("안", final: false) == .blocked)  // at the first letter
        #expect(Self.verdict("4S店", final: true) == .allowed)
        #expect(Self.verdict("4S店", final: false) == .undecided)  // one Han letter: waits for more or the end
        #expect(Self.verdict("OK，好的", final: false) == .allowed)
    }

    @Test("T-016m row 2: Latin-only, 12+ letters: pt 0.9 blocked; en 0.9 allowed; es 0.8 blocked; en 0.4 undecided")
    func longLatin() {
        #expect(Self.verdict("Tudo bem, em que posso ajudar você?", final: false, ("pt", 0.9)) == .blocked)
        #expect(Self.verdict("Sure, it's 22 degrees now", final: false, ("en", 0.9)) == .allowed)
        #expect(Self.verdict("Disculpa, no entendí", final: false, ("es", 0.8)) == .blocked)
        #expect(Self.verdict("Sure, it's 22 degrees now", final: false, ("en", 0.4)) == .undecided)
        #expect(Self.verdict("Tudo bem, em que posso ajudar você?", final: false, ("pt", 0.4)) == .undecided)
        // At the end, an undecided long text is allowed.
        #expect(Self.verdict("Sure, it's 22 degrees now", final: true, ("en", 0.4)) == .allowed)
        // Under 12 letters, still coming: undecided whatever the detector says.
        #expect(Self.verdict("Tudo bem", final: false, ("pt", 0.99)) == .undecided)
    }

    @Test("T-016m row 3: final, under 12 letters: OK en 0.3 allowed; Sure en 0.9 allowed; Jardin fr 0.85 blocked; Tudo bem pt 0.6 allowed")
    func shortLatin() {
        #expect(Self.verdict("OK", final: true, ("en", 0.3)) == .allowed)
        #expect(Self.verdict("Sure", final: true, ("en", 0.9)) == .allowed)
        #expect(Self.verdict("Jardin", final: true, ("fr", 0.85)) == .blocked)
        #expect(Self.verdict("Tudo bem", final: true, ("pt", 0.6)) == .allowed)
        #expect(Self.verdict("OK", final: true) == .allowed)  // no detector answer
    }

    static func harness(_ answers: [String: (String, Double)] = [:], streamsCleanAudio: Bool = true) -> PipelineHarness {
        var h = PipelineHarness()
        h.pipeline = DriverTurnPipeline(streamsCleanAudio: streamsCleanAudio,
                                        languageIdentifier: FakeLanguageIdentifier(answers: answers))
        return h
    }

    static let pcm = PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])
    static let portuguese = "Tudo bem, em que posso ajudar você?"

    static func audio(_ out: [PipelineOutput]) -> Int { out.filter { if case .speechAudio = $0 { true } else { false } }.count }
    static func reasks(_ out: [PipelineOutput]) -> [String] { out.compactMap { if case .languageReask(let s, _) = $0 { s } else { nil } } }
    static func fallbacks(_ out: [PipelineOutput]) -> Int { out.filter { if case .fallbackLine = $0 { true } else { false } }.count }
    static func langChecks(_ out: [PipelineOutput]) -> [String] {
        out.compactMap { if case .diagnostic(let e) = $0, case .langCheck = e { e.logLine } else { nil } }
    }

    /// The driver's utterance with SenseVoice's final, then her turn.
    static func asked(_ h: inout PipelineHarness, _ words: String = "不知道。", language: SpokenLanguage? = .zh) {
        h.send(.driverUtterance(words, language: language))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
    }

    @Test("T-016m row 4: Portuguese text after 200 ms of audio: no audio released, voided, one WRONG_LANGUAGE with the SenseVoice words and 中文")
    func portugueseVoided() {
        var h = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&h)
        let t = h.turn
        var out = h.send(.replyAudio(t, Self.pcm))
        h.advance(by: .milliseconds(100))
        out += h.send(.replyAudio(t, Self.pcm))
        h.advance(by: .milliseconds(100))
        out += h.send(.replyText(t, Self.portuguese))
        out += h.send(.replyAudio(t, Self.pcm))
        out += h.send(.audioDone(t))
        #expect(Self.audio(h.out) == 0 && h.spoken.isEmpty)
        #expect(out.contains(.voided(t)))
        #expect(Self.reasks(h.out) == ["[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。司机刚才说的是「不知道。」。请用中文回答这句话。"])
        #expect(Self.langChecks(h.out) == ["lang-check turn=1 verdict=blocked lang=pt p=0.90 held_ms=200"])
        #expect(h.out.contains(.diagnostic(.wrongLanguage(heard: true))))
        // Sent at once: no correction grace timer, and no NOT_MANDARIN.
        #expect(h.corrections.isEmpty && h.timers[.correction] == nil)
    }

    @Test("T-016m row 5: Chinese text 300 ms after the first audio releases it; no text for 800 ms releases it with verdict=released")
    func holdAndRelease() {
        var h = Self.harness()
        Self.asked(&h)
        let t = h.turn
        #expect(Self.audio(h.send(.replyAudio(t, Self.pcm))) == 0)
        h.advance(by: .milliseconds(300))
        let allowed = h.send(.replyText(t, "现在是上午九点。"))
        #expect(Self.audio(allowed) == 1 && h.spoken == "现在是上午九点。")
        #expect(Self.audio(h.send(.replyAudio(t, Self.pcm))) == 1)
        #expect(Self.langChecks(h.out) == ["lang-check turn=1 verdict=allowed lang=none p=0.00 held_ms=300"])

        var g = Self.harness()
        Self.asked(&g)
        let u = g.turn
        g.send(.replyAudio(u, Self.pcm))
        g.advance(by: .milliseconds(799))
        #expect(Self.audio(g.out) == 0)
        g.advance(by: .milliseconds(1))
        #expect(Self.audio(g.out) == 1)
        #expect(Self.langChecks(g.out) == ["lang-check turn=1 verdict=released lang=none p=0.00 held_ms=800"])
        // The check goes on: a later Hangul letter cuts her (voided), and no second lang-check line.
        let later = g.send(.replyText(u, "안녕"))
        #expect(later.contains(.voided(u)) && Self.langChecks(g.out).count == 1)
    }

    @Test("T-016m row 6: re-ask blocked again → one fallback line; re-ask with no reply for 6 s → one; a new utterance before 6 s → none")
    func fallback() {
        // Blocked again.
        var h = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&h)
        h.send(.replyText(h.turn, Self.portuguese))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.send(.replyText(h.turn, Self.portuguese))
        #expect(Self.fallbacks(h.out) == 1 && Self.reasks(h.out).count == 1)
        #expect(h.out.contains(.fallbackLine("没听清，请再说一遍")))
        #expect(h.out.contains(.diagnostic(.fallbackLine(turn: 2, reason: .blockedAgain))))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.send(.replyText(h.turn, "안녕"))
        h.advance(by: .seconds(10))
        #expect(Self.fallbacks(h.out) == 1)  // once per utterance

        // No reply within 6 s of the re-ask.
        var g = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&g)
        g.send(.replyText(g.turn, Self.portuguese))
        g.advance(by: .milliseconds(5_999))
        #expect(Self.fallbacks(g.out) == 0)
        g.advance(by: .milliseconds(1))
        #expect(Self.fallbacks(g.out) == 1 && g.out.contains(.diagnostic(.fallbackLine(turn: 1, reason: .noReply))))
        g.advance(by: .seconds(10))
        #expect(Self.fallbacks(g.out) == 1)

        // A new driver utterance before 6 s cancels it.
        var n = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&n)
        n.send(.replyText(n.turn, Self.portuguese))
        n.advance(by: .seconds(3))
        Self.asked(&n, "现在几点")
        n.advance(by: .seconds(10))
        #expect(Self.fallbacks(n.out) == 0)

        // A reply after the re-ask that is allowed stops the no-reply clock.
        var a = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&a)
        a.send(.replyText(a.turn, Self.portuguese))
        a.turn = a.turn.next()
        a.send(.turnOpened(a.turn))
        a.send(.replyText(a.turn, "不知道也没关系。"))
        a.advance(by: .seconds(10))
        #expect(Self.fallbacks(a.out) == 0)
    }

    @Test("T-016m row 7: the re-ask texts: 「不知道。」 zh; en 「What time is it」; no SenseVoice final")
    func reaskTexts() {
        let head = "[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。"
        #expect(CorrectionReason.wrongLanguage(heard: "不知道。", language: .zh) == head + "司机刚才说的是「不知道。」。请用中文回答这句话。")
        #expect(CorrectionReason.wrongLanguage(heard: "What time is it", language: .en) == head + "司机刚才说的是「What time is it」。请用英文回答这句话。")
        #expect(CorrectionReason.wrongLanguage(heard: "今何時ですか", language: .ja) == head + "司机刚才说的是「今何時ですか」。请用日语回答这句话。")
        #expect(CorrectionReason.wrongLanguage(heard: nil, language: nil) == head + "请用中文简短地请司机再说一遍。")
        #expect(CorrectionReason.wrongLanguage(heard: "안녕", language: .other) == head + "请用中文简短地请司机再说一遍。")
        #expect(CorrectionReason.wrongLanguage.instruction == head + "请用中文简短地请司机再说一遍。")

        // Through the pipeline: English words; then no SenseVoice final (Gemini's transcript only).
        var h = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&h, "What time is it", language: .en)
        h.send(.replyText(h.turn, Self.portuguese))
        #expect(Self.reasks(h.out) == [head + "司机刚才说的是「What time is it」。请用英文回答这句话。"])
        var g = Self.harness([Self.portuguese: ("pt", 0.9)])
        Self.asked(&g, "早安", language: nil)
        g.send(.replyText(g.turn, Self.portuguese))
        #expect(Self.reasks(g.out) == [head + "请用中文简短地请司机再说一遍。"])
        #expect(g.out.contains(.diagnostic(.wrongLanguage(heard: false))))
        // The same words reported again before the reply keep SenseVoice's final.
        var s = Self.harness([Self.portuguese: ("pt", 0.9)])
        s.send(.driverUtterance("不知道。", language: .zh))
        Self.asked(&s, "不知道。", language: nil)
        s.send(.replyText(s.turn, Self.portuguese))
        #expect(Self.reasks(s.out).first?.contains("「不知道。」") == true)
    }

    @Test("T-016m row 8: the diagnostic lines are exactly as item 7, with no words")
    func lines() {
        #expect(DiagnosticEvent.langCheck(turn: 3, verdict: .blocked, lang: LanguageTag("pt"), percent: 90, heldMs: 200).logLine
                == "lang-check turn=3 verdict=blocked lang=pt p=0.90 held_ms=200")
        #expect(DiagnosticEvent.langCheck(turn: 4, verdict: .released, lang: nil, percent: 0, heldMs: 800).logLine
                == "lang-check turn=4 verdict=released lang=none p=0.00 held_ms=800")
        #expect(DiagnosticEvent.langCheck(turn: 5, verdict: .allowed, lang: LanguageTag("zh-Hans"), percent: 100, heldMs: 12).logLine
                == "lang-check turn=5 verdict=allowed lang=zh-Hans p=1.00 held_ms=12")
        #expect(DiagnosticEvent.wrongLanguage(heard: true).logLine == "correction WRONG_LANGUAGE heard=sensevoice")
        #expect(DiagnosticEvent.wrongLanguage(heard: false).logLine == "correction WRONG_LANGUAGE heard=none")
        #expect(DiagnosticEvent.fallbackLine(turn: 9, reason: .blockedAgain).logLine == "fallback-line turn=9 reason=blocked_again")
        #expect(DiagnosticEvent.fallbackLine(turn: 9, reason: .noReply).logLine == "fallback-line turn=9 reason=no_reply")
        // Only a code can be a tag: words are not.
        #expect(LanguageTag("Tudo bem") == nil && LanguageTag("不知道") == nil && LanguageTag("") == nil)
        #expect(LanguageTag.probability(5) == "0.05" && LanguageTag.probability(85) == "0.85")
    }

    @Test("T-016m item 6: a Latin-only reply is English on screen only when allowed")
    func screen() {
        #expect(ScreenLanguage.replyLanguage("Sure, it's 22 degrees now") == .en)
        #expect(ScreenLanguage.replyLanguage("Sure, it's 22 degrees now", latinAllowed: false) == nil)
        #expect(ScreenLanguage.check("Sure, it's 22 degrees now", final: true,
                                     language: ScreenLanguage.replyLanguage("Sure, it's 22 degrees now", latinAllowed: false)) == .hide)
    }

    @Test("T-016m item 3: with a Qwen or Azure voice (no audio), the text is held for the verdict too")
    func revoicedText() {
        var h = Self.harness([Self.portuguese: ("pt", 0.9)], streamsCleanAudio: false)
        Self.asked(&h)
        h.send(.replyText(h.turn, "Tudo"))
        #expect(h.spoken.isEmpty)
        h.send(.replyText(h.turn, " bem, em que posso ajudar você?"))
        #expect(h.spoken.isEmpty && h.out.contains(.voided(h.turn)))
    }

    @Test("T-016m review M1: a reply cut by a stop or a barge-in is voided with no re-ask and no fallback line")
    func cutReplyIsSilent() {
        var h = Self.harness(["Jardin": ("fr", 0.85)])
        Self.asked(&h)
        h.send(.replyText(h.turn, "Jardin"))
        h.send(.stopped)
        h.send(.turnClosed(h.turn, .cancelled))
        h.advance(by: .seconds(7))
        #expect(Self.reasks(h.out).isEmpty && Self.fallbacks(h.out) == 0 && h.out.contains(.voided(h.turn)))
        var b = Self.harness(["Jardin": ("fr", 0.85)])
        Self.asked(&b)
        b.send(.replyText(b.turn, "Jardin"))
        b.send(.turnClosed(b.turn, .cancelled))
        #expect(Self.reasks(b.out).isEmpty)
    }

    @Test("T-016m review M2, M3: a late final of the same onset keeps the one re-ask; a new onset cancels the fallback line at once")
    func onsets() {
        var h = Self.harness()
        h.send(.speechStarted)
        h.send(.driverUtterance("不知道"))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.send(.replyText(h.turn, "안녕"))
        h.send(.driverUtterance("不知道。", language: .zh))  // the SenseVoice final, late
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.send(.replyText(h.turn, "안녕"))
        #expect(Self.reasks(h.out).count == 1 && Self.fallbacks(h.out) == 1)

        var g = Self.harness()
        g.send(.speechStarted)
        Self.asked(&g)
        g.send(.replyText(g.turn, "안녕"))
        g.advance(by: .seconds(5))
        g.send(.speechStarted)  // the driver repeats before 6 s
        g.advance(by: .seconds(5))
        #expect(Self.fallbacks(g.out) == 0)
    }
}
