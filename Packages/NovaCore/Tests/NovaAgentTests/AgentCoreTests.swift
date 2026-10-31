import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

/// Drives the pure `AgentState` with scripted provider events and records every effect.
struct Drive {
    var state = AgentState()
    var now = NovaInstant.zero
    var effects: [AgentEffect] = []
    var turn = TurnID.initial

    @discardableResult
    mutating func send(_ event: AgentEvent) -> [AgentEffect] {
        let out = state.handle(event, at: now)
        effects += out
        return out
    }

    @discardableResult
    mutating func realtime(_ event: RealtimeEvent) -> [AgentEffect] {
        send(.realtime(event, connection: state.session.connection))
    }

    /// Connected and listening.
    mutating func connect() {
        send(.start)
        realtime(.setupComplete)
    }

    /// Fires every pipeline timer of `kind` scheduled so far, at its deadline.
    @discardableResult
    mutating func fire(_ kind: PipelineTimer.Kind) -> [AgentEffect] {
        let pending = effects.compactMap { effect -> (PipelineTimer, NovaInstant)? in
            if case .schedule(.pipeline(let t), let at) = effect, t.kind == kind { (t, at) } else { nil }
        }
        guard let (timer, at) = pending.last else { return [] }
        now = at
        return send(.timer(.pipeline(timer)))
    }
}

func climateOn(_ id: String = "call_1") -> ToolCall {
    ToolCall(id: CallID(id)!, name: "control_climate", arguments: ["action": "power_on"])
}

func spoken(_ effects: [AgentEffect]) -> String {
    effects.compactMap { if case .speak(let s) = $0 { s } else { nil } }.joined()
}

func index(_ effects: [AgentEffect], _ match: (AgentEffect) -> Bool) -> Int? { effects.firstIndex(where: match) }

@Suite("T-023 AgentCore W1-W3 without audio")
struct AgentWalkthroughTests {
    @Test("W1 normal turn: one control_climate runs, its ok result goes back, and only then the claim is spoken")
    func w1() {
        var d = Drive()
        d.connect()
        #expect(d.state.view.chip == .listening)
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: false))
        d.send(.speechStopped)
        #expect(d.state.view.chip == .processing)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("打开空调", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        let claim = d.realtime(.replyText(t1, "空调已经为您打开了。"))
        #expect(spoken(claim).isEmpty)  // held until the result proves it (I-1)
        let starts = d.effects.filter { if case .startTool = $0 { true } else { false } }
        #expect(starts == [.startTool(t1, climateOn())])

        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true, "temperature_c": 24])))
        d.realtime(.audioDone(t1))
        d.realtime(.responseDone(t1, outcome: .completed))
        let response = index(d.effects) { if case .provider(.toolResponses) = $0 { true } else { false } }
        let firstSpeak = index(d.effects) { if case .speak = $0 { true } else { false } }
        #expect(response != nil && firstSpeak != nil && response! < firstSpeak!)
        #expect(spoken(d.effects) == "空调已经为您打开了。")
        #expect(d.state.view.subtitle == "空调已经为您打开了。")
    }

    @Test("W1 failure: ok=false is never claimed; the held claim is voided and the playback epoch moves on")
    func w1Failure() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("打开空调", isFinal: false))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.realtime(.replyText(t1, "空调已经为您打开了。"))
        d.send(.toolFinished(t1, climateOn(), .failure(.vehicleUnavailable)))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(spoken(d.effects).isEmpty)
        #expect(d.effects.contains(.flushPlayback(Epoch(1))))
        // The correction goes out after its grace period (F-06), not at once.
        let correction = d.fire(.correction)
        #expect(correction.contains(.provider(.text([TextTurn(role: .user, text: CorrectionReason.claimAfterFailure.instruction)],
                                                     turnComplete: true))))
    }

    @Test("W2 barge-in: 别说了 flushes, then cancels revoicing; clause 3 never plays and her answer to it is dropped")
    func w2() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("讲个故事", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.replyAudio(t1, PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])))
        d.realtime(.replyText(t1, "从前有一座山，山里有座庙，"))
        d.send(.playback(.replyStarted(Epoch.initial)))
        #expect(d.state.view.chip == .speaking)

        // The driver's voice alone does not stop her (owner rule 2026-10-28).
        let sound = d.send(.speechStarted(recentSpeech: true))
        #expect(!sound.contains { if case .flushPlayback = $0 { true } else { false } })
        #expect(sound.contains(.diagnostic(.bargeIn(qualified: false))))
        // The stop phrase does, already from the partial transcript.
        let barge = d.realtime(.userTranscript("别说", isFinal: false)) + d.realtime(.userTranscript("了", isFinal: false))
        #expect(Array(barge.prefix(2)) == [.flushPlayback(Epoch(1)), .cancelRevoicing(Epoch(1))])
        #expect(barge.contains(.diagnostic(.bargeIn(qualified: true))))
        let late = d.realtime(.replyText(t1, "庙里有个老和尚。"))
        let after = d.realtime(.replyText(t1, "老和尚在讲故事。"))
        #expect(spoken(late + after).isEmpty)
        d.send(.speechStopped)
        d.realtime(.userTranscript("别说了", isFinal: true))
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        #expect(spoken(d.realtime(.replyText(t2, "好的，我不说了。"))).isEmpty)
    }

    @Test("W2 unqualified speech during playback is residual echo: nothing is flushed")
    func w2Echo() {
        var d = Drive()
        d.connect()
        d.send(.playback(.replyStarted(Epoch.initial)))
        let out = d.send(.speechStarted(recentSpeech: false))
        #expect(!out.contains { if case .flushPlayback = $0 { true } else { false } })
    }

    @Test("Mandarin only (owner rule 2026-10-28): a Spanish reply is voided and corrected in Chinese")
    func notMandarin() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("¿Qué?", isFinal: true))
        d.realtime(.responseStarted(t1))
        let out = d.realtime(.replyText(t1, "Encontré 5 lugares, por favor dime cuál quieres."))
        #expect(spoken(out).isEmpty)
        let correction = d.fire(.correction)
        #expect(correction.contains(.provider(.text([TextTurn(role: .user, text: CorrectionReason.notMandarin.instruction)],
                                                     turnComplete: true))))
    }

    @Test("W3 timeout: one re-ask at 6 s, silent give-up at 10 s, and a late tool call of that turn is dropped")
    func w3() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("把空调打开", isFinal: false))
        d.send(.speechStopped)
        let reask = d.fire(.reask)
        #expect(d.now == NovaInstant(milliseconds: 6_000))
        // F-08 §15 item 3: the re-ask names the newest words.
        #expect(reask.contains(.provider(.text([TextTurn(role: .user, text: "请回答我最新的这句话：「把空调打开」")], turnComplete: true))))
        let giveUp = d.fire(.giveUp)
        #expect(d.now == NovaInstant(milliseconds: 10_000))
        #expect(spoken(giveUp).isEmpty)

        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        let late = d.realtime(.toolCalls(t1, [climateOn("late_1")]))
        d.realtime(.replyText(t1, "好的，已为您打开空调。"))
        #expect(late == [.diagnostic(.lateToolResultDropped(turn: t1))])
        #expect(!d.effects.contains { if case .startTool = $0 { true } else { false } })
        #expect(spoken(d.effects).isEmpty)

        // The next utterance works normally again.
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        let next = d.realtime(.toolCalls(t2, [climateOn("call_2")]))
        #expect(next.contains(.startTool(t2, climateOn("call_2"))))
    }

    @Test("W4 (session side): a drop while thinking shows PROCESSING and reconnects with the handle")
    func w4() {
        var d = Drive()
        d.connect()
        d.realtime(.resumptionHandle("h1"))
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.failed(RealtimeError(.disconnect)))
        #expect(d.state.view.chip == .processing)
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let reconnect = d.send(.timer(.session(timer.last!)))
        #expect(reconnect.contains(.provider(.connect(connection: d.state.session.connection, resume: "h1"))))
    }

    @Test("W1 in the recorded Gemini order: the call closes turn 1, the claim comes in turn 2 and is proven")
    func w1RecordedOrder() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("帮我把空调打开", isFinal: false))
        d.send(.speechStopped)
        let t1 = TurnID(1), t2 = TurnID(2)
        d.realtime(.userTranscript("帮我把空调打开", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.toolCalls(t1, [climateOn()]))
        d.realtime(.audioDone(t1))
        d.realtime(.responseDone(t1, outcome: .completed))
        d.send(.toolFinished(t1, climateOn(), .success(["power_on": true, "temperature_c": 24])))
        d.realtime(.responseStarted(t2))
        d.realtime(.replyText(t2, "空调已为您打开。"))
        d.realtime(.audioDone(t2))
        d.realtime(.responseDone(t2, outcome: .completed))
        _ = d.fire(.correction)
        #expect(spoken(d.effects) == "空调已为您打开。")
        #expect(!d.effects.contains { if case .provider(.text) = $0 { true } else { false } })  // no false nudge
        #expect(!d.effects.contains { if case .flushPlayback = $0 { true } else { false } })
    }

    @Test("W3 in the real order: the flushed final transcript of the abandoned utterance does not revive it")
    func w3FinalTranscript() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("把空调打开", isFinal: false))
        d.send(.speechStopped)
        d.fire(.reask)
        d.fire(.giveUp)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("把空调打开", isFinal: true))
        d.realtime(.responseStarted(t1))
        let late = d.realtime(.toolCalls(t1, [climateOn("late_1")]))
        #expect(late == [.diagnostic(.lateToolResultDropped(turn: t1))])
        #expect(!d.effects.contains { if case .startTool = $0 { true } else { false } })
    }

    @Test("W2/W4: turn ids restart on a new socket; a barged-in turn 1 does not mute the new turn 1")
    func turnIDsPerSocket() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "从前有一座山，"))
        d.send(.playback(.replyStarted(Epoch.initial)))
        d.send(.speechStarted(recentSpeech: true))  // barge-in silences turn 1 of socket 1
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        d.send(.timer(.session(timer.last!)))
        d.realtime(.setupComplete)
        d.send(.speechStopped)
        // F-15a §2.5 (T-040f): the utterance that began during her reply was no driver turn; the driver
        // speaks again on the new socket.
        d.send(.playback(.replyFinished(Epoch.initial)))
        d.now = d.now + .seconds(1)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("你好", isFinal: true))
        let before = d.effects.count
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "你好，我在。"))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(spoken(Array(d.effects[before...])) == "你好，我在。")
    }

    @Test("W2: a server-side interrupted flushes playback and drops the half clause")
    func serverInterrupted() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("讲个故事", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "从前"))
        let out = d.realtime(.interrupted(t1, reason: .serverVAD))
        #expect(out.contains(.flushPlayback(Epoch(1))))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(spoken(d.effects).isEmpty)
    }

    @Test("W2 R4: after a permanent focus loss the reply is dropped, and the next driver utterance regains focus")
    func focusRegained() {
        var d = Drive()
        d.connect()
        d.send(.audioSession(.interruptionEnded(shouldResume: false)))
        #expect(d.state.arbiter.reply == .drop)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.userTranscript("你好", isFinal: true))
        d.realtime(.responseStarted(t1))
        d.realtime(.replyText(t1, "你好，我在。"))
        d.realtime(.responseDone(t1, outcome: .completed))
        #expect(spoken(d.effects) == "你好，我在。")
    }

    @Test("W1: nothing runs after stop, even a call already buffered from the socket")
    func afterStop() {
        var d = Drive()
        d.connect()
        let connection = d.state.session.connection
        d.send(.stop)
        let out = d.send(.realtime(.toolCalls(TurnID(1), [climateOn()]), connection: connection))
        #expect(out.isEmpty)
    }
}

/// Records effects; tools run on a real `ToolRunner` with a scripted executor.
final class RecordingSink: AgentEffectSink, @unchecked Sendable {
    let log = Mutex<[String]>([])
    func provider(_ command: ProviderCommand) async {
        switch command {
        case .toolResponses(let r): log.withLock { $0.append("toolResponse:\(r.map(\.result.ok))") }
        case .connect: log.withLock { $0.append("connect") }
        default: break
        }
    }
    func flushPlayback(to epoch: Epoch) { log.withLock { $0.append("flush") } }
    func cancelRevoicing(_ epoch: Epoch) async {}
    func newReply() async {}
    func speak(_ clause: String) async { log.withLock { $0.append("speak:\(clause)") } }
    func publish(_ view: AgentViewState) async {}
    func diagnostic(_ event: DiagnosticEvent) {}
    func speakGuidance(_ text: String, id: GuidanceID) async { log.withLock { $0.append("guidance:\(text)") } }
    func uplink(open: Bool) {}
}

struct OkExecutor: ToolExecutor {
    func execute(_ call: ToolCall) async -> ToolResult { .success(["power_on": true]) }
}

@Suite("T-023 AgentCore actor shell")
struct AgentCoreShellTests {
    @Test("W1 through the actor: ToolRunner result comes back as toolFinished and releases the claim")
    func shell() async throws {
        let sink = RecordingSink()
        let core = AgentCore(clock: ManualClock(), sink: sink,
                             tools: ToolRunner(executors: ["control_climate": OkExecutor()]))
        await core.send(.start)
        let connection = await core.state.session.connection
        await core.send(.realtime(.setupComplete, connection: connection))
        await core.send(.speechStarted(recentSpeech: true))
        await core.send(.realtime(.userTranscript("打开空调", isFinal: false), connection: connection))
        await core.send(.speechStopped)
        let t1 = TurnID(1)
        await core.send(.realtime(.responseStarted(t1), connection: connection))
        await core.send(.realtime(.toolCalls(t1, [climateOn()]), connection: connection))
        await core.send(.realtime(.replyText(t1, "空调打开了。"), connection: connection))
        for _ in 0..<200 where !sink.log.withLock({ $0.contains { $0.hasPrefix("speak:") } }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        await core.send(.realtime(.responseDone(t1, outcome: .completed), connection: connection))
        let log = sink.log.withLock { $0 }
        #expect(log.first == "connect")
        let response = try #require(log.firstIndex(of: "toolResponse:[true]"))
        let speak = try #require(log.firstIndex { $0.hasPrefix("speak:") })
        #expect(response < speak)
    }
}

@Suite("T-016a F-05a AgentState with the transcript selector")
struct DriverWordsTests {
    func speaking() -> Drive {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.send(.driverWords(.final("讲个故事")))
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.replyAudio(TurnID(1), PCMBuffer(sampleRate: 24_000, samples: [1, 2, 3])))
        d.realtime(.replyText(TurnID(1), "从前有一座山，"))
        d.send(.playback(.replyStarted(Epoch.initial)))
        return d
    }

    @Test("F-05a row 3: 别说了 in a local partial stops her; no Gemini transcript is involved")
    func stopFromLocalPartial() {
        var d = speaking()
        d.send(.speechStarted(recentSpeech: true))
        #expect(d.send(.driverWords(.partial("别说"))).isEmpty)
        let barge = d.send(.driverWords(.partial("别说了")))
        #expect(Array(barge.prefix(2)) == [.flushPlayback(Epoch(1)), .cancelRevoicing(Epoch(1))])
    }

    @Test("F-05a: once the selector feeds the words, Gemini's own transcript is ignored")
    func geminiIgnored() {
        var d = speaking()
        d.send(.speechStarted(recentSpeech: true))
        let out = d.realtime(.userTranscript("别说了", isFinal: true))
        #expect(!out.contains { if case .flushPlayback = $0 { true } else { false } })
    }

    @Test("F-05a row 4 (revised): the same tool call runs whatever the transcript was (unclear, Portuguese, none)")
    func transcriptNeverGuards() {
        for words in [DriverWords.unclear, .final("Não fale mais"), .final("今天天气不错"), nil] {
            var d = Drive()
            d.connect()
            d.send(.speechStarted(recentSpeech: true))
            d.send(.speechStopped)
            if let words { d.send(.driverWords(words)) }
            d.realtime(.responseStarted(TurnID(1)))
            let call = ToolCall(id: CallID("c1")!, name: "set_speech_output", arguments: ["mode": "silent"])
            #expect(d.realtime(.toolCalls(TurnID(1), [call])).contains { if case .startTool = $0 { true } else { false } },
                    "\(String(describing: words))")
        }
    }

    @Test("F-05a S4: an unclear utterance is not a stop phrase and starts no pipeline")
    func unclearNoStop() {
        var d = speaking()
        d.send(.speechStarted(recentSpeech: true))
        #expect(d.send(.driverWords(.unclear)).isEmpty)
    }
}

@Suite("T-040h F-15a AgentState: no route choice, route changes run on the first try")
struct NavigationRequestedTests {
    func navigating() -> Drive {
        var d = Drive()
        d.connect()
        d.send(.navigation(NavigationFlags(navigating: true, guidanceRunning: true)))
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        return d
    }

    func started(_ out: [AgentEffect]) -> Bool { out.contains { if case .startTool = $0 { true } else { false } } }

    @Test("F-15a row 12 (revised): while navigating, 换最快的 runs at once even when the subtitle shows （没听清）")
    func changeOnFirstTry() {
        var d = navigating()
        d.send(.driverWords(.unclear))
        d.realtime(.responseStarted(TurnID(1)))
        let fastest = ToolCall(id: CallID("c1")!, name: "choose_navigation_option", arguments: ["preference": "fastest"])
        #expect(started(d.realtime(.toolCalls(TurnID(1), [fastest]))))
    }

    @Test("F-15a: a tap on an alternative route is the request (I-6)")
    func tap() {
        var d = navigating()
        #expect(started(d.send(.ui(.choose(row: 1)))))
    }
}

@Suite("T-004i F-04 §14 AgentState follows the gate's one send decision")
struct SendDecisionTests {
    func playing() -> Drive {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.replyText(TurnID(1), "有两个地点，请说第几个。"))
        d.send(.playback(.replyStarted(Epoch.initial)))
        return d
    }

    @Test("F-04 §14 row 1/5: a not-sent utterance opens no turn, owes no answer, starts no reply clock, stops nothing")
    func notSent() {
        var d = playing()
        let start = d.send(.speechStarted(recentSpeech: false, sentToModel: false))
        #expect(!start.contains { if case .flushPlayback = $0 { true } else { false } })
        #expect(d.send(.speechStopped).isEmpty)
        #expect(d.send(.driverWords(.final("嗯"))).isEmpty)
    }

    @Test("F-04 §14 row 3/5: a sent utterance is a driver turn and starts the reply clock")
    func sent() {
        var d = playing()
        d.send(.playback(.replyFinished(Epoch.initial)))
        d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        let stopped = d.send(.speechStopped)
        #expect(stopped.contains { if case .schedule(.pipeline, _) = $0 { true } else { false } })
    }

    @Test("F-04 §14 row 6: 别说了 while she talks stops her at once; nothing goes to Gemini")
    func stopPhraseNotSent() {
        var d = playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: false))
        let out = d.send(.driverWords(.final("别说了")))
        #expect(out.contains { if case .flushPlayback = $0 { true } else { false } })
        // F-08 §15: only the empty activity goes to Gemini (it ends the reply there too); no words, no audio.
        #expect(out.filter { if case .provider = $0 { true } else { false } } == [.provider(.interruptReply)])
        #expect(!d.send(.speechStopped).contains { if case .provider = $0 { true } else { false } })
    }
}

@Suite("T-022a F-08 §14 stop phrase while she talks")
struct StopPhraseSpotterCoreTests {
    func stops(_ out: [AgentEffect]) -> Bool { out.contains { if case .flushPlayback = $0 { true } else { false } } }
    func diagnostics(_ out: [AgentEffect]) -> [DiagnosticEvent] {
        out.compactMap { if case .diagnostic(let e) = $0 { e } else { nil } }
    }

    @Test("F-08 §14 row 3: a spotter hit stops her (flush, qualified barge-in), sends nothing, opens no turn")
    func hit() {
        var d = SendDecisionTests().playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: false))
        let out = d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        #expect(stops(out))
        #expect(diagnostics(out).contains(.bargeIn(qualified: true)))
        #expect(diagnostics(out).contains { if case .stopPhrase(.kws, 0, _, 80, false) = $0 { true } else { false } })
        // F-08 §15: only the empty activity goes to Gemini (it ends the reply there too); no words, no audio.
        #expect(out.filter { if case .provider = $0 { true } else { false } } == [.provider(.interruptReply)])
        #expect(!d.send(.speechStopped).contains { if case .provider = $0 { true } else { false } })
    }

    @Test("F-08 §14 row 3 / item 5: the transcript check after a spotter hit, or a second hit, changes nothing")
    func secondIgnored() {
        var d = SendDecisionTests().playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: false))
        #expect(stops(d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))))
        // Her next reply starts at once; a second hit and the transcript of the same utterance are ignored.
        d.send(.playback(.replyStarted(Epoch.initial.next())))
        #expect(!stops(d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 3, score: 70)))))
        #expect(!stops(d.send(.driverWords(.final("别说了")))))
    }

    @Test("F-08 §14 item 5: the transcript final of the stopped utterance, arriving after it closed, stops nothing")
    func lateFinalIgnored() {
        var d = SendDecisionTests().playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: false))
        #expect(stops(d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))))
        d.send(.speechStopped)
        d.send(.playback(.replyStarted(Epoch.initial.next())))
        d.now = d.now + .seconds(3)
        #expect(!stops(d.send(.driverWords(.final("别说了")))))
    }

    @Test("F-08 §14 (review D1): 「停」 with her silent is a command for the model, not a given-up turn")
    func stopWordWhileSilent() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        let words = d.send(.driverWords(.final("停")))
        #expect(!stops(words))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        let call = d.realtime(.toolCalls(TurnID(1), [ToolCall(id: CallID("m1")!, name: "control_music",
                                                             arguments: ["action": "stop"])]))
        #expect(call.contains { if case .startTool = $0 { true } else { false } })
    }

    @Test("F-08 §14 (review D2): after a self-stop, a later hit in a new reply still stops her")
    func laterHitStops() {
        var d = SendDecisionTests().playing()
        d.now = NovaInstant(milliseconds: 5_000)
        #expect(stops(d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))))
        d.send(.playback(.replyStarted(Epoch.initial.next())))
        d.now = NovaInstant(milliseconds: 15_000)
        #expect(stops(d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))))
    }

    @Test("F-08 §14 item 7: a hit with no driver speech is a self-stop; a reply with an unsent utterance and no hit is a miss")
    func logLines() {
        var d = SendDecisionTests().playing()
        d.now = NovaInstant(milliseconds: 5_000)
        let selfStop = d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 6, score: 55)))
        #expect(diagnostics(selfStop).contains { if case .stopPhrase(.kws, 6, -1, 55, true) = $0 { true } else { false } })
        var m = SendDecisionTests().playing()
        m.send(.speechStarted(recentSpeech: true, sentToModel: false))
        m.send(.speechStopped)
        let idle = m.send(.playback(.replyIdle(Epoch.initial)))
        #expect(diagnostics(idle).contains { if case .stopPhraseMiss = $0 { true } else { false } })
    }
}

@Suite("T-022c F-08 §16 after a stop nothing is spoken without a sent utterance")
struct PostStopCoreTests {
    func spokeText(_ out: [AgentEffect]) -> Bool { out.contains { if case .speak = $0 { true } else { false } } }
    func diagnostics(_ out: [AgentEffect]) -> [DiagnosticEvent] {
        out.compactMap { if case .diagnostic(let e) = $0 { e } else { nil } }
    }

    @Test("F-08 §16 row 7: stop mid-turn, Gemini then opens a turn with no sent utterance: not spoken, no re-ask")
    func noResume() {
        var d = SendDecisionTests().playing()
        d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        d.realtime(.interrupted(TurnID(1), reason: .bargeIn))
        d.now = d.now + .seconds(2)
        let opened = d.realtime(.responseStarted(TurnID(2)))
        #expect(diagnostics(opened).contains(.postStopTurnDropped))
        #expect(!spokeText(d.realtime(.replyText(TurnID(2), "珠海还有长隆海洋王国……"))))
        d.realtime(.responseDone(TurnID(2), outcome: .completed))
        d.now = d.now + .seconds(20)
        for timer in [PipelineTimer.Kind.reask] {
            #expect(!d.fire(timer).contains { if case .provider(.text) = $0 { true } else { false } })
        }
        // A real question afterwards is answered.
        d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        d.send(.driverWords(.final("现在几点")))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(3)))
        #expect(spokeText(d.realtime(.replyText(TurnID(3), "现在是下午三点。"))))
    }
}

@Suite("T-022b F-08 §15 a stop phrase also ends the reply for Gemini")
struct StopSyncTests {
    func diagnostics(_ out: [AgentEffect]) -> [DiagnosticEvent] {
        out.compactMap { if case .diagnostic(let e) = $0 { e } else { nil } }
    }
    func spokeText(_ out: [AgentEffect]) -> Bool { out.contains { if case .speak = $0 { true } else { false } } }

    @Test("F-08 §15 row 2: local flush first, then the empty activity; stopSync sent; no interrupt in 1 s is logged")
    func flushThenInterrupt() throws {
        var d = SendDecisionTests().playing()
        let out = d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        let flush = try #require(out.firstIndex { if case .flushPlayback = $0 { true } else { false } })
        let sync = try #require(out.firstIndex(of: .provider(.interruptReply)))
        #expect(flush < sync)
        #expect(diagnostics(out).contains(.stopSyncSent))
        d.now = d.now + .seconds(1)
        #expect(diagnostics(d.send(.timer(.stopSync(.zero)))) == [.stopSyncNoInterrupt])
    }

    @Test("F-08 §15 row 3: interrupted closes the old turn; the mute is off; the new question is answered")
    func newQuestionAnswered() {
        var d = SendDecisionTests().playing()
        d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        d.now = d.now + .milliseconds(300)
        let closed = d.realtime(.interrupted(TurnID(1), reason: .bargeIn))
        #expect(diagnostics(closed).contains(.stopSyncInterrupted(ms: 300)))
        #expect(!d.state.arbiter.replyPlaying)
        d.now = d.now + .seconds(2)
        d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        d.send(.driverWords(.final("现在几点")))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(2)))
        #expect(spokeText(d.realtime(.replyText(TurnID(2), "现在是下午三点。"))))
    }

    @Test("F-08 §15 row 4: no answer to the next question: the re-ask names it, never the generic text")
    func reaskNamesNewest() {
        var d = SendDecisionTests().playing()
        d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        d.realtime(.interrupted(TurnID(1), reason: .bargeIn))
        d.now = d.now + .seconds(2)
        d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        d.send(.driverWords(.final("讲个笑话")))
        d.send(.speechStopped)
        let reask = d.fire(.reask)
        #expect(reask.contains(.provider(.text([TextTurn(role: .user, text: "请回答我最新的这句话：「讲个笑话」")], turnComplete: true))))
        #expect(!reask.contains(.provider(.text([TextTurn(role: .user, text: DriverTurnPipeline.reaskText)], turnComplete: true))))
    }

    @Test("F-08 §15 item 3: the stop's own sent utterance starts no clock")
    func stopUtteranceNoClock() {
        var d = SendDecisionTests().playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        let stopped = d.send(.speechStopped)
        #expect(diagnostics(stopped).contains(.reaskSuppressed))
        #expect(!stopped.contains { if case .schedule(.pipeline(let t), _) = $0 { t.kind == .reask } else { false } })
    }

    @Test("F-08 §15 row 5: transcript stop, new utterance, Gemini's turn: spoken, abandonCleared")
    func abandonScoped() {
        var d = SendDecisionTests().playing()
        d.send(.speechStarted(recentSpeech: true, sentToModel: false))
        d.send(.driverWords(.final("别说了")))
        d.send(.speechStopped)
        d.realtime(.interrupted(TurnID(1), reason: .bargeIn))
        d.now = d.now + .seconds(2)
        let started = d.send(.speechStarted(recentSpeech: true, sentToModel: true))
        #expect(diagnostics(started).contains(.abandonCleared))
        d.send(.driverWords(.final("讲个笑话")))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(2)))
        #expect(spokeText(d.realtime(.replyText(TurnID(2), "有一只企鹅走进了冰淇淋店。"))))
    }

    @Test("F-08 §15 item 4: server turn already done, local audio still playing: a turn Gemini opens for the empty activity is not spoken")
    func emptyActivityTurnDropped() {
        var d = SendDecisionTests().playing()
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        d.send(.playback(.replyStarted(d.state.arbiter.epoch)))
        #expect(d.state.arbiter.replyPlaying, "epoch \(d.state.arbiter.epoch)")
        let out = d.send(.stopPhraseSpotted(StopPhraseHit(phrase: 0, score: 80)))
        #expect(out.contains(.provider(.interruptReply)))
        d.realtime(.responseStarted(TurnID(2)))
        #expect(!spokeText(d.realtime(.replyText(TurnID(2), "好的，我不说了。"))))
        // An unrelated turn's interrupted does not close the sync; the 1 s check still logs it.
        d.now = d.now + .seconds(1)
        #expect(diagnostics(d.send(.timer(.stopSync(.zero)))) == [.stopSyncNoInterrupt])
    }
}
