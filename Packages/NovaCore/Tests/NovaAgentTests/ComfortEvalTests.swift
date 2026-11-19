import Synchronization
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

private func run(_ c: ComfortCase, end: ComfortVehicleState, calls: [ComfortCallRecord] = [], reply: String,
                 audio: Int? = 900, problem: ComfortRunProblem? = nil) -> ComfortRun {
    ComfortRun(caseID: c.id, attempt: 1, end: end, calls: calls, reply: reply, firstAudioMs: audio, problem: problem)
}

private func ok(_ name: String, _ data: [String: JSONValue] = [:]) -> ComfortCallRecord {
    ComfortCallRecord(name: name, ok: true, code: nil, data: data)
}

private func comfortCase(_ id: String) -> ComfortCase { ComfortCases.all.first { $0.id == id }! }

private func nav(_ destination: String, ok: Bool = true) -> ComfortCallRecord {
    ComfortCallRecord(name: "navigate_to", ok: ok, code: ok ? nil : .noCandidates,
                      data: ok ? ["status": "candidates_listed"] : [:], arguments: ["destination": .string(destination)])
}

/// F-09b §12 item 3: the ten sleepy cases.
private let sleepyIDs = ["drowsy", "drowsyMusicOn", "fallingAsleep", "hEyelids", "hDizzy", "h2EyesClosing", "h2Yawning",
                         "t3Exhausted", "h3Nodding", "h3Foggy"]

@Suite("T-031a F-12 §14 comfort test set and scorer")
struct ComfortEvalTests {
    @Test("F-12 row 1 scorer: pass, forbidden state, wrong decision; two different valid outcomes both pass")
    func scorer() {
        let c = comfortCase("mosquito")
        var windowsOpen = c.start
        for w in WindowID.allCases { windowsOpen.cabin.windows[w] = 50 }
        let table = run(c, end: windowsOpen, calls: [ok("control_window", ["windows": ["front_left": 50]])], reply: "车窗都开了一半")
        #expect(ComfortScorer.score(c, table).pass)
        var fanOn = c.start
        fanOn.climate.powerOn = true
        fanOn.climate.fanLevel = 3
        let model = run(c, end: fanOn, calls: [ok("get_vehicle_state"), ok("control_climate", ["action": "power_on"])],
                        reply: "空调打开了，风量调到了3档")
        #expect(ComfortScorer.score(c, model).pass)
        var warmer = fanOn
        warmer.climate.targetTemperatureCelsius = 26
        #expect(ComfortScorer.score(c, run(c, end: warmer, calls: [ok("control_climate")], reply: "好的")).failure
                == .forbiddenChange(.temperature))
        #expect(ComfortScorer.score(c, run(c, end: c.start, reply: "蚊子很烦人")).failure == .wrongDecision(.noTool))
        // A claim with no ok result is unbacked; one naming windows needs control_window.
        #expect(ComfortScorer.score(c, run(c, end: c.start, reply: "车窗打开了")).failure == .unbackedClaim)
        #expect(ComfortScorer.score(c, run(c, end: fanOn, calls: [ok("control_climate")], reply: "车窗打开了")).failure
                == .unbackedClaim)
        #expect(ComfortScorer.score(c, run(c, end: c.start, reply: "", problem: .noAnswer)).failure == .problem(.noAnswer))
        // An act that changes nothing required fails.
        let seatOnly = run(c, end: c.start, calls: [ok("control_window", ["action": "get_state"]), ok("control_climate")],
                           reply: "好的")
        #expect(ComfortScorer.score(c, seatOnly).failure == .missingChange)
    }

    @Test("F-12 row 1 decisions: ask, refuse, noTool, blocked, mention")
    func decisions() {
        let ask = comfortCase("closeWhat")
        #expect(ComfortScorer.score(ask, run(ask, end: ask.start, reply: "要关空调、车窗还是音乐？")).pass)
        let joke = comfortCase("joke")
        #expect(ComfortScorer.score(joke, run(joke, end: joke.start, reply: "有一天小明去买菜。")).pass)
        let fast = comfortCase("openAllFast")
        let blocked = ComfortCallRecord(name: "control_window", ok: false, code: .vehicleBlocked, data: ["action": "open"])
        let refused = run(fast, end: fast.start, calls: [blocked], reply: "车速太快，车窗没有打开。")
        #expect(ComfortScorer.decision(refused) == .refuse)
        #expect(ComfortScorer.score(fast, refused).pass)
        var wide = fast.start
        for w in WindowID.allCases { wide.cabin.windows[w] = 50 }
        #expect(ComfortScorer.score(fast, run(fast, end: wide, calls: [ok("control_window")], reply: "好")).failure
                == .windowAboveLimit)
        // F-09b §12 item 3 (T-031k): a sleepy driver passes with one navigate_to to nearby rest places, ≤ 1 sentence.
        let drowsy = comfortCase("drowsy")
        let coffee = nav("附近的咖啡店")
        #expect(ComfortScorer.score(drowsy, run(drowsy, end: drowsy.start, calls: [coffee], reply: "找个地方休息一下吧。")).pass)
        #expect(ComfortScorer.score(drowsy, run(drowsy, end: drowsy.start, reply: "")).failure == .noRestPlaces)
        var awake = drowsy.start
        awake.musicPlaying = true
        let music = run(drowsy, end: awake, calls: [ok("control_music", ["status": "playing"]), coffee], reply: "")
        #expect(ComfortScorer.score(drowsy, music).failure == .wrongDecision(.act))
    }

    @Test("F-12 row 2 the set: 55+ cases, every decision, 15+ held out, 10+ unprompted, unique ids")
    func theSet() {
        let all = ComfortCases.all
        #expect(all.count >= 55)
        #expect(Set(all.map(\.id)).count == all.count)
        #expect(Set(all.map(\.expected)) == Set(ComfortDecision.allCases))
        #expect(all.filter(\.heldOut).count >= 15)
        #expect(all.filter { !$0.heldOut }.count >= 40)
        #expect(all.filter { $0.unprompted && $0.group == .comfort }.count >= 10)
        let sentences = Set(all.map(\.sentence))
        for s in ["有蚊子", "蚊子还没走", "蚊子出去了", "有点闷", "有异味", "好困", "车里飞进来一只蚊子", "有烟味", "我快睡着了",
                  "打开空调", "车窗开一半", "再冷一点", "关窗", "帮我关一下", "讲个笑话", "蚊子是什么动物", "我朋友车里有蚊子"] {
            #expect(sentences.contains(s), "missing \(s)")
        }
        #expect(all.contains { $0.group == .blocked && $0.start.speedKmh ?? 0 > VehicleActionPolicy.windowSpeedKmh })
        // Unprompted wordings appear in no prompt or tool description.
        let prompts = ([PersonaInstruction.base, PersonaInstruction.base]
                       + (ToolCatalog.specs + ToolCatalog.specs).map(\.declaration.description)).joined()
        for c in all where c.unprompted { #expect(!prompts.contains(c.sentence), "\(c.id) is prompted") }
    }

    @Test("F-12 item 5 report: tallies by decision and set, times, and a log line with no reply text")
    func report() {
        let a = comfortCase("joke"), b = comfortCase("hColleagueSmoke")
        let runs = [run(a, end: a.start, reply: "笑话一则", audio: 800), run(b, end: b.start, reply: "车窗打开了", audio: 1500),
                    run(a, end: a.start, reply: "再来一个", audio: 1100)]
        let r = ComfortReport(cases: ComfortCases.all, runs: runs)
        #expect(r.overall.passed == 2 && r.overall.total == 3)
        #expect(r.heldOut.total == 1 && r.heldOut.passed == 0)
        #expect(r.tuning.passed == 2)
        #expect(r.medianFirstAudioMs == 1100 && r.worstFirstAudioMs == 1500)
        #expect(r.unbackedClaims == 1)
        #expect(r.failures.map(\.caseID) == ["hColleagueSmoke"])
        let line = r.logLines().joined(separator: "\n")
        #expect(line.contains("overall=2/3"))
        #expect(line.contains("comfortEvalFailure hColleagueSmoke#1:unbackedClaim"))
        for run in runs { #expect(!line.contains(run.reply)) }
    }

    @Test("T-031c F-09b row 1: base is the model base with the §3 item 3 rule 5, within maxBaseCharacters")
    func prompt() {
        let base = PersonaInstruction.base
        #expect(!base.contains("车内场景（有蚊子、闷）"))
        #expect(!base.contains("有点热、太热了：调低一度温度"))
        #expect(base.contains("5. 司机说车里的感受或情况：按车内状态选一个合理的小动作直接做，不要反问。要做动作就先调用工具。做了就用一句话说改成了什么（例如「空调调到24度了」）；司机说「不用」「改回去」「刚才那个不要」就调用 undo_last_change。只是提到别处的事或问知识时不做任何操作。只说真正做成的，没做成的要说。"))
        #expect(!base.contains("get_vehicle_state"))
        #expect(base.contains(PersonaInstruction.sleepySentence) && !base.contains("不要说话，不回应"))
        #expect(base.contains("座位有点高：座椅降低一级。"))
        #expect(base.count <= PersonaInstruction.maxBaseCharacters, "\(base.count)")
        for search in [false, true] {
            #expect(PersonaInstruction.base(base, webSearch: search).count <= PersonaInstruction.maxBaseCharacters)
        }
    }
}

/// A provider that answers each typed case with one tool call, then a sentence.
final class ScriptedProvider: RealtimeProvider, @unchecked Sendable {
    let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false)
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let state = Mutex<(connection: Generation, sent: [[TextTurn]], configs: Int, closes: Int)>((.initial, [], 0, 0))
    let script: @Sendable (String) -> (ToolCall?, String)

    init(script: @escaping @Sendable (String) -> (ToolCall?, String)) {
        self.script = script
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self)
    }

    var sent: [[TextTurn]] { state.withLock { $0.sent } }
    var closes: Int { state.withLock { $0.closes } }

    private func emit(_ e: RealtimeEvent) { continuation.yield(ProviderEvent(connection: state.withLock { $0.connection }, event: e)) }

    func connect(_ config: SessionConfig, resume handle: String?, connection: Generation) async {
        state.withLock { $0.connection = connection; $0.configs += 1 }
        emit(.setupComplete)
    }
    func sendAudio(_ frame: PCMFrame16k) {}
    func sendAudioStreamEnd() async {}
    func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        state.withLock { $0.sent.append(turns) }
        let (call, text) = script(turns.last!.text)
        if let call {
            emit(.toolCalls(TurnID(1), [call]))
            emit(.responseDone(TurnID(1), outcome: .completed))
        } else {
            answer(text)
        }
    }
    func sendToolResponses(_ responses: [ToolResponse]) async {
        let text = script(sent.last!.last!.text).1
        answer(text)
    }
    private func answer(_ text: String) {
        emit(.replyAudio(TurnID(2), PCMBuffer(sampleRate: 24_000, samples: [1])))
        emit(.replyText(TurnID(2), text))
        emit(.responseDone(TurnID(2), outcome: .completed))
    }
    func close() async { state.withLock { $0.closes += 1 } }
}

final class FakeEvalVehicle: VehicleControlPort, @unchecked Sendable {
    let state = Mutex(ComfortVehicleState.default)
    var backendLabel: String { "fake" }
    func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState> {
        .success(state.withLock { $0.climate.powerOn = on; return $0.climate }, limitReached: false)
    }
    func setCabinTemperature(_ c: Double) async -> VehicleActionResult<ClimateState> {
        .success(state.withLock { $0.climate.targetTemperatureCelsius = c; return $0.climate }, limitReached: false)
    }
    func changeCabinTemperature(_ d: Double) async -> VehicleActionResult<ClimateState> {
        .success(state.withLock { $0.climate.targetTemperatureCelsius += d; return $0.climate }, limitReached: false)
    }
    func setFanLevel(_ l: Int) async -> VehicleActionResult<ClimateState> {
        .success(state.withLock { $0.climate.fanLevel = l; return $0.climate }, limitReached: false)
    }
    func changeFanLevel(_ d: Int) async -> VehicleActionResult<ClimateState> {
        .success(state.withLock { $0.climate.fanLevel += d; return $0.climate }, limitReached: false)
    }
    func climateState() async -> ClimateState { state.withLock { $0.climate } }
    func setWindows(_ ws: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState> {
        .success(state.withLock { s in for w in ws { s.cabin.windows[w] = openPercent }; return s.cabin }, limitReached: false)
    }
    func changeWindows(_ ws: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState> {
        .success(state.withLock { s in for w in ws { s.cabin.windows[w, default: 0] += deltaPercent }; return s.cabin },
                 limitReached: false)
    }
    func setSeatHeight(_ seat: SeatID, level: Int) async -> VehicleActionResult<CabinState> { .unsupported("seat") }
    func changeSeatHeight(_ seat: SeatID, delta: Int) async -> VehicleActionResult<CabinState> { .unsupported("seat") }
    func cabinState() async -> CabinState { state.withLock { $0.cabin } }
}

@Suite("T-031a F-12 §14 item 4 runner")
struct ComfortEvalRunnerTests {
    @Test("F-12 item 4 each run: reset vehicle, new session, history then the sentence, tools behind the policy, scored")
    func runs() async {
        let vehicle = FakeEvalVehicle()
        let provider = ScriptedProvider { sentence in
            switch sentence {
            case "有蚊子":
                (ToolCall(id: CallID("w1")!, name: "control_window", arguments: ["action": "set", "value": .int(50)]),
                 "车窗都开了一半。")
            case "车窗全打开":
                (ToolCall(id: CallID("w2")!, name: "control_window", arguments: ["action": "open"]), "车速太快，车窗没有打开。")
            case "蚊子出去了，关上吧":
                (ToolCall(id: CallID("s1")!, name: "run_scenario", arguments: ["name": "mosquito_done"]), "车窗关好了。")
            default: (nil, "好的。")
            }
        }
        let speed = Mutex<Double?>(nil)
        let port = PolicedVehiclePort(vehicle, speedKmh: { speed.withLock { $0 } })
        let harness = ComfortEvalHarness(
            reset: { s in vehicle.state.withLock { $0 = s }; speed.withLock { $0 = s.speedKmh } },
            snapshot: { vehicle.state.withLock { $0 } },
            tools: ["control_window": VehicleToolExecutor(port: port), "control_climate": VehicleToolExecutor(port: port)])
        let config = SessionConfig(systemInstruction: PersonaInstruction.base,
                                   tools: ToolCatalog.declarations)
        let runner = ComfortEvalRunner(provider: provider, config: config, harness: harness, clock: SystemClock(),
                                       timeout: .seconds(5))
        let cases = ["mosquito", "openAllFast", "mosquitoGoneClose"].map(comfortCase)
        let runs = await runner.runAll(cases, attempts: 2)
        #expect(runs.count == 6)
        #expect(provider.closes == 6)
        #expect(runs.allSatisfy { $0.problem == nil && $0.firstAudioMs != nil })
        let mosquito = runs[0]
        #expect(mosquito.calls.map(\.ok) == [true])
        #expect(ComfortScorer.score(cases[0], mosquito).pass)
        // Reset per run: the second attempt starts closed again.
        #expect(runs[1].end.cabin.windows[.frontLeft] == 50)
        // At 120 km/h the policy blocks the open; the windows stay closed and the refusal passes.
        let fast = runs[2]
        #expect(fast.calls.first?.code == .vehicleBlocked)
        #expect(fast.end.cabin.windows.values.allSatisfy { $0 == 0 })
        #expect(ComfortScorer.score(cases[1], fast).pass)
        // A tool the session did not declare (run_scenario in model mode) is refused as unknown, and history goes first.
        #expect(runs[4].calls.first?.code == .unknownTool)
        // F-09b §5: the start state's note goes just before the sentence.
        let sent = provider.sent[4].map(\.text)
        #expect(sent.count == 4 && sent[0] == "有蚊子" && sent[1] == "车窗都开了一半，让蚊子飞出去。" && sent[3] == "蚊子出去了，关上吧")
        #expect(sent[2].hasPrefix("[系统] 车内状态：") && sent[2].contains("车窗 主驾50%"))
        let report = ComfortReport(cases: ComfortCases.all, runs: runs)
        #expect(report.blocked == 2)
    }
}

@Suite("T-031k F-09b §12 sleepy driver: rest suggestion and nearby places")
struct SleepyRestTests {
    @Test("F-09b §12 row 1: the base has item 1's sentence, not the silence; within maxBaseCharacters")
    func base() {
        let sentence = "司机说累、犯困：不要调空调、车窗、座椅或音乐。用一句话建议找地方休息，并调用 navigate_to，destination=附近的咖啡店（在高速上用 附近的服务区），让司机在屏幕上选；司机没选就不开始导航。"
        #expect(PersonaInstruction.sleepySentence == sentence)
        let base = PersonaInstruction.base
        #expect(base.contains("。" + sentence + "座位有点高"))
        #expect(!base.contains("不要说话，不回应"))
        for search in [false, true] {
            let text = PersonaInstruction.base(base, webSearch: search)
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(search) \(text.count)")
        }
    }

    @Test("F-09b §12 row 2: the ten sleepy cases expect navigate_to to nearby rest places, forbid every facet, not silent; whyDrowsy unchanged")
    func definitions() {
        let cases = ComfortCases.all.filter(\.restPlaces)
        #expect(Set(cases.map(\.id)) == Set(sleepyIDs) && cases.count == 10)
        for c in cases {
            #expect(c.forbidden == Set(ComfortFacet.allCases), "\(c.id)")
            #expect(c.accepted == [.noTool, .ask], "\(c.id)")
            for d in ["附近的咖啡店", "附近的服务区", "附近找个地方休息"] {
                #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav(d)], reply: "找个地方休息一下吧。")).pass, "\(c.id) \(d)")
            }
            // Speaking passes now (the old `spoke` failure is gone); more than one sentence does not.
            #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav("附近的咖啡店")], reply: "累了吧。去喝杯咖啡吧。"))
                .failure == .longReply)
            #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav("咖啡店")], reply: "休息一下吧。")).failure
                    == .noRestPlaces)
            #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav("附近的加油站")], reply: "休息一下吧。")).failure
                    == .noRestPlaces)
            #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav("附近的咖啡店"), nav("附近的服务区")],
                                               reply: "休息一下吧。")).failure == .noRestPlaces)
            var cooler = c.start
            cooler.climate.targetTemperatureCelsius -= 1
            #expect(!ComfortScorer.score(c, run(c, end: cooler, calls: [ok("control_climate"), nav("附近的咖啡店")],
                                                reply: "休息一下吧。")).pass, "\(c.id)")
        }
        let why = comfortCase("whyDrowsy")
        #expect(!why.restPlaces && why.expected == .noTool && why.accepted == [.noTool] && why.forbidden == Set(ComfortFacet.allCases))
        #expect(ComfortScorer.score(why, run(why, end: why.start, reply: "长时间开车容易疲劳。")).pass)
    }

    @Test("F-09b §12 row 2 (review): refusal words, 已为你找到 and a failed car call")
    func reviewProbes() async {
        for c in ComfortCases.all where c.restPlaces {
            for reply in ["开车犯困不安全，找个地方休息一下吧。", "不行就找个服务区歇会儿吧。", "导航暂时还不能用，找个地方休息一下吧。",
                          "已为你找到附近的咖啡店，选一个休息一下吧。"] {
                #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [nav("附近的咖啡店")], reply: reply)).pass, "\(c.id) \(reply)")
            }
            let failedCar = ComfortCallRecord(name: "control_climate", ok: false, code: .vehicleBlocked, data: [:])
            #expect(ComfortScorer.score(c, run(c, end: c.start, calls: [failedCar, nav("附近的咖啡店")], reply: "休息一下吧。"))
                .failure == .wrongDecision(.refuse))
        }
        // A claim with no ok navigate_to is still unbacked; a car claim is unbacked even with one.
        let d = comfortCase("drowsy")
        #expect(ComfortScorer.unbackedClaim(run(d, end: d.start, reply: "已为你找到附近的咖啡店。")))
        #expect(ComfortScorer.unbackedClaim(run(d, end: d.start, calls: [nav("附近的咖啡店")], reply: "空调已经打开了。")))
        // The eval stub answers like the real tool's candidate list.
        let r = await ComfortRestPlacesStub().execute(ToolCall(id: CallID("1")!, name: "navigate_to",
                                                                 arguments: .object(["destination": "附近的咖啡店"])))
        #expect(r.ok && r.data["status"] == "candidates_listed")
    }

    @Test("F-09b §12 row 4: navigate_to finds nothing; one sentence suggesting a rest passes with no route")
    func noResults() {
        for c in ComfortCases.all where c.restPlaces {
            let failed = run(c, end: c.start, calls: [nav("附近的咖啡店", ok: false)], reply: "附近没找到咖啡店，找个安全的地方停下来休息一下吧。")
            #expect(ComfortScorer.score(c, failed).pass, "\(c.id)")
        }
    }
}
