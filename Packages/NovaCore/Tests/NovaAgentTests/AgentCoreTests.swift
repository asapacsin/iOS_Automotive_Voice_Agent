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

    @Test("W2 barge-in: flush, then cancel revoicing, then the session hears the driver; clause 3 never plays")
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

        let barge = d.send(.speechStarted(recentSpeech: true))
        #expect(Array(barge.prefix(2)) == [.flushPlayback(Epoch(1)), .cancelRevoicing(Epoch(1))])
        #expect(d.state.view.chip == .listening)
        let late = d.realtime(.replyText(t1, "庙里有个老和尚。"))
        d.realtime(.interrupted(t1, reason: .serverVAD))
        let after = d.realtime(.replyText(t1, "老和尚在讲故事。"))
        #expect(spoken(late + after).isEmpty)
    }

    @Test("W2 unqualified speech during playback is residual echo: nothing is flushed")
    func w2Echo() {
        var d = Drive()
        d.connect()
        d.send(.playback(.replyStarted(Epoch.initial)))
        let out = d.send(.speechStarted(recentSpeech: false))
        #expect(!out.contains { if case .flushPlayback = $0 { true } else { false } })
    }

    @Test("W3 timeout: one re-ask at 3 s, silent give-up at 5 s, and a late tool call of that turn is dropped")
    func w3() {
        var d = Drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.realtime(.userTranscript("把空调打开", isFinal: false))
        d.send(.speechStopped)
        let reask = d.fire(.reask)
        #expect(d.now == NovaInstant(milliseconds: 3_000))
        #expect(reask.contains(.provider(.text([TextTurn(role: .user, text: "请回应我刚才说的话。")], turnComplete: true))))
        let giveUp = d.fire(.giveUp)
        #expect(d.now == NovaInstant(milliseconds: 5_000))
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
