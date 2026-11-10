import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

/// F-09a §6 (T-017a): car tools only for car requests (落域); tired utterances silenced in code.
@Suite("T-017a F-09a car request areas")
struct CarRequestAreaTests {
    static let music: Set<String> = ["playSong", "stopMusic", "t3MusicOff"]
    static let sleepy = ["drowsy", "drowsyMusicOn", "fallingAsleep", "t3Exhausted", "hEyelids", "hDizzy", "h2EyesClosing",
                         "h2Yawning", "h3Nodding", "h3Foggy"]

    static func area(_ text: String?) -> CarRequestArea { CarRequestRouter.area(final: text, previous: nil) }

    static func drive(revoicing: Bool = true) -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), revoicing: revoicing, carRequestAreas: true)
        d.connect()
        return d
    }

    static func liveInfo(_ id: String = "call_2") -> ToolCall {
        ToolCall(id: CallID(id)!, name: "query_live_info", arguments: ["kind": "weather", "where": "上海"])
    }

    static func areas(_ effects: [AgentEffect]) -> [CarRequestArea] {
        effects.compactMap { if case .diagnostic(.carArea(_, let a)) = $0 { a } else { nil } }
    }

    static func started(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { if case .startTool(_, let c) = $0 { c.name } else { nil } }
    }

    static func refusedCodes(_ effects: [AgentEffect]) -> [ToolErrorCode] {
        effects.flatMap { effect -> [ToolErrorCode] in
            if case .provider(.toolResponses(let rs)) = effect { rs.compactMap { $0.result.code } } else { [] }
        }
    }

    /// One sent utterance closed, then its local final (nil: none comes).
    @discardableResult
    static func say(_ d: inout Drive, _ final: DriverWords?) -> [AgentEffect] {
        var out = d.send(.speechStarted(recentSpeech: true))
        out += d.send(.speechStopped)
        if let final { out += d.send(.driverWords(final)) }
        return out
    }

    /// Fires the newest `.area` wait at its deadline.
    @discardableResult
    static func fireArea(_ d: inout Drive) -> [AgentEffect] {
        guard let at = d.effects.compactMap({ effect -> NovaInstant? in
            if case .schedule(.area(let at), _) = effect { at } else { nil }
        }).last else { return [] }
        d.now = at
        return d.send(.timer(.area(at)))
    }

    @Test("F-09a row 1: every comfort case that acts or refuses is car; the three music cases are chat")
    func row1() {
        let cases = ComfortCases.all.filter { $0.expected == .act || $0.expected == .refuse }
        #expect(cases.count > 50)
        for c in cases {
            #expect(Self.area(c.sentence) == (Self.music.contains(c.id) ? .chat : .car), "\(c.id) \(c.sentence)")
        }
    }

    @Test("F-09a row 2: the ten sleepy cases are tired")
    func row2() {
        for id in Self.sleepy {
            let c = ComfortCases.all.first { $0.id == id }
            #expect(c != nil, "\(id)")
            #expect(Self.area(c?.sentence) == .tired, "\(id)")
        }
    }

    @Test("F-09a row 3: jokes, questions, a bare 帮我调一下, 困难 and a sleepy line asking for music are chat")
    func row3() {
        for text in ["讲个笑话", "讲个小故事", "明天会下雨吗", "为什么开车容易犯困", "帮我调一下", "有点困难", "好困，放首歌"] {
            #expect(Self.area(text) == .chat, "\(text)")
        }
        #expect(Self.area("好 困 。") == .tired)  // Gemini-style spacing is normalized
        #expect(Self.area(nil) == .unknown)
        #expect(Self.area("温度调到二十二度") == .car)
    }

    @Test("F-09a row 4: a chat utterance's control_climate is refused with NOT_A_CAR_REQUEST; query_live_info runs")
    func row4() {
        var d = Self.drive()
        Self.say(&d, .final("讲个笑话"))
        #expect(Self.areas(d.effects) == [.chat])
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        let out = d.realtime(.toolCalls(t1, [climateOn(), Self.liveInfo()]))
        #expect(Self.started(out) == ["query_live_info"])
        #expect(Self.refusedCodes(out) == [.notACarRequest])
        let advice = out.compactMap { effect -> String? in
            if case .provider(.toolResponses(let rs)) = effect { rs.first?.result.advice } else { nil }
        }
        #expect(advice == ["司机这句话不是车辆操作请求，没有执行。不要提这个操作，正常回应司机。"])
        #expect(out.contains(.diagnostic(.toolRefused(code: .notACarRequest))))
    }

    @Test("F-09a row 5: tired: two turns of text and audio are neither played nor shown, no re-ask; 有点热 next is answered")
    func row5() {
        var d = Self.drive(revoicing: false)
        Self.say(&d, .final("好困"))
        #expect(Self.areas(d.effects) == [.tired])
        let t1 = TurnID(1), t2 = TurnID(2)
        var out = d.realtime(.responseStarted(t1))
        out += d.realtime(.replyText(t1, "好的，给你开空调。"))
        out += d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        out += d.realtime(.toolCalls(t1, [climateOn()]))
        out += d.realtime(.responseDone(t1, outcome: .completed))
        out += d.realtime(.responseStarted(t2))
        out += d.realtime(.replyText(t2, "要不要休息一下？"))
        out += d.realtime(.replyAudio(t2, GeminiVoiceTests.pcm))
        out += d.realtime(.responseDone(t2, outcome: .completed))
        #expect(GeminiVoiceTests.played(out).isEmpty)
        #expect(d.state.view.subtitle.isEmpty)
        #expect(Self.started(out).isEmpty)
        #expect(Self.refusedCodes(out) == [.notACarRequest])
        #expect(out.contains(.diagnostic(.tiredSilenced(turn: 1))))
        #expect(out.contains(.diagnostic(.tiredSilenced(turn: 2))))
        // No empty-response re-ask, correction or fallback line after the timeouts.
        let later = d.fire(.reask) + d.fire(.correction) + d.fire(.giveUp)
        #expect(!later.contains { if case .provider(.text) = $0 { true } else { false } })

        Self.say(&d, .final("有点热"))
        #expect(Self.areas(d.effects).last == .car)
        let t3 = TurnID(3)
        d.realtime(.responseStarted(t3))
        let call = d.realtime(.toolCalls(t3, [climateOn("call_3")]))
        #expect(Self.started(call) == ["control_climate"])
        d.send(.toolFinished(t3, climateOn("call_3"), .success(["power_on": true])))
        let reply = d.realtime(.replyText(t3, "空调开好了。")) + d.realtime(.replyAudio(t3, GeminiVoiceTests.pcm))
        #expect(GeminiVoiceTests.played(reply) == [t3])
    }

    @Test("F-09a row 5: a turn that opens before the final waits; 好困 then drops it, 讲个笑话 releases it")
    func row5Order() {
        var d = Self.drive(revoicing: false)
        Self.say(&d, nil)
        let t1 = TurnID(1)
        var out = d.realtime(.responseStarted(t1))
        out += d.realtime(.replyText(t1, "好的。"))
        out += d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        #expect(GeminiVoiceTests.played(out).isEmpty)
        #expect(d.state.view.subtitle.isEmpty)
        let tired = d.send(.driverWords(.final("好困")))
        #expect(GeminiVoiceTests.played(tired).isEmpty)
        #expect(tired.contains(.diagnostic(.tiredSilenced(turn: 1))))
        #expect(tired.contains { if case .flushPlayback = $0 { true } else { false } })
        #expect(GeminiVoiceTests.played(d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))).isEmpty)

        var e = Self.drive(revoicing: false)
        // The local partial came while the utterance was open; its final comes after her turn closed.
        e.send(.speechStarted(recentSpeech: true))
        e.send(.driverWords(.partial("讲个笑话")))
        e.send(.speechStopped)
        e.realtime(.responseStarted(t1))
        e.realtime(.replyText(t1, "好的，有一只小猫。"))
        e.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        e.realtime(.responseDone(t1, outcome: .completed))
        let released = e.send(.driverWords(.final("讲个笑话")))
        #expect(Self.areas(released) == [.chat])
        #expect(GeminiVoiceTests.played(released) == [t1])
        #expect(e.state.view.subtitle == "好的，有一只小猫。")
    }

    @Test("F-09a row 5: a held reply is kept while the driver speaks again, and plays once its area is known")
    func row5BargeIn() {
        var d = Self.drive(revoicing: false)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.driverWords(.partial("讲个笑话")))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "好的，有一只小猫。"))
        d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        d.realtime(.responseDone(t1, outcome: .completed))
        let next = d.send(.speechStopped)
        #expect(Self.areas(next) == [.unknown])
        #expect(GeminiVoiceTests.played(next) == [t1, t1])   // whole reply, head first
        #expect(d.state.view.subtitle == "好的，有一只小猫。")
    }

    @Test("F-09a row 5: a turn Gemini opens before the phone closes 好困 is silenced")
    func row5EarlyTurn() {
        var d = Self.drive(revoicing: false)
        Self.say(&d, .final("讲个笑话"))
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.send(.speechStarted(recentSpeech: true))
        let t2 = TurnID(2)
        var out = d.realtime(.responseStarted(t2))
        out += d.realtime(.replyText(t2, "好的，开空调。"))
        out += d.realtime(.replyAudio(t2, GeminiVoiceTests.pcm))
        out += d.send(.speechStopped)
        out += d.send(.driverWords(.final("好困")))
        out += d.realtime(.replyAudio(t2, GeminiVoiceTests.pcm))
        #expect(GeminiVoiceTests.played(out).isEmpty)
        #expect(out.contains(.diagnostic(.tiredSilenced(turn: 2))))
        #expect(d.state.view.subtitle.isEmpty)
    }

    @Test("F-09a row 6: 有点热 (climate ok), 再低一点, 好困 are car, follow-up, tired")
    func row6() {
        var d = Self.drive()
        Self.say(&d, .final("有点热"))
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        d.realtime(.responseDone(t1, outcome: .completed))
        Self.say(&d, .final("再低一点"))
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        let lower = ToolCall(id: CallID("call_2")!, name: "control_climate", arguments: ["action": "adjust_temperature", "value": -1])
        #expect(Self.started(d.realtime(.toolCalls(t2, [lower]))) == ["control_climate"])
        d.realtime(.responseDone(t2, outcome: .completed))
        Self.say(&d, .final("好困"))
        #expect(Self.areas(d.effects) == [.car, .followUp, .tired])
        // Without an ok comfort result before it, the same words are chat.
        var e = Self.drive()
        Self.say(&e, .final("有点热"))
        Self.say(&e, .final("再低一点"))
        #expect(Self.areas(e.effects) == [.car, .chat])
        #expect(DiagnosticEvent.carArea(utterance: 2, area: .followUp).logLine == "area utterance=2 area=follow-up")
        #expect(DiagnosticEvent.tiredSilenced(turn: 3).logLine == "tired-silenced turn=3")
        var r = ConversationRecorder()
        #expect(r.add(.area(utterance: 2, area: .followUp), atMs: 5) == ["5 area utterance=2 area=follow-up"])
    }

    @Test("F-09a row 7: unclear, or no final within 800 ms of a comfort call: unknown, and the call runs")
    func row7() {
        var d = Self.drive()
        Self.say(&d, .unclear)
        #expect(Self.areas(d.effects) == [.unknown])
        d.realtime(.responseStarted(TurnID(1)))
        #expect(Self.started(d.realtime(.toolCalls(TurnID(1), [climateOn()]))) == ["control_climate"])

        var e = Self.drive()
        Self.say(&e, nil)
        e.realtime(.responseStarted(TurnID(1)))
        let held = e.realtime(.toolCalls(TurnID(1), [climateOn()]))
        #expect(Self.started(held).isEmpty)
        #expect(held.contains(.schedule(.area(e.now + .milliseconds(800)), at: e.now + .milliseconds(800))))
        let fired = Self.fireArea(&e)
        #expect(Self.areas(fired) == [.unknown])
        #expect(Self.started(fired) == ["control_climate"])
        // A late final changes nothing.
        #expect(Self.areas(e.send(.driverWords(.final("讲个笑话")))).isEmpty)
    }

    @Test("F-09a row 7: a call that waits is refused when the final then says chat")
    func row7Late() {
        var d = Self.drive()
        Self.say(&d, nil)
        d.realtime(.responseStarted(TurnID(1)))
        #expect(Self.started(d.realtime(.toolCalls(TurnID(1), [climateOn()]))).isEmpty)
        let out = d.send(.driverWords(.final("讲个笑话")))
        #expect(Self.refusedCodes(out) == [.notACarRequest])
        #expect(Self.started(out).isEmpty)
        #expect(d.state.runningTools == 0)
    }

    @Test("F-09a row 8: a tap is never refused by the area")
    func row8() {
        #expect(CarRequestRouter.allows(.chat, fromTap: true))
        #expect(CarRequestRouter.allows(.tired, fromTap: true))
        #expect(!CarRequestRouter.allows(.chat))
        #expect(CarRequestRouter.allows(.unknown))
    }

    @Test("Areas off (no phone recognizer words): every call runs as before")
    func off() {
        var d = Drive()
        d.connect()
        Self.say(&d, .final("讲个笑话"))
        d.realtime(.responseStarted(TurnID(1)))
        #expect(Self.started(d.realtime(.toolCalls(TurnID(1), [climateOn()]))) == ["control_climate"])
        #expect(Self.areas(d.effects).isEmpty)
    }

    @Test("F-09a row 5 early call: after 有点热, 好困's early control_climate is refused once the area is tired")
    func row5EarlyCallTired() {
        var d = Self.drive()
        Self.say(&d, .final("有点热"))
        let t1 = TurnID(1), t2 = TurnID(2)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        d.realtime(.responseDone(t1, outcome: .completed))
        d.send(.speechStarted(recentSpeech: true))
        var out = d.realtime(.responseStarted(t2))
        out += d.realtime(.toolCalls(t2, [climateOn("call_3")]))
        #expect(Self.started(out).isEmpty)
        out += d.send(.speechStopped)
        out += d.send(.driverWords(.final("好困")))
        #expect(Self.areas(d.effects).last == .tired)
        #expect(Self.started(out).isEmpty)
        #expect(Self.refusedCodes(out) == [.notACarRequest])
        #expect(d.state.runningTools == 0)
    }

    @Test("F-09a row 5 early call: a held comfort call that Gemini cancels never runs")
    func row5EarlyCallCancelled() {
        var d = Self.drive()
        Self.say(&d, .final("讲个笑话"))
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.send(.speechStarted(recentSpeech: true))
        let t2 = TurnID(2)
        var out = d.realtime(.responseStarted(t2))
        out += d.realtime(.toolCalls(t2, [climateOn()]))
        out += d.realtime(.toolCallCancellation([climateOn().id]))
        out += d.send(.speechStopped)
        out += d.send(.driverWords(.final("有点热")))
        #expect(Self.started(out).isEmpty)
        #expect(Self.refusedCodes(out).isEmpty)
        #expect(d.state.runningTools == 0)
    }

    @Test("F-09a row 5: a late call of the closed utterance's turn keeps that utterance's area")
    func row5LateCallOfClosedTurn() {
        var d = Self.drive()
        Self.say(&d, .final("有点热"))
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.send(.speechStarted(recentSpeech: true))
        d.send(.driverWords(.partial("讲个")))
        let out = d.realtime(.toolCalls(t1, [climateOn()]))
        #expect(Self.started(out) == ["control_climate"])
    }

    @Test("F-09a row 5 early call: after 讲个笑话, an early comfort call for 有点热 runs once the area is car")
    func row5EarlyCallAfterChat() {
        var d = Self.drive()
        Self.say(&d, .final("讲个笑话"))
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.send(.speechStarted(recentSpeech: true))
        let t2 = TurnID(2)
        var out = d.realtime(.responseStarted(t2))
        out += d.realtime(.toolCalls(t2, [climateOn()]))
        #expect(Self.started(out).isEmpty)
        #expect(Self.refusedCodes(out).isEmpty)
        out += d.send(.speechStopped)
        out += d.send(.driverWords(.final("有点热")))
        #expect(Self.started(out) == ["control_climate"])
        #expect(Self.refusedCodes(out).isEmpty)
    }

    @Test("F-09a row 5 early call: the first utterance's early call waits for its area and is credited to it")
    func row5EarlyCallFirst() {
        var d = Self.drive()
        d.send(.speechStarted(recentSpeech: true))
        let t1 = TurnID(1)
        var out = d.realtime(.responseStarted(t1))
        out += d.realtime(.toolCalls(t1, [climateOn()]))
        #expect(Self.started(out).isEmpty)
        out += d.send(.speechStopped)
        out += d.send(.driverWords(.final("有点热")))
        #expect(Self.started(out) == ["control_climate"])
        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true])))
        d.realtime(.responseDone(t1, outcome: .completed))
        Self.say(&d, .final("再低一点"))
        #expect(Self.areas(d.effects) == [.car, .followUp])
    }

    @Test("F-09a row 5 early reply: no final ever comes; the early turn's reply plays 800 ms after the close as unknown")
    func row5EarlyReplyNoFinal() {
        var d = Self.drive(revoicing: false)
        d.send(.speechStarted(recentSpeech: true))
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "好的，从前有一只小猫在河边钓鱼，钓了一整天。"))
        d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        d.now = d.now + .milliseconds(2000)
        let closed = d.send(.speechStopped)
        let deadline = d.now + .milliseconds(800)
        #expect(closed.contains(.schedule(.area(deadline), at: deadline)))
        #expect(GeminiVoiceTests.played(closed).isEmpty)
        let fired = Self.fireArea(&d)
        #expect(d.now == deadline)
        #expect(Self.areas(fired) == [.unknown])
        #expect(GeminiVoiceTests.played(fired) == [t1])
        #expect(d.state.view.subtitle == "好的，从前有一只小猫在河边钓鱼，钓了一整天。")
    }

    @Test("F-09a row 5: two held turns that closed meanwhile are both released when the area is known")
    func row5TwoHeldClosed() {
        var d = Self.drive(revoicing: false)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.driverWords(.partial("讲个笑话")))
        d.send(.speechStopped)
        let t1 = TurnID(1), t2 = TurnID(2)
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "好的，有一只小猫。"))
        d.realtime(.replyAudio(t1, GeminiVoiceTests.pcm))
        d.realtime(.responseDone(t1, outcome: .completed))
        d.realtime(.responseStarted(t2))
        d.realtime(.replyText(t2, "小猫在河边钓了一整天的鱼，最后一条也没钓到。"))
        d.realtime(.replyAudio(t2, GeminiVoiceTests.pcm))
        d.realtime(.responseDone(t2, outcome: .completed))
        let out = d.send(.driverWords(.final("讲个笑话")))
        #expect(Self.areas(out) == [.chat])
        #expect(GeminiVoiceTests.played(out) == [t1, t2])
        #expect(d.state.view.subtitle.hasSuffix("小猫在河边钓了一整天的鱼，最后一条也没钓到。"))
    }
}
