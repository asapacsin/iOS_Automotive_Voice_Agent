import Testing
import NovaKit
import NovaPorts
import NovaVoice
@testable import NovaAgent

private func screenHidden(_ effects: [AgentEffect]) -> [AgentEffect] {
    effects.filter { if case .screenHidden(.driver, _) = $0 { true } else { false } }
}

@Suite("T-016n F-05a §16 the driver's line on screen comes from Gemini's text only")
struct DriverLineTests {
    static let detector = FakeDetector(["tudo bem": ("pt", 0.9), "What time is it now": ("en", 0.9), "OK": ("en", 0.3)])

    /// Connected; one utterance sent and closed; the local recognizer feeds the core's words.
    static func heard(local: String?) -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), languageIdentifier: detector)
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        if let local { d.send(.driverWords(.final(local))) }
        return d
    }

    @Test("T-016n F-05a §16 row 1: local 「不知道。」 and Gemini `tudo bem` (pt 0.9): 「（没听清）」, never the local text")
    func localNeverShown() {
        var d = Self.heard(local: "不知道。")
        #expect(d.state.view.driverLine.isEmpty)
        let out = d.realtime(.userTranscript("tudo bem", isFinal: true))
        #expect(d.state.view.driverLine == "（没听清）")
        #expect(screenHidden(out).count == 1)
        #expect(!d.effects.contains { if case .publish(let v) = $0 { v.driverLine.contains("不知道") } else { false } })
    }

    @Test("T-016n F-05a §16 row 2: Chinese, Japanese, English (en 0.9) and OK show; Hangul shows 「（没听清）」")
    func filter() {
        for (text, line) in [("现在几点?", "现在几点?"), ("今何時ですか", "今何時ですか"), ("What time is it now", "What time is it now"),
                             ("OK", "OK"), ("당연하죠.早上。", "（没听清）")] {
            var d = Self.heard(local: nil)
            d.realtime(.userTranscript(text, isFinal: true))
            #expect(d.state.view.driverLine == line)
        }
    }

    @Test("T-016n F-05a §16 row 3: Latin partials wait; the English final shows")
    func partials() {
        var d = Self.heard(local: nil)
        d.realtime(.userTranscript("Wha", isFinal: false))
        #expect(d.state.view.driverLine.isEmpty)
        d.realtime(.userTranscript("t time", isFinal: false))
        #expect(d.state.view.driverLine.isEmpty)
        d.realtime(.userTranscript("What time is it now", isFinal: true))
        #expect(d.state.view.driverLine == "What time is it now")
    }

    @Test("T-016n F-05a §16 row 4: local text and no Gemini text: no line; driverUtterance still gets the local words")
    func noGeminiText() {
        var d = Self.heard(local: "把空调打开")
        #expect(d.state.view.driverLine.isEmpty)
        // The local words reached driverUtterance: the no-answer re-ask names them.
        let reask = d.fire(.reask)
        #expect(reask.contains(.provider(.text([TextTurn(role: .user, text: "请回答我最新的这句话：「把空调打开」")], turnComplete: true))))
        // A new utterance clears an old line.
        d.realtime(.userTranscript("现在几点", isFinal: true))
        #expect(d.state.view.driverLine == "现在几点")
        d.send(.speechStarted(recentSpeech: true))
        #expect(d.state.view.driverLine.isEmpty)
    }

    @Test("T-016n F-05a §16 row 5: the local 「别说了」 stops her while Gemini's text is hidden")
    func stopPhrase() {
        var d = Self.heard(local: "讲个故事")
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.replyText(TurnID(1), "从前有一座山，山里有座庙，"))
        d.send(.playback(.replyStarted(Epoch.initial)))
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("la vecina", isFinal: true))
        let stop = d.send(.driverWords(.partial("别说了")))
        #expect(stop.contains(.flushPlayback(Epoch(1))))
        #expect(d.state.view.driverLine == "（没听清）")
    }
}
