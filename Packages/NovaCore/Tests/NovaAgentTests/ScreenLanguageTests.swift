import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

private func subtitles(_ effects: [AgentEffect]) -> [String] {
    effects.compactMap { if case .publish(let v) = $0 { v.subtitle } else { nil } }
}

private func hidden(_ effects: [AgentEffect]) -> [AgentEffect] {
    effects.filter { if case .screenHidden = $0 { true } else { false } }
}

@Suite("T-016i F-05a §13 only Chinese reaches the conversation text on screen")
struct ScreenLanguageTests {
    @Test("Row 1: final Chinese, names inside Chinese, short tokens and numbers show")
    func shows() {
        for text in ["你好", "导航去 Costa", "4S店", "OK", "4S", "22", "…", "去SM广场"] {
            #expect(ScreenLanguage.check(text, final: true) == .show, "\(text)")
        }
    }

    @Test("Row 2: final other scripts, mixed Hangul, and Latin sentences hide")
    func hides() {
        for text in ["안녕하세요", "好的안녕", "こんにちは", "Привет", "मैं", "¿Qué?", "What?", "la vecina", "好 la vecina"] {
            #expect(ScreenLanguage.check(text, final: true) == .hide, "\(text)")
        }
    }

    @Test("Row 3: not final: Latin waits, Hangul hides, Chinese shows")
    func notFinal() {
        #expect(ScreenLanguage.check("Disc", final: false) == .wait)
        #expect(ScreenLanguage.check("OK", final: false) == .wait)
        #expect(ScreenLanguage.check("안", final: false) == .hide)
        #expect(ScreenLanguage.check("你好", final: false) == .show)
    }

    func replying() -> (Drive, TurnID) {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("你好", isFinal: true))
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        return (d, t)
    }

    @Test("Row 4: OK then ，好的: nothing after the first piece, the whole text after the second")
    func wholeOnce() {
        var (d, t) = replying()
        let first = d.realtime(.replyText(t, "OK"))
        #expect(subtitles(first).allSatisfy { $0.isEmpty })
        let second = d.realtime(.replyText(t, "，好的"))
        #expect(subtitles(second).last == "OK，好的")
    }

    @Test("Row 5: 안녕 is voided with NOT_MANDARIN at the first Hangul letter; nothing shown or spoken")
    func hangulVoided() {
        #expect(ReplyLanguage.isNotMandarin("안"))
        #expect(ReplyLanguage.isNotMandarin("好的안"))
        #expect(!ReplyLanguage.isNotMandarin("OK"))
        var (d, t) = replying()
        let out = d.realtime(.replyText(t, "안녕"))
        #expect(spoken(out).isEmpty && subtitles(out).allSatisfy { $0.isEmpty })
        #expect(d.fire(.correction).contains(.provider(.text([TextTurn(role: .user, text: CorrectionReason.notMandarin.instruction)],
                                                             turnComplete: true))))
    }

    @Test("Row 6: a Spanish reply piece by piece never shows; voided at 6 letters as today")
    func spanish() {
        var (d, t) = replying()
        var shown: [String] = []
        for piece in ["Dis", "cul", "pa, no"] { shown += subtitles(d.realtime(.replyText(t, piece))) }
        #expect(shown.allSatisfy { $0.isEmpty })
        #expect(!ReplyLanguage.isNotMandarin("Discu") && ReplyLanguage.isNotMandarin("Discul"))
        #expect(spoken(d.effects).isEmpty)
    }

    @Test("Row 7: la vecina from either source shows 「（没听清）」; the words themselves are unchanged")
    func driverLine() {
        let words = "la vecina"
        let shown = ScreenLanguage.driverDisplay(words, final: true)
        #expect(shown.line == "（没听清）" && shown.hidden)
        #expect(ScreenLanguage.driverDisplay("la vec", final: false).line == nil)
        let stop = ScreenLanguage.driverDisplay("别说了", final: true)
        #expect(stop.line == "别说了" && !stop.hidden)
        #expect(words == "la vecina")
    }

    @Test("Row 8: a hidden guidance reading shows the engine's sentence and is still spoken; a hidden camera answer becomes the fallback")
    func guidanceAndCamera() {
        var d = Drive()
        d.connect()
        d.send(.navigation(NavigationFlags(navigating: true, guidanceRunning: true)))
        d.send(.guidancePrompt("前方300米右转", GuidanceID(1)))
        let t = TurnID(1)
        d.realtime(.responseStarted(t))
        let out = d.realtime(.replyText(t, "전방 300미터"))
        #expect(subtitles(out).last == "前方300米右转")
        #expect(hidden(out) == [.screenHidden(.guidance, "전방 300미터")])
        // Display only: her reading still goes through the relay unchanged (F-14), and the hidden text stays hidden.
        let done = d.realtime(.responseDone(t, outcome: .completed))
        #expect(subtitles(done).allSatisfy { $0 == "前方300米右转" } && hidden(done).isEmpty)
        let ru = ScreenLanguage.cameraLine("Это машина")
        #expect(ru.line == "刚才没看清楚，再问我一次吧。" && ru.hidden)
        let zh = ScreenLanguage.cameraLine("前面是一辆白色的车。")
        #expect(zh.line == "前面是一辆白色的车。" && !zh.hidden)
    }

    @Test("Row 9: one screen-hidden record line per hidden text; the log line has no words")
    func recordLines() {
        var (d, t) = replying()
        d.realtime(.replyText(t, "What?"))
        let done = d.realtime(.responseDone(t, outcome: .completed))
        #expect(hidden(done) == [.screenHidden(.reply, "What?")])
        #expect(hidden(d.realtime(.replyText(t, " now"))).isEmpty)
        for kind in ScreenTextKind.allCases {
            var r = ConversationRecorder()
            let text = String(repeating: "가", count: 90)
            #expect(r.add(.screenHidden(kind: kind, text: text), atMs: 5)
                    == ["5 screen-hidden kind=\(kind.rawValue) text=\(String(repeating: "가", count: 80))"])
            #expect(DiagnosticEvent.screenHidden(kind: kind).logLine == "screenHidden kind=\(kind.rawValue)")
        }
    }
}
