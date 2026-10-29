import Testing
import NovaKit
import NovaPorts
@testable import NovaVoice

@Suite("T-016a F-05a TranscriptLanguage")
struct TranscriptLanguageTests {
    @Test("F-05a row 2: Mandarin true; Portuguese and English false; 导航去 Costa true; digits and punctuation ignored")
    func isChinese() {
        for text in ["别说了", "回家", "帮我把空调打开。", "附近有加油站吗？", "導航回家", "播放 3 号歌"] {
            #expect(TranscriptLanguage.isChinese(text), "\(text)")
        }
        for text in ["Não fale mais", "obrigado", "stop talking", "OK", "", "123", "。！？", "ありがとう"] {
            #expect(!TranscriptLanguage.isChinese(text), "\(text)")
        }
        #expect(TranscriptLanguage.isChinese("导航去 Costa"))
        #expect(TranscriptLanguage.isChinese("导航去 Costa 2 号"))
        // Mostly Latin words around one character is not Chinese.
        #expect(!TranscriptLanguage.isChinese("vai para o 家 agora mesmo"))
    }
}

@Suite("T-016a F-05a TranscriptSelector")
struct TranscriptSelectorTests {
    let u1 = UtteranceID(1)
    let u2 = UtteranceID(2)
    let t0 = NovaInstant.zero

    func words(_ out: [TranscriptSelector.Output]) -> [DriverWords] {
        out.compactMap { if case .words(let w) = $0 { w } else { nil } }
    }

    @Test("F-05a row 1 S1: local partials and final are forwarded; Gemini's transcript for the utterance is dropped")
    func localWins() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        #expect(words(s.local(.partial(u1, "别说"), at: t0)) == [.partial("别说")])
        #expect(s.gemini("Não", isFinal: false, at: t0).isEmpty)
        #expect(words(s.local(.partial(u1, "别说了"), at: t0)) == [.partial("别说了")])
        #expect(s.end(u1, at: t0) == [.schedule(u1, at: t0 + .milliseconds(800))])
        #expect(words(s.local(.final(u1, "别说了"), at: t0)) == [.final("别说了")])
        #expect(s.gemini("Não fale", isFinal: true, at: t0).isEmpty)
        #expect(s.deadline(u1, at: t0 + .milliseconds(800)).isEmpty)
    }

    @Test("F-05a row 1 S2: no local final 800 ms after the end, the last partial becomes the final")
    func finalWait() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        _ = s.local(.partial(u1, "回家"), at: t0)
        _ = s.end(u1, at: t0)
        #expect(words(s.deadline(u1, at: t0 + .milliseconds(800))) == [.final("回家")])
        // A late final changes nothing.
        #expect(s.local(.final(u1, "回家吧"), at: t0 + .milliseconds(900)).isEmpty)
    }

    @Test("F-05a row 1 S2→S3: no local text at all, Gemini's transcript is used (Chinese only)")
    func noLocalText() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        _ = s.gemini("算了", isFinal: true, at: t0)
        _ = s.end(u1, at: t0)
        #expect(words(s.deadline(u1, at: t0 + .milliseconds(800))) == [.final("算了")])

        // Gemini's final arrives only after the wait.
        _ = s.begin(u2, localReady: true)
        _ = s.end(u2, at: t0)
        #expect(words(s.deadline(u2, at: t0 + .milliseconds(800))).isEmpty)
        #expect(words(s.gemini("好的", isFinal: true, at: t0)) == [.final("好的")])
    }

    @Test("F-05a row 1 S3: local unavailable, Gemini's Chinese partials and final pass")
    func fallback() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: false)
        #expect(words(s.gemini("别说", isFinal: false, at: t0)) == [.partial("别说")])
        #expect(words(s.gemini("了", isFinal: false, at: t0)) == [.partial("别说了")])
        #expect(s.end(u1, at: t0).isEmpty)
        #expect(words(s.gemini("别说了", isFinal: true, at: t0)) == [.final("别说了")])
    }

    @Test("F-05a row 1 S3: the recognizer fails mid-utterance; with partial text it is the final, without it Gemini's")
    func failure() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        _ = s.local(.partial(u1, "打开空调"), at: t0)
        #expect(s.local(.failed(u1, reason: "error"), at: t0).isEmpty)
        #expect(words(s.end(u1, at: t0)) == [.final("打开空调")])

        _ = s.begin(u2, localReady: true)
        _ = s.end(u2, at: t0)
        #expect(words(s.local(.failed(u2, reason: "error"), at: t0)).isEmpty)
        #expect(words(s.gemini("Não fale", isFinal: true, at: t0)) == [.unclear])
    }

    @Test("F-05a row 1 S4: Gemini's non-Chinese text is never the driver's words")
    func languageCheck() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: false)
        #expect(s.gemini("Não fa", isFinal: false, at: t0).isEmpty)
        #expect(words(s.gemini("Não fale mais", isFinal: true, at: t0)) == [.unclear])
    }

    @Test("F-05a row 1 S5: empty text is ignored (local and Gemini)")
    func empty() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        #expect(s.local(.partial(u1, ""), at: t0).isEmpty)
        #expect(s.local(.final(u1, ""), at: t0).isEmpty)
        #expect(s.gemini("回家", isFinal: true, at: t0).isEmpty)
        _ = s.begin(u2, localReady: false)
        #expect(s.gemini("  ", isFinal: true, at: t0).isEmpty)
    }

    @Test("F-05a §9: events of a superseded utterance are dropped")
    func stale() {
        var s = TranscriptSelector()
        _ = s.begin(u1, localReady: true)
        _ = s.end(u1, at: t0)
        _ = s.begin(u2, localReady: true)
        #expect(s.local(.final(u1, "回家"), at: t0).isEmpty)
        #expect(s.deadline(u1, at: t0 + .milliseconds(800)).isEmpty)
        #expect(words(s.local(.partial(u2, "好的"), at: t0)) == [.partial("好的")])
    }
}
