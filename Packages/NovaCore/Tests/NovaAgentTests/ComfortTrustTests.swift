import Synchronization
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// T-031e: a provider that answers each text with one scripted step, in order.
struct Step: Sendable {
    var call: ToolCall?
    var text: String
    /// End the reply with `audioDone` only (no `responseDone`).
    var audioDoneOnly = false
    /// After the tool responses, this text is the answer.
    var afterTool: String?
}

final class StepProvider: RealtimeProvider, @unchecked Sendable {
    let capabilities = RealtimeCapabilities(serverSpeechEvents: false, clientCancel: false, verbatimRelay: false)
    let events: AsyncStream<ProviderEvent>
    private let continuation: AsyncStream<ProviderEvent>.Continuation
    private let state = Mutex<(connection: Generation, steps: [Step], turn: Int, sent: [String], last: Step?)>((.initial, [], 0, [], nil))
    let onSend: @Sendable (Int) async -> Void

    init(_ steps: [Step], onSend: @escaping @Sendable (Int) async -> Void = { _ in }) {
        (events, continuation) = AsyncStream.makeStream(of: ProviderEvent.self)
        self.onSend = onSend
        state.withLock { $0.steps = steps }
    }

    var sent: [String] { state.withLock { $0.sent } }

    private func emit(_ e: RealtimeEvent) { continuation.yield(ProviderEvent(connection: state.withLock { $0.connection }, event: e)) }
    private func nextTurn() -> TurnID { TurnID(UInt64(state.withLock { $0.turn += 1; return $0.turn })) }

    func sendContextUpdate(systemInstruction: String) async {}
    func connect(_ config: SessionConfig, resume handle: String?, connection: Generation, updateAtSetup: String?) async {
        state.withLock { $0.connection = connection }
        emit(.setupComplete)
    }
    func sendAudio(_ frame: PCMFrame16k) {}
    func sendAudioStreamEnd() async {}
    func sendText(_ turns: [TextTurn], turnComplete: Bool) async {
        let (step, count) = state.withLock { s -> (Step, Int) in
            s.sent.append(turns.last!.text)
            let step = s.steps.isEmpty ? Step(text: "好的。") : s.steps.removeFirst()
            s.last = step
            return (step, s.sent.count)
        }
        await onSend(count)
        let t = nextTurn()
        emit(.responseStarted(t))
        if let call = step.call {
            emit(.toolCalls(t, [call]))
            emit(.audioDone(t))
            emit(.responseDone(t, outcome: .completed))
        } else {
            answer(step.text, t, onlyAudioDone: step.audioDoneOnly)
        }
    }
    func sendToolResponses(_ responses: [ToolResponse]) async {
        let step = state.withLock { $0.last }
        answer(step?.afterTool ?? "好的。", nextTurn(), onlyAudioDone: step?.audioDoneOnly ?? false)
    }
    private func answer(_ text: String, _ t: TurnID, onlyAudioDone: Bool) {
        emit(.responseStarted(t))
        emit(.replyAudio(t, PCMBuffer(sampleRate: 24_000, samples: [1])))
        emit(.replyText(t, text))
        emit(.audioDone(t))
        if !onlyAudioDone { emit(.responseDone(t, outcome: .completed)) }
    }
    func close() async {}
}

private func comfortCase(_ id: String) -> ComfortCase { ComfortCases.all.first { $0.id == id }! }
private let open50 = ToolCall(id: CallID("w1")!, name: "control_window", arguments: ["action": "set", "value": .int(50)])

private func makeRunner(_ provider: any RealtimeProvider, timeout: Int64 = 400) -> ComfortEvalRunner {
    let vehicle = FakeEvalVehicle()
    let port = PolicedVehiclePort(vehicle, speedKmh: { nil })
    let harness = ComfortEvalHarness(reset: { s in vehicle.state.withLock { $0 = s } },
                                     snapshot: { vehicle.state.withLock { $0 } },
                                     tools: ["control_window": VehicleToolExecutor(port: port),
                                             "control_climate": VehicleToolExecutor(port: port)])
    let config = SessionConfig(systemInstruction: PersonaInstruction.modelComfortBase, tools: ToolCatalog.declarations(for: .model))
    return ComfortEvalRunner(provider: provider, config: config, harness: harness, clock: SystemClock(),
                             timeout: .milliseconds(timeout))
}

/// Row 3: an outcome the scorer must pass for `c`.
func goodRun(_ c: ComfortCase) -> ComfortRun {
    var decision = c.expected
    if decision == .act, c.requireAny.isEmpty, c.accepted.contains(.noTool) { decision = .noTool }
    var end = c.start
    var calls: [ComfortCallRecord] = []
    var reply: String
    switch decision {
    case .act:
        for group in c.requireAny {
            for change in group where apply(change, to: &end, c) { break }
        }
        calls = [ComfortCallRecord(name: "control_climate", ok: true, code: nil, data: [:])]
        reply = "嗯，这样应该舒服些。"
    case .ask: reply = "你想调哪一项呢？"
    case .noTool: reply = "这个问题挺有意思。"
    case .refuse:
        calls = [ComfortCallRecord(name: "control_window", ok: false, code: .vehicleBlocked, data: ["blocked": "window_at_speed"])]
        reply = "抱歉，没能操作车窗。"
    }
    if !c.mention.isEmpty { reply += "找个服务区休息一下吧。" }
    if c.silent { reply = "" }
    return ComfortRun(caseID: c.id, attempt: 1, end: end, calls: calls, reply: reply, firstAudioMs: 900)
}

/// One change that is allowed for the case and possible from its start.
private func apply(_ change: ComfortChange, to s: inout ComfortVehicleState, _ c: ComfortCase) -> Bool {
    func facet(_ ch: ComfortChange) -> ComfortFacet {
        switch ch { case .up(let f), .down(let f), .changed(let f): f }
    }
    guard !c.forbidden.contains(facet(change)) else { return false }
    let limit = c.maxWindowPercent ?? CabinLimits.windowMax
    switch change {
    case .up(.windows), .changed(.windows):
        guard let w = WindowID.allCases.first(where: { (s.cabin.windows[$0] ?? 0) < limit }) else { return false }
        s.cabin.windows[w] = limit
    case .down(.windows):
        guard let w = WindowID.allCases.first(where: { (s.cabin.windows[$0] ?? 0) > 0 }) else { return false }
        s.cabin.windows[w] = 0
    case .up(.fan): guard s.climate.fanLevel < ClimateLimits.maxFanLevel else { return false }; s.climate.fanLevel += 1
    case .down(.fan): guard s.climate.fanLevel > ClimateLimits.minFanLevel else { return false }; s.climate.fanLevel -= 1
    case .up(.acPower): guard !s.climate.powerOn else { return false }; s.climate.powerOn = true
    case .down(.acPower): guard s.climate.powerOn else { return false }; s.climate.powerOn = false
    case .up(.temperature):
        guard s.climate.targetTemperatureCelsius < ClimateLimits.maxTemperatureC else { return false }
        s.climate.targetTemperatureCelsius += 1
    case .down(.temperature):
        guard s.climate.targetTemperatureCelsius > ClimateLimits.minTemperatureC else { return false }
        s.climate.targetTemperatureCelsius -= 1
    case .up(.music): guard !s.musicPlaying else { return false }; s.musicPlaying = true
    case .down(.music): guard s.musicPlaying else { return false }; s.musicPlaying = false
    default: return false
    }
    return true
}

@Suite("T-031e F-12 §16 trustworthy comfort test")
struct ComfortTrustTests {
    @Test("Row 1: audioDone ends the reply; audioDone before a tool response keeps waiting; nothing by the limit is slowAnswer")
    func endOfReply() async {
        let joke = comfortCase("joke")
        let done = await makeRunner(StepProvider([Step(text: "好的。", audioDoneOnly: true)]), timeout: 5000).run(joke, attempt: 1)
        #expect(done.problem == nil && done.stages.answerDoneMs != nil && (done.stages.answerDoneMs ?? 9999) < 1000)
        let mosquito = comfortCase("mosquito")
        let tool = await makeRunner(StepProvider([Step(call: open50, text: "", audioDoneOnly: true, afterTool: "车窗开了一半。")]),
                                    timeout: 5000).run(mosquito, attempt: 1)
        #expect(tool.problem == nil && tool.calls.count == 1 && tool.reply == "车窗开了一半。")
        #expect(ComfortScorer.score(mosquito, tool).pass)
        let slow = await makeRunner(QueuedProvider([.noDone]), timeout: 300).run(joke, attempt: 1)
        #expect(slow.problem == .slowAnswer)
    }

    @Test("Row 2: decisions of the real c4fa669 replies")
    func realReplies() {
        #expect(ComfortScorer.textDecision("哈哈，有一天小明问他爸爸：你是不是瞎呀？爸爸说：我看得见你啊。") == .noTool)
        #expect(ComfortScorer.textDecision("请问您想调整哪里呢？是温度、座椅还是车窗？") == .ask)
        #expect(ComfortScorer.textDecision("听起来昨晚肯定很难受，今天车里温度还可以吗？") == .ask)
        #expect(ComfortScorer.textDecision("空调制冷靠的是制冷剂。压缩机把它压成高温高压的气体。冷凝器散热后变成液体。最后在蒸发器里吸热，车里就凉了。") == .noTool)
        #expect(ComfortScorer.textDecision("抱歉，这个我做不到。") == .refuse)
        #expect(ComfortScorer.textDecision("") == .noTool)
    }

    @Test("Row 3: every case has a known good outcome that passes, and a known bad one that fails")
    func knownOutcomes() {
        for c in ComfortCases.all {
            let good = goodRun(c)
            let score = ComfortScorer.score(c, good)
            #expect(score.pass, "\(c.id) good outcome fails: \(score.failure.map(\.code) ?? "")")
            if let f = ComfortFacet.allCases.first(where: c.forbidden.contains) {
                var end = c.start
                var changed = false
                for ch in [ComfortChange.up(f), .down(f)] where !changed { changed = apply(ch, to: &end, ComfortCase(c.id, c.sentence, group: c.group, expected: c.expected, start: c.start)) }
                let bad = ComfortRun(caseID: c.id, attempt: 1, end: end,
                                     calls: [ComfortCallRecord(name: "control_climate", ok: true, code: nil, data: [:])],
                                     reply: "好了。", firstAudioMs: 900)
                if changed { #expect(!ComfortScorer.score(c, bad).pass, "\(c.id) bad outcome passes") }
            } else if !c.requireAny.isEmpty {
                let bad = ComfortRun(caseID: c.id, attempt: 1, end: c.start,
                                     calls: [ComfortCallRecord(name: "control_climate", ok: true, code: nil, data: [:])],
                                     reply: "好了。", firstAudioMs: 900)
                #expect(ComfortScorer.score(c, bad).failure == .missingChange, "\(c.id)")
            }
        }
    }

    @Test("Row 4: 100 cases with the item 5 counts; a disputed case is shown and not scored")
    func theSet() {
        let all = ComfortCases.all
        #expect(all.count == 100)
        let new = all.filter { $0.id.hasPrefix("t3") || $0.id.hasPrefix("h3") }
        #expect(new.count == 34)
        #expect(new.filter(\.heldOut).count >= 20)
        #expect(new.filter { $0.expected == .noTool || $0.expected == .ask }.count >= 12)
        #expect(new.filter { $0.unprompted && $0.group == .comfort }.count >= 10)
        #expect(ComfortCases.newest.count == 20)
        let prompts = ([PersonaInstruction.base, PersonaInstruction.modelComfortBase]
                       + (ToolCatalog.specs + ToolCatalog.modelComfortSpecs).map(\.declaration.description)).joined()
        for c in new where c.heldOut || c.unprompted { #expect(!prompts.contains(c.sentence), "\(c.id) is in a prompt") }
        let trial = ComfortCases.trial
        #expect(trial.count == 12 && Set(trial.map(\.expected)) == Set(ComfortDecision.allCases))
        let c = comfortCase("mosquito")
        let r = ComfortReport(cases: all, runs: [goodRun(c), goodRun(comfortCase("joke"))], disputed: ["mosquito"])
        #expect(r.disputed == ["mosquito"] && r.overall.total == 1 && r.perCase["mosquito"] == nil)
    }

    @Test("Row 5: pass^3, the paired mean and interval by hand, no difference, different builds")
    func comparison() {
        func summary(_ mode: ToolCatalog.ComfortMode, _ build: String, _ per: [String: [Bool]]) -> ComfortSummary {
            var r = ComfortReport(cases: [], runs: [])
            r.perCase = per
            return ComfortSummary(report: r, mode: mode, build: build, date: "2026-11-03")
        }
        // Table: a 3/3, b 0/3, c 3/3. Model: a 3/3, b 3/3, c 0/3 → diffs 0, +100, −100: mean 0, sd 100, se 57.735.
        let t = summary(.table, "x", ["a": [true, true, true], "b": [false, false, false], "c": [true, true, true]])
        let m = summary(.model, "x", ["a": [true, true, true], "b": [true, true, true], "c": [false, false, false]])
        let cmp = ComfortComparison(table: t, model: m)!
        #expect(abs(cmp.meanPoints) < 1e-9)
        #expect(abs(cmp.highPoints - 1.96 * 57.735_026_9) < 1e-3)
        #expect(cmp.noVisibleDifference)
        #expect(cmp.differing.map(\.caseID) == ["b", "c"])
        // Every case +1/3: mean 33.3 with zero spread → a clear difference.
        let m2 = summary(.model, "x", ["a": [true, true, true], "b": [true, false, false], "c": [true, true, true]])
        let t2 = summary(.table, "x", ["a": [true, true, false], "b": [false, false, false], "c": [true, true, false]])
        let c2 = ComfortComparison(table: t2, model: m2)!
        #expect(abs(c2.meanPoints - 100.0 / 3) < 1e-9 && !c2.noVisibleDifference)
        #expect(ComfortComparison(table: t, model: summary(.model, "y", m.perCase)) == nil)
        // pass^3 in the report.
        let joke = comfortCase("joke")
        func run(_ ok: Bool, _ a: Int) -> ComfortRun {
            ComfortRun(caseID: "joke", attempt: a, end: joke.start, calls: [], reply: ok ? "好呀。" : "车窗打开了。", firstAudioMs: 900)
        }
        let r = ComfortReport(cases: ComfortCases.all, runs: [run(true, 1), run(false, 2), run(true, 3)] + Array(repeating: goodRun(comfortCase("acPrinciple")), count: 3))
        #expect(r.allRunsPass.total == 2 && r.allRunsPass.passed == 1)
        #expect(r.allRunsPassByDecision[.noTool]?.passed == 1)
        // A long act reply is counted, not failed.
        var long = goodRun(comfortCase("hot"))
        long = ComfortRun(caseID: long.caseID, attempt: 1, end: long.end, calls: long.calls, reply: "好的。我调低了。还有别的吗。", firstAudioMs: 900)
        #expect(ComfortReport(cases: ComfortCases.all, runs: [long]).tooLong == 1)
    }

    @Test("Row 6: an unbacked claim gets the correction; fixed by a tool, by an honest reply, or not at all")
    func correction() async {
        let c = comfortCase("mosquito")
        let byTool = await makeRunner(StepProvider([Step(text: "车窗打开了。"), Step(call: open50, text: "", afterTool: "车窗开了一半。")]))
            .run(c, attempt: 1)
        #expect(byTool.firstReplyClaim && !ComfortScorer.unbackedClaim(byTool) && ComfortScorer.score(c, byTool).pass)
        let honest = StepProvider([Step(text: "车窗打开了。"), Step(text: "抱歉，刚才我还没有操作。")])
        let h = await makeRunner(honest).run(c, attempt: 1)
        #expect(h.firstReplyClaim && !ComfortScorer.unbackedClaim(h))
        #expect(honest.sent.last == "[系统] 你声称已完成操作，但没有成功的工具结果。请先调用工具，或如实说明。")
        let again = await makeRunner(StepProvider([Step(text: "车窗打开了。"), Step(text: "车窗打开了。")])).run(c, attempt: 1)
        let r = ComfortReport(cases: ComfortCases.all, runs: [byTool, h, again])
        #expect(r.firstReplyClaims == 3 && r.uncorrectedClaims == 1)
    }

    @Test("Row 7: leaving the foreground repeats the run and leaves it out of the score")
    func interrupted() async {
        let box = Mutex<ComfortEvalRunner?>(nil)
        let provider = StepProvider([], onSend: { n in
            if n == 1, let r = box.withLock({ $0 }) { await r.setActive(false); await r.setActive(true) }
        })
        let runner = makeRunner(provider)
        box.withLock { $0 = runner }
        let runs = await runner.runAll([comfortCase("joke")], attempts: 1)
        #expect(runs.map(\.problem) == [.interrupted, nil])
        let r = ComfortReport(cases: ComfortCases.all, runs: runs)
        #expect(r.interrupted == 1 && r.overall.total == 1)
        // Still in the background: every repeat is interrupted, up to maxRepeats, and nothing is scored.
        let away = makeRunner(StepProvider([]))
        await away.setActive(false)
        let none = await away.runAll([comfortCase("joke")], attempts: 1)
        #expect(none.count == ComfortEvalRunner.maxRepeats + 1 && none.allSatisfy { $0.problem == .interrupted })
    }

    @Test("A case short of runs is never pass^3; a stalled correction is counted and scores the final state")
    func shortAndStalled() async {
        let joke = comfortCase("joke")
        let r = ComfortReport(cases: ComfortCases.all, runs: [goodRun(joke)], attempts: 3)
        #expect(r.allRunsPass.total == 0 && r.shortCases == ["joke"])
        let c = comfortCase("mosquito")
        let stalled = await makeRunner(StepProvider([Step(text: "车窗打开了。"), Step(text: "", audioDoneOnly: true)]), timeout: 300)
            .run(c, attempt: 1)
        #expect(stalled.firstReplyClaim)
        #expect(ComfortReport(cases: ComfortCases.all, runs: [stalled]).firstReplyClaims == 1)
    }
}

