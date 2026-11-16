import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

/// F-09b §4 item 3, §5, §6, §7 (T-031j, T-016p, T-017c): the agent side of the flexible assistant.
@Suite("T-031j T-016p T-017c F-09b flexible assistant")
struct FlexibleAssistantTests {
    static func car(fan: Int = 2, speed: Double? = 60) -> CarStateSnapshot {
        CarStateSnapshot(acOn: true, temperatureC: 24, fanLevel: fan, windows: [.frontLeft: 0, .frontRight: 0, .rearLeft: 0, .rearRight: 0],
                         driverSeat: 5, musicPlaying: false, speedKmh: speed)
    }

    static func notes(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { effect -> String? in
            if case .provider(.text(let turns, false)) = effect { turns.map(\.text).joined() } else { nil }
        }
    }

    static func reasons(_ effects: [AgentEffect]) -> [StateNoteReason] {
        effects.compactMap { if case .diagnostic(.stateNote(let r)) = $0 { r } else { nil } }
    }

    /// One completed model turn with optional tool calls.
    @discardableResult
    static func turn(_ d: inout Drive, calls: [ToolCall] = [], reply: String = "好的。") -> [AgentEffect] {
        var out = d.send(.speechStarted(recentSpeech: true))
        out += d.send(.speechStopped)
        d.turn = d.turn.next()
        out += d.realtime(.responseStarted(d.turn))
        if !calls.isEmpty {
            out += d.realtime(.toolCalls(d.turn, calls))
            for c in calls { out += d.send(.toolFinished(d.turn, c, .success(["ok": true]))) }
        }
        out += d.realtime(.replyText(d.turn, reply))
        out += d.realtime(.responseDone(d.turn, outcome: .completed))
        return out
    }

    @Test("T-031j F-09b §4 item 3: an undo's ok backs the claims for the restored functions only")
    func undoClaims() {
        let data: [String: JSONValue] = ["restored": ["climate": ["temperature_c": 24], "windows": ["front_left": 0]]]
        #expect(ClaimLexicon.unbackedTopics(in: "空调恢复到24度了，车窗也关上了", proofs: [("undo_last_change", data)]).isEmpty)
        let climateOnly: [String: JSONValue] = ["restored": ["climate": ["fan_level": 2]]]
        #expect(ClaimLexicon.unbackedTopics(in: "车窗关上了", proofs: [("undo_last_change", climateOnly)]) == [.windows])
    }

    @Test("T-031j F-09b §5 item 1: the note's exact form; no location field")
    func noteForm() {
        var s = Self.car(speed: nil)
        s.windows[.frontLeft] = 30
        s.temperatureC = 22.5
        #expect(s.note == "[系统] 车内状态：空调开，22.5度，风量2；车窗 主驾30% 副驾0% 后左0% 后右0%；座椅 主驾5档；音乐没放；车速未知公里。这句不用回答。")
        #expect(Self.car().note.contains("车速60公里"))
    }

    @Test("T-031j F-09b row 5: notes on connect, after the fan turn and on the speed cross only; never while a reply is open; destination and state in one text turn")
    func row5() {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), destinationNotes: true)
        d.send(.start)
        d.send(.vehicleState(Self.car()))
        // Connect: the state note.
        let connect = d.realtime(.setupComplete)
        #expect(Self.reasons(connect) == [.connect])
        #expect(Self.notes(connect).count == 1)
        // A turn that changes the fan (the shell reports the new state while the turn is open).
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.turn = d.turn.next()
        d.realtime(.responseStarted(d.turn))
        let open = d.send(.vehicleState(Self.car(fan: 4)))
        #expect(Self.notes(open).isEmpty)  // never while a reply is open
        d.realtime(.replyText(d.turn, "风量调到4档了。"))
        let done = d.realtime(.responseDone(d.turn, outcome: .completed))
        #expect(Self.reasons(done) == [.changed])
        #expect(Self.notes(done).first?.contains("风量4") == true)
        // A turn that changes nothing: no note.
        #expect(Self.reasons(Self.turn(&d)).isEmpty)
        // Speed crosses 100 km/h: a note; staying above it: none.
        #expect(Self.reasons(d.send(.vehicleState(Self.car(fan: 4, speed: 110)))) == [.speed])
        #expect(Self.reasons(d.send(.vehicleState(Self.car(fan: 4, speed: 120)))).isEmpty)
        // Destination and a state change pending together: one text turn.
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.turn = d.turn.next()
        d.realtime(.responseStarted(d.turn))
        d.send(.destination("珠海站"))
        d.send(.vehicleState(Self.car(fan: 5, speed: 120)))
        d.realtime(.replyText(d.turn, "好的。"))
        let both = d.realtime(.responseDone(d.turn, outcome: .completed))
        let texts = Self.notes(both)
        #expect(texts.count == 1)
        #expect(texts.first?.contains("珠海站") == true && texts.first?.contains("风量5") == true)
    }

    @Test("T-031j F-09b §5 item 2: not more than once per completed turn")
    func oncePerTurn() {
        var d = Drive()
        d.send(.vehicleState(Self.car()))
        d.connect()
        // The connect note was this turn's note: a speed cross waits for the next completed turn.
        #expect(Self.reasons(d.send(.vehicleState(Self.car(speed: 110)))).isEmpty)
        #expect(Self.reasons(Self.turn(&d)) == [.speed])
        // Two crosses before the next completed turn: one note.
        #expect(Self.reasons(d.send(.vehicleState(Self.car(speed: 90)))).isEmpty)
        #expect(Self.reasons(d.send(.vehicleState(Self.car(speed: 110)))).isEmpty)
        #expect(Self.reasons(Self.turn(&d)) == [.speed])
    }

    @Test("T-016p F-09b row 6: summary for a new session 10 minutes later without a handle; none 40 minutes later; none with a handle; at most 6 exchanges")
    func row6() {
        var memory = ExchangeMemory()
        for i in 1...8 {
            memory.add(ConversationExchange(driver: "第\(i)句" + String(repeating: "长", count: 80), reply: "好的\(i)",
                                            tools: i == 8 ? ["control_climate ok"] : []), at: .zero)
        }
        #expect(memory.count == 6)
        var later = memory
        let s = later.summary(at: .zero + .seconds(600))
        #expect(s?.exchanges == 6 && s?.ageS == 600)
        #expect(s?.text.hasPrefix("[系统] 接着之前的对话。最近几句：司机「第3句") == true)
        #expect(s?.text.contains("（control_climate ok）") == true)
        #expect(s?.text.hasSuffix("。这句不用回答。") == true)
        #expect(s?.text.contains(String(repeating: "长", count: 60)) == false)  // each text cut to 60
        var old = memory
        #expect(old.summary(at: .zero + .seconds(40 * 60)) == nil)
        #expect(old.count == 0)
        // The summary goes once, as the first note on connect, before the state note.
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), summary: s)
        d.send(.vehicleState(Self.car()))
        d.send(.start)
        let first = d.realtime(.setupComplete)
        let text = Self.notes(first).first ?? ""
        #expect(text.hasPrefix("[系统] 接着之前的对话") && text.contains("车内状态"))
        #expect(first.contains(.diagnostic(.summaryNote(exchanges: 6, ageS: 600))))
        // With a resumption handle: no summary.
        var r = Drive()
        r.state = AgentState(truthfulness: TruthfulnessTuning(), resume: SessionResume(handle: "h"), summary: s)
        r.send(.start)
        #expect(!Self.notes(r.realtime(.setupComplete)).contains { $0.contains("接着之前的对话") })
        // 结束对话 clears.
        memory.clear()
        #expect(memory.summary(at: .zero + .seconds(1)) == nil)
    }

    @Test("T-016p F-09b §6 item 1: a completed exchange gives the driver line, her reply and the tool codes")
    func exchangeEffect() {
        var d = Drive()
        d.connect()
        let out = Self.turn(&d, calls: [climateOn()], reply: "空调开了。")
        let exchanges = out.compactMap { if case .exchange(let e) = $0 { e } else { nil } }
        #expect(exchanges.count == 1)
        #expect(exchanges.first?.tools == ["control_climate ok"])
        #expect(exchanges.first?.reply.contains("空调开了") == true)
    }

    @Test("T-017c F-09b row 7: comfort calls from 讲个笑话 and 好困 run (no NOT_A_CAR_REQUEST, no area wait)")
    func row7() {
        for words in ["讲个笑话", "好困"] {
            var d = Drive()
            d.connect()
            d.send(.speechStarted(recentSpeech: true))
            d.send(.speechStopped)
            d.send(.driverWords(.final(words)))
            d.turn = d.turn.next()
            d.realtime(.responseStarted(d.turn))
            let out = d.realtime(.toolCalls(d.turn, [climateOn()]))
            #expect(out.contains { if case .startTool(_, let c) = $0 { c.name == "control_climate" } else { false } }, "\(words)")
            #expect(!out.contains { if case .provider(.toolResponses) = $0 { true } else { false } }, "\(words)")
        }
        #expect(ToolErrorCode(rawValue: "NOT_A_CAR_REQUEST") == nil)
    }
}
