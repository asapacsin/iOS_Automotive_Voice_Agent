import Synchronization
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// One connection's behaviour for the T-031d runner tests.
enum SessionScript: Sendable {
    case fail, answer, silent, toolThenSilent, noDone, rejected, dropMidAnswer, emptyTurn
    case slowConnect(ms: Int64, answerAfterMs: Int64)
}

final class QueuedProvider: RealtimeProvider, @unchecked Sendable {
    let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false)
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let state = Mutex<(connection: Generation, scripts: [SessionScript], current: SessionScript, connects: Int)>(
        (.initial, [], .answer, 0))

    init(_ scripts: [SessionScript]) {
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self)
        state.withLock { $0.scripts = scripts }
    }

    var connects: Int { state.withLock { $0.connects } }

    private func emit(_ e: RealtimeEvent, on c: Generation) { continuation.yield(ProviderEvent(connection: c, event: e)) }
    private var current: (Generation, SessionScript) { state.withLock { ($0.connection, $0.current) } }

    func connect(_ config: SessionConfig, resume handle: String?, connection: Generation) async {
        let script = state.withLock { s -> SessionScript in
            s.connection = connection
            s.connects += 1
            s.current = s.scripts.isEmpty ? .answer : s.scripts.removeFirst()
            return s.current
        }
        switch script {
        case .fail: emit(.failed(RealtimeError(.connection)), on: connection)
        case .slowConnect(let ms, _):
            Task {
                try? await Task.sleep(for: .milliseconds(ms))
                self.emit(.setupComplete, on: connection)
            }
        default: emit(.setupComplete, on: connection)
        }
    }
    func sendAudio(_ frame: PCMFrame16k) {}
    func sendAudioStreamEnd() async {}
    func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        let (c, script) = current
        switch script {
        case .answer: answer(c)
        case .slowConnect(_, let after):
            Task {
                try? await Task.sleep(for: .milliseconds(after))
                self.answer(c)
            }
        case .toolThenSilent:
            emit(.responseStarted(TurnID(1)), on: c)
            emit(.toolCalls(TurnID(1), [ToolCall(id: CallID("w1")!, name: "control_window",
                                                  arguments: ["action": "set", "value": .int(50)])]), on: c)
            emit(.responseDone(TurnID(1), outcome: .completed), on: c)
        case .noDone:
            emit(.responseStarted(TurnID(1)), on: c)
            emit(.replyAudio(TurnID(1), PCMBuffer(sampleRate: 24_000, samples: [1])), on: c)
        case .rejected: emit(.turnEnded(.responseRejected), on: c)
        case .dropMidAnswer:
            emit(.responseStarted(TurnID(1)), on: c)
            emit(.replyAudio(TurnID(1), PCMBuffer(sampleRate: 24_000, samples: [1])), on: c)
            emit(.failed(RealtimeError(.quota)), on: c)
        case .emptyTurn:
            emit(.responseStarted(TurnID(1)), on: c)
            emit(.responseDone(TurnID(1), outcome: .completed), on: c)
        case .silent, .fail: break
        }
    }
    func sendToolResponses(_ responses: [ToolResponse]) async {}
    private func answer(_ c: Generation) {
        emit(.responseStarted(TurnID(2)), on: c)
        emit(.replyAudio(TurnID(2), PCMBuffer(sampleRate: 24_000, samples: [1])), on: c)
        emit(.replyText(TurnID(2), "好的。"), on: c)
        emit(.responseDone(TurnID(2), outcome: .completed), on: c)
    }
    func close() async {}
}

private func comfortCase(_ id: String) -> ComfortCase { ComfortCases.all.first { $0.id == id }! }

private func runner(_ provider: QueuedProvider, timeout: Int64 = 300, connect: Int64 = 1000) -> ComfortEvalRunner {
    let vehicle = FakeEvalVehicle()
    let port = PolicedVehiclePort(vehicle, speedKmh: { nil })
    let harness = ComfortEvalHarness(reset: { s in vehicle.state.withLock { $0 = s } },
                                     snapshot: { vehicle.state.withLock { $0 } },
                                     tools: ["control_window": VehicleToolExecutor(port: port)])
    let config = SessionConfig(systemInstruction: PersonaInstruction.modelComfortBase, tools: ToolCatalog.declarations(for: .model))
    return ComfortEvalRunner(provider: provider, config: config, harness: harness, clock: SystemClock(),
                             timeout: .milliseconds(timeout), connectTimeout: .milliseconds(connect))
}

@Suite("T-031d F-12 §15 tuning round")
struct ComfortTuningTests {
    @Test("Row 1: retried session, infrastructure, noAnswer, stuckAfterTool, slowAnswer, and a rejected turn")
    func causes() async {
        let c = comfortCase("joke")
        let once = QueuedProvider([.fail, .answer])
        let retried = await runner(once).run(c, attempt: 1)
        #expect(retried.problem == nil && once.connects == 2)
        #expect(ComfortScorer.score(c, retried).pass)

        let twice = QueuedProvider([.fail, .fail])
        #expect(await runner(twice).run(c, attempt: 1).problem == .infrastructure)
        #expect(await runner(QueuedProvider([.silent])).run(c, attempt: 1).problem == .noAnswer)
        let stuck = await runner(QueuedProvider([.toolThenSilent])).run(comfortCase("mosquito"), attempt: 1)
        #expect(stuck.problem == .stuckAfterTool && stuck.calls.count == 1 && stuck.stages.firstToolMs != nil)
        #expect(await runner(QueuedProvider([.noDone])).run(c, attempt: 1).problem == .slowAnswer)
        // A rejected turn ends at once with its reason, not after the timeout.
        let rejected = await runner(QueuedProvider([.rejected]), timeout: 5000).run(c, attempt: 1)
        #expect(rejected.problem == .noAnswer && rejected.turnEnd == .responseRejected)
        // No setupComplete within the connect limit is a session failure, retried, then infrastructure.
        let hang = await runner(QueuedProvider([.slowConnect(ms: 400, answerAfterMs: 0), .slowConnect(ms: 400, answerAfterMs: 0)]),
                                connect: 100).run(c, attempt: 1)
        #expect(hang.problem == .infrastructure)
        // A session that drops mid-answer is the connection: retried, then infrastructure.
        #expect(await runner(QueuedProvider([.dropMidAnswer, .dropMidAnswer])).run(c, attempt: 1).problem == .infrastructure)
        // An empty turn is no answer, not a noTool pass.
        #expect(await runner(QueuedProvider([.emptyTurn])).run(c, attempt: 1).problem == .noAnswer)
    }

    @Test("Row 2: a slow connect inside its limit is not a timeout; the answer timer starts at sendText")
    func timerAtSend() async {
        let c = comfortCase("joke")
        let r = await runner(QueuedProvider([.slowConnect(ms: 250, answerAfterMs: 150)]), timeout: 300, connect: 1000)
            .run(c, attempt: 1)
        #expect(r.problem == nil)
        #expect((r.firstAudioMs ?? 0) >= 100 && (r.firstAudioMs ?? 1000) < 300)
    }

    @Test("Row 3: comfort and all stage percentiles, infrastructure above 5% is not valid, blocks listed")
    func report() {
        let comfort = comfortCase("mosquito"), other = comfortCase("joke"), fast = comfortCase("openAllFast")
        func run(_ c: ComfortCase, _ ms: Int, problem: ComfortRunProblem? = nil, calls: [ComfortCallRecord] = []) -> ComfortRun {
            ComfortRun(caseID: c.id, attempt: 1, end: c.start, calls: calls, reply: "好",
                       stages: ComfortStages(firstEventMs: ms, firstAudioMs: ms), problem: problem)
        }
        let block = ComfortCallRecord(name: "control_window", ok: false, code: .vehicleBlocked,
                                      data: ["action": "open", "blocked": "window_at_speed"])
        let runs = [run(comfort, 1000), run(comfort, 3000), run(other, 9000), run(fast, 500, calls: [block]),
                    run(other, 0, problem: .infrastructure)]
        let r = ComfortReport(cases: ComfortCases.all, runs: runs)
        #expect(r.stagesComfort[.firstAudio] == ComfortReport.Percentiles([1000, 3000]))
        #expect(r.stagesComfort[.firstAudio]?.worst == 3000)
        #expect(r.stagesAll[.firstAudio]?.worst == 9000)
        #expect(r.overall.total == 4)
        #expect(r.infrastructure == ["joke#1"])
        #expect(!r.valid)
        #expect(r.blocks == [ComfortReport.Block(caseID: "openAllFast", attempt: 1, tool: "control_window", rule: "window_at_speed")])
        let line = r.logLines(mode: .model).joined(separator: "\n")
        #expect(line.contains("valid=false"))
        #expect(line.contains("comfortEvalBlock mode=model openAllFast#1 control_window window_at_speed"))
        #expect(line.contains("firstAudioMs=all:"))
        #expect(!line.contains("好"))
        // 1 of 21 infrastructure (under 5%) is valid.
        let many = (0..<20).map { _ in run(other, 100) } + [run(other, 0, problem: .infrastructure)]
        #expect(ComfortReport(cases: ComfortCases.all, runs: many).valid)
    }

    @Test("Row 4 (§15): 100 cases now; earlier held-out cases unchanged; no prompt or description holds a held-out sentence")
    func theSet() {
        let all = ComfortCases.all
        #expect(all.count == 100)
        let fresh = all.filter { ComfortCases.fresh.contains($0.id) }
        #expect(fresh.count == 10 && fresh.allSatisfy(\.heldOut))
        #expect(fresh.filter { $0.unprompted && $0.group == .comfort }.count >= 6)
        let earlier = all.filter { $0.heldOut && !ComfortCases.fresh.contains($0.id) && !ComfortCases.newest.contains($0.id) }.map { "\($0.id)=\($0.sentence)" }
        #expect(earlier == ["hMoldy=车里一股霉味", "hEyelids=眼皮在打架", "hNoAir=感觉透不过气", "hFreezing=冻死了",
                            "hDizzy=脑袋昏昏沉沉的", "hStale=空气不太新鲜", "hMosquitoBite=被蚊子咬了一口", "hRearHalf=后排车窗开一半",
                            "hTemp20=温度调到20度", "hWarmerAtMax=再热一点", "hOpenWhat=帮我开一下",
                            "hColleagueSmoke=我同事说他车里全是烟味", "hMosquitoSeason=蚊子一般几月份最多", "hStuffyFast=有点闷",
                            "hCloseBroken=关窗"])
        let prompts = ([PersonaInstruction.modelComfortBase]
                       + ToolCatalog.modelComfortSpecs.map(\.declaration.description)).joined()
        // 有点闷 and 关窗 are shared with tuning cases (scenario and direct wordings) and were held out for state, not words.
        for c in all where c.heldOut && !["hStuffyFast", "hCloseBroken"].contains(c.id) {
            #expect(!prompts.contains(c.sentence), "\(c.id) is in a prompt")
        }
    }

    @Test("Row 5: setting off keeps today's catalog and prompt")
    func settingOff() {
        #expect(ToolCatalog.declarations(for: .table) == ToolCatalog.declarations)
        #expect(PersonaInstruction.base(for: .table) == PersonaInstruction.base)
        #expect(PersonaInstruction.modelComfortBase.count <= PersonaInstruction.maxBaseCharacters)
        #expect(PersonaInstruction.modelComfortRule.contains("服务区"))
    }
}
