import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

private struct Fake: LanguageIdentifier {
    func hypotheses(_ text: String) -> [LanguageHypothesis] {
        text.hasPrefix("Tudo bem, em") ? [LanguageHypothesis(language: "pt", probability: 0.9)] : []
    }
}

@Suite("T-016m F-05a §15 in AgentState and the record")
struct ReplyLanguageAgentTests {
    static let portuguese = "Tudo bem, em que posso ajudar você?"

    static func asked() -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: false, languageIdentifier: Fake())
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.send(.driverWords(.final("不知道。", language: .zh)))
        d.realtime(.responseStarted(TurnID(1)))
        return d
    }

    static func texts(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { if case .provider(.text(let turns, _)) = $0 { turns.last?.text } else { nil } }
    }

    @Test("T-016m rows 4, 6: Portuguese voided and re-asked with SenseVoice's words; no reply for 6 s → the app's line on the guidance lane and screen")
    func reaskThenFallback() {
        var d = Self.asked()
        let out = d.realtime(.replyAudio(TurnID(1), PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])))
            + d.realtime(.replyText(TurnID(1), Self.portuguese))
        #expect(!out.contains { if case .playReplyAudio = $0 { true } else { false } })
        #expect(Self.texts(out) == ["[系统] WRONG_LANGUAGE：刚才的回答不是中文、英文或日语，已作废。司机刚才说的是「不知道。」。请用中文回答这句话。"])
        #expect(out.contains(.diagnostic(.wrongLanguage(heard: true))))
        #expect(d.state.view.subtitle.isEmpty)
        let fallback = d.fire(.fallback)
        #expect(fallback.contains { if case .speakGuidance("没听清，请再说一遍", _) = $0 { true } else { false } })
        #expect(d.state.view.subtitle == "没听清，请再说一遍")
        #expect(fallback.contains(.diagnostic(.fallbackLine(turn: 1, reason: .noReply))))
    }

    @Test("T-016m row 8: the record lines are exactly as item 7, with no reply or driver words")
    func recordLines() {
        var r = ConversationRecorder()
        let lines = r.add(.langCheck(turn: 8, verdict: .blocked, lang: LanguageTag("pt"), percent: 90, heldMs: 200), atMs: 10)
            + r.add(.wrongLanguage(heard: true), atMs: 11)
            + r.add(.wrongLanguage(heard: false), atMs: 12)
            + r.add(.fallbackLine(turn: 9, reason: .blockedAgain), atMs: 13)
            + r.add(.langCheck(turn: 10, verdict: .released, lang: nil, percent: 0, heldMs: 800), atMs: 14)
        #expect(lines == ["10 lang-check turn=8 verdict=blocked lang=pt p=0.90 held_ms=200",
                          "11 correction WRONG_LANGUAGE heard=sensevoice",
                          "12 correction WRONG_LANGUAGE heard=none",
                          "13 fallback-line turn=9 reason=blocked_again",
                          "14 lang-check turn=10 verdict=released lang=none p=0.00 held_ms=800"])
        for line in lines { #expect(!line.contains("Tudo") && !line.contains("不知道")) }
    }
}
