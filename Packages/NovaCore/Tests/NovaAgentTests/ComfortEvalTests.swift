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

@Suite("T-031a F-12 §14 comfort test set and scorer")
struct ComfortEvalTests {
    @Test("F-12 row 1 scorer: pass, forbidden state, wrong decision; two different valid outcomes both pass")
    func scorer() {
        let c = comfortCase("mosquito")
        var windowsOpen = c.start
        for w in WindowID.allCases { windowsOpen.cabin.windows[w] = 50 }
        let table = run(c, end: windowsOpen, calls: [ok("run_scenario", ["done": ["车窗开到50%"]])], reply: "车窗都开了一半")
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
        // F-12 §20 row 3: a sleepy driver passes only with no action and no words.
        let drowsy = comfortCase("drowsy")
        #expect(ComfortScorer.score(drowsy, run(drowsy, end: drowsy.start, reply: "")).pass)
        #expect(ComfortScorer.score(drowsy, run(drowsy, end: drowsy.start, reply: "累了的话找个服务区休息一下吧")).failure
                == .spoke)
        let scenario = ComfortCallRecord(name: "run_scenario", ok: true, code: nil, data: ["scenario": "drowsy"])
        #expect(ComfortScorer.score(drowsy, run(drowsy, end: drowsy.start, calls: [scenario], reply: "")).pass)
        var awake = drowsy.start
        awake.musicPlaying = true
        let music = run(drowsy, end: awake, calls: [ok("control_music", ["status": "playing"])], reply: "")
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
        let prompts = ([PersonaInstruction.base, PersonaInstruction.modelComfortBase]
                       + (ToolCatalog.specs + ToolCatalog.modelComfortSpecs).map(\.declaration.description)).joined()
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
        let line = r.logLines(mode: .table).joined(separator: "\n")
        #expect(line.contains("overall=2/3"))
        #expect(line.contains("comfortEvalFailure mode=table hColleagueSmoke#1:unbackedClaim"))
        for run in runs { #expect(!line.contains(run.reply)) }
    }

    @Test("F-12 rows 3-4 prompt: off is today's base; on drops the scenario words and stays within the limit")
    func prompt() {
        #expect(PersonaInstruction.base(for: .table) == PersonaInstruction.base)
        let on = PersonaInstruction.base(for: .model)
        #expect(on != PersonaInstruction.base)
        #expect(!on.contains("车内场景（有蚊子、闷）"))
        #expect(!on.contains("有点热、太热了：调低一度温度"))
        #expect(on.contains(PersonaInstruction.modelComfortRule))
        #expect(on.contains("get_vehicle_state"))
        #expect(on.contains("我朋友车里有蚊子"))
        #expect(on.contains(PersonaInstruction.sleepySentence))
        #expect(on.count <= PersonaInstruction.maxBaseCharacters)
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

    func sendContextUpdate(systemInstruction: String) async {}
    func connect(_ config: SessionConfig, resume handle: String?, connection: Generation, updateAtSetup: String?) async {
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
        let config = SessionConfig(systemInstruction: PersonaInstruction.modelComfortBase,
                                   tools: ToolCatalog.declarations(for: .model))
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
        #expect(provider.sent[4].map(\.text) == ["有蚊子", "车窗都开了一半，让蚊子飞出去。", "蚊子出去了，关上吧"])
        let report = ComfortReport(cases: ComfortCases.all, runs: runs)
        #expect(report.blocked == 2)
    }
}
