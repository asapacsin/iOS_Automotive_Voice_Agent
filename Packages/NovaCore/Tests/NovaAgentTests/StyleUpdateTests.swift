import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

/// F-21 §16 (T-034c): a new tone reaches Gemini on the same connection. The wire format (row 1) and the order of a
/// resumed setup's update before audio (row 5) are in NovaRealtime's tests.
@Suite("T-034c F-21 §16 a new tone in the same conversation")
struct StyleUpdateTests {
    static let base = PersonaInstruction.base(PersonaInstruction.base(for: .table), webSearch: true)

    static func instruction(_ style: SpeakingStyle) -> String { PersonaInstruction.build(base: base, style: style) }

    /// Connected and listening, with the tone feature on.
    static func session(style: SpeakingStyle = .default, model: String = SessionConfig.contextUpdateModel,
                        disabled: Bool = false, resume: SessionResume? = nil) -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: TruthfulnessTuning(), resume: resume,
                             styleUpdates: StyleUpdates(base: base, style: style, model: model, disabled: disabled))
        d.connect()
        return d
    }

    static func updates(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { if case .provider(.contextUpdate(let text)) = $0 { text } else { nil } }
    }

    static func lines(_ effects: [AgentEffect]) -> [StyleUpdateLine] {
        effects.compactMap { if case .styleUpdateLine(let line) = $0 { line } else { nil } }
    }

    static func connects(_ effects: [AgentEffect]) -> [(resume: String?, instruction: String?, update: String?)] {
        effects.compactMap {
            if case .provider(.connect(_, let resume, let instruction, let update)) = $0 { (resume, instruction, update) } else { nil }
        }
    }

    static func styleCall(_ style: String, _ n: Int) -> ToolCall {
        ToolCall(id: CallID("style_\(n)")!, name: SpeakingStyleHandler.tool, arguments: ["style": .string(style)])
    }

    /// One 「说话X一点」 exchange in the recorded Gemini order: the call closes its turn, the result goes back, and the
    /// confirmation comes in the next turn. Returns the effects from the result on, and the confirmation turn.
    @discardableResult
    static func ask(_ d: inout Drive, style: String, end: (TurnID) -> RealtimeEvent = { .responseDone($0, outcome: .completed) },
                    checkBefore: (([AgentEffect]) -> Void)? = nil) -> (effects: [AgentEffect], answer: TurnID) {
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("说话\(style)一点", isFinal: true))
        let call = d.turn.next(), answer = call.next()
        d.turn = answer
        let n = Int(answer.value)
        var before: [AgentEffect] = []
        before += d.realtime(.responseStarted(call))
        before += d.realtime(.toolCalls(call, [styleCall(style, n)]))
        before += d.realtime(.responseDone(call, outcome: .completed))
        let result: ToolResult = SpeakingStyle(rawValue: style).map { .success(["style": .string($0.rawValue)]) }
            ?? ToolDispatcher.failure(.styleNotAllowed)
        var effects = d.send(.toolFinished(call, styleCall(style, n), result))
        effects += d.realtime(.responseStarted(answer))
        effects += d.realtime(.replyText(answer, "好呀。"))
        checkBefore?(before + effects)
        effects += d.realtime(end(answer))
        return (effects, answer)
    }

    @Test("F-21 §16 row 2: no update before the confirmation turn's turnComplete; one after it, same base, sweet block")
    func afterConfirmation() {
        var d = Self.session()
        #expect(Self.connects(d.effects).map(\.instruction) == [Self.instruction(.default)])
        let (effects, _) = Self.ask(&d, style: "sweet", checkBefore: { before in
            #expect(Self.updates(before).isEmpty)  // not at the call, not at the result, not while she confirms
        })
        let sent = Self.updates(effects)
        #expect(sent == [Self.instruction(.sweet)])
        #expect(sent.first?.hasPrefix(Self.base + "\n") == true)
        #expect(Self.lines(effects) == [.sent(style: .sweet, chars: Self.instruction(.sweet).count, reason: .tool)])
        #expect(d.state.tones?.held == Self.instruction(.sweet))
        // The line follows the update it reports.
        let update = effects.firstIndex { if case .provider(.contextUpdate) = $0 { true } else { false } }
        let line = effects.firstIndex { if case .styleUpdateLine = $0 { true } else { false } }
        #expect(update != nil && line != nil && update! < line!)
    }

    @Test("F-21 §16 item 2: the call's own turn closing after the result is not the answer; the answer turn is")
    func callTurnClosesLate() {
        var d = Self.session()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let call = TurnID(1), answer = TurnID(2)
        d.realtime(.responseStarted(call))
        d.realtime(.toolCalls(call, [Self.styleCall("sweet", 1)]))
        d.send(.toolFinished(call, Self.styleCall("sweet", 1), .success(["style": "sweet"])))
        #expect(Self.updates(d.realtime(.responseDone(call, outcome: .completed))).isEmpty)
        d.realtime(.responseStarted(answer))
        d.realtime(.replyText(answer, "好呀。"))
        #expect(Self.updates(d.realtime(.responseDone(answer, outcome: .completed))) == [Self.instruction(.sweet)])
    }

    @Test("F-21 §16 row 3: the same tone again sends nothing (skipped reason=same); STYLE_NOT_ALLOWED sends nothing")
    func sameAndRefused() {
        var d = Self.session(style: .sweet)
        let (same, _) = Self.ask(&d, style: "sweet")
        #expect(Self.updates(same).isEmpty)
        #expect(Self.lines(same) == [.skipped(.same)])
        let (refused, _) = Self.ask(&d, style: "bossy")
        #expect(Self.updates(refused).isEmpty && Self.lines(refused).isEmpty)
        #expect(Self.updates(d.effects).isEmpty)
    }

    @Test("F-21 §16 row 4: a confirmation turn that ends with interrupted sends the update at interrupted")
    func atInterrupted() {
        var d = Self.session()
        let (effects, answer) = Self.ask(&d, style: "gentle", end: { .interrupted($0, reason: .serverVAD) })
        #expect(Self.updates(effects) == [Self.instruction(.gentle)])
        // The assembler's trailing responseDone(cancelled) sends nothing more.
        #expect(Self.updates(d.realtime(.responseDone(answer, outcome: .cancelled))).isEmpty)
    }

    @Test("F-21 §16 row 5: a handle setup with current ≠ original carries the update for setupComplete; equal or no handle: nothing")
    func resumedSetup() {
        // current ≠ original: the original is the default the chain began with.
        var d = Self.session()
        d.realtime(.resumptionHandle("h1"))
        Self.ask(&d, style: "sweet")
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let reconnect = d.send(.timer(.session(timer.last!)))
        let connect = Self.connects(reconnect)
        #expect(connect.count == 1 && connect[0].resume == "h1")
        #expect(connect[0].instruction == Self.instruction(.sweet) && connect[0].update == Self.instruction(.sweet))
        let ready = d.realtime(.setupComplete)
        // The provider sent it first at setupComplete; the core writes the line and sends no second update.
        #expect(Self.updates(ready).isEmpty)
        #expect(Self.lines(ready) == [.sent(style: .sweet, chars: Self.instruction(.sweet).count, reason: .resume)])
        #expect(d.state.tones?.held == Self.instruction(.sweet))

        // current = original: nothing.
        var same = Self.session(style: .sweet)
        same.realtime(.resumptionHandle("h2"))
        same.realtime(.failed(RealtimeError(.disconnect)))
        let t2 = same.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let c2 = Self.connects(same.send(.timer(.session(t2.last!))))
        #expect(c2.count == 1 && c2[0].resume == "h2" && c2[0].update == nil)
        let r2 = same.realtime(.setupComplete)
        #expect(Self.updates(r2).isEmpty && Self.lines(r2).isEmpty)

        // Set up without a handle: its setup already holds the current tone.
        var fresh = Self.session()
        Self.ask(&fresh, style: "lively")
        fresh.realtime(.failed(RealtimeError(.disconnect)))
        let t3 = fresh.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let c3 = Self.connects(fresh.send(.timer(.session(t3.last!))))
        #expect(c3.count == 1 && c3[0].resume == nil)
        #expect(c3[0].instruction == Self.instruction(.lively) && c3[0].update == nil)
        let r3 = fresh.realtime(.setupComplete)
        #expect(Self.updates(r3).isEmpty && Self.lines(r3).isEmpty)
    }

    @Test("F-21 §16 item 5: a give-up keeps the chain's original beside the handle; the next session's first setup uses it")
    func giveUpChain() {
        var d = Self.session()
        d.realtime(.resumptionHandle("h1"))
        Self.ask(&d, style: "sweet")
        d.realtime(.closed)
        var guardCount = 0
        while d.state.session.state == .reconnecting, guardCount < 100 {
            guardCount += 1
            d.now = d.now + .seconds(8)
            d.realtime(.failed(RealtimeError(.connection)))
        }
        #expect(d.effects.contains(.keepResumption("h1", instruction: Self.instruction(.default))))

        var next = Drive()
        next.state = AgentState(truthfulness: TruthfulnessTuning(),
                                resume: SessionResume(handle: "h1", instruction: Self.instruction(.default)),
                                styleUpdates: StyleUpdates(base: Self.base, style: .sweet))
        let connect = Self.connects(next.send(.start))
        #expect(connect.count == 1 && connect[0].resume == "h1" && connect[0].update == Self.instruction(.sweet))
        #expect(Self.lines(next.realtime(.setupComplete)) == [.sent(style: .sweet, chars: Self.instruction(.sweet).count,
                                                                     reason: .resume)])
        // Kept with the same tone: nothing to send.
        var same = AgentState(truthfulness: TruthfulnessTuning(),
                              resume: SessionResume(handle: "h1", instruction: Self.instruction(.sweet)),
                              styleUpdates: StyleUpdates(base: Self.base, style: .sweet))
        #expect(Self.connects(same.handle(.start, at: .zero)).first?.update == nil)
    }

    @Test("F-21 §16 item 5: the kept instruction goes with its handle only: taken once, gone when the handle expires or is dropped")
    func keptBesideHandle() {
        var store = KeptResumption()
        store.keep("h1", instruction: "orig", at: .zero)
        #expect(store.take(at: .zero + .minutes(1)) == SessionResume(handle: "h1", instruction: "orig"))
        store.keep("h1", instruction: "orig", at: .zero)
        #expect(store.take(at: .zero + .minutes(120)) == SessionResume(handle: nil))
        store.keep("h1", instruction: "orig", at: .zero)
        store.drop()
        #expect(store.take(at: .zero) == nil)
        #expect(SessionResume(handle: nil, instruction: "orig").instruction == nil)
    }

    @Test("F-21 §16 row 6: on gemini-3.1-flash-live-preview nothing is sent; skipped reason=model")
    func otherModel() {
        var d = Self.session(model: "gemini-3.1-flash-live-preview")
        let (effects, _) = Self.ask(&d, style: "sweet")
        #expect(Self.updates(effects).isEmpty)
        #expect(Self.lines(effects) == [.skipped(.model)])
        #expect(SessionConfig.supportsContextUpdate(model: "models/gemini-3.8-live"))
        #expect(!SessionConfig.supportsContextUpdate(model: "gemini-3.8-live-extended-thinking"))
        // A resumed setup on that model sends nothing either.
        d.realtime(.resumptionHandle("h1"))
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        #expect(Self.connects(d.send(.timer(.session(timer.last!)))).first?.update == nil)
        let ready = d.realtime(.setupComplete)
        #expect(Self.updates(ready).isEmpty && Self.lines(ready) == [.skipped(.model)])
    }

    @Test("F-21 §16 row 7: MALFORMED 1 s after an update: rejected, then skipped reason=disabled for a later change")
    func rejectedMalformed() {
        var d = Self.session()
        Self.ask(&d, style: "sweet")
        d.now = d.now + .seconds(1)
        let closed = d.realtime(.failed(RealtimeError(.malformed)))
        #expect(Self.lines(closed) == [.rejected(code: .malformed)])
        #expect(d.state.tones?.disabled == true)
        #expect(StyleUpdateLine.rejected(code: .malformed).logLine == "style-update rejected code=MALFORMED")
        // The next session of this app run starts disabled (the shell passes it on).
        var next = Self.session(disabled: true)
        let (later, _) = Self.ask(&next, style: "gentle")
        #expect(Self.updates(later).isEmpty && Self.lines(later) == [.skipped(.disabled)])
    }

    @Test("F-21 §16 row 7: a 1007/1008 close (CONNECTION_CLOSED) after an update: no repeated update after the reconnect")
    func rejectedThenReconnect() {
        var d = Self.session()
        d.realtime(.resumptionHandle("h1"))
        Self.ask(&d, style: "sweet")
        d.now = d.now + .milliseconds(1_500)
        #expect(Self.lines(d.realtime(.failed(RealtimeError(.connectionClosed)))) == [.rejected(code: .connectionClosed)])
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let connect = Self.connects(d.send(.timer(.session(timer.last!))))
        #expect(connect.count == 1 && connect[0].resume == "h1" && connect[0].update == nil)
        let ready = d.realtime(.setupComplete)
        #expect(Self.updates(ready).isEmpty && Self.lines(ready) == [.skipped(.disabled)])
        let (later, _) = Self.ask(&d, style: "gentle")
        #expect(Self.updates(later).isEmpty && Self.lines(later) == [.skipped(.disabled)])
        #expect(Self.updates(d.effects) == [Self.instruction(.sweet)])
    }

    @Test("F-21 §16 item 7: a close after 2 s, or a retryable drop, is no rejection")
    func notRejected() {
        var late = Self.session()
        Self.ask(&late, style: "sweet")
        late.now = late.now + .milliseconds(2_001)
        #expect(Self.lines(late.realtime(.failed(RealtimeError(.connectionClosed)))).isEmpty)
        #expect(late.state.tones?.disabled == false)
        var drop = Self.session()
        Self.ask(&drop, style: "sweet")
        #expect(Self.lines(drop.realtime(.failed(RealtimeError(.disconnect)))).isEmpty)
        #expect(drop.state.tones?.disabled == false)
    }

    @Test("F-21 §16 row 8: a tone picked in 设置 while listening is sent at once; while she replies, when that reply ends")
    func settingsPath() {
        var d = Self.session()
        let now = d.send(.speakingStyle(.tsundere))
        #expect(Self.updates(now) == [Self.instruction(.tsundere)])
        #expect(Self.lines(now) == [.sent(style: .tsundere, chars: Self.instruction(.tsundere).count, reason: .settings)])
        // The same tone again (the tool's own write echoed by the settings) changes nothing.
        #expect(d.send(.speakingStyle(.tsundere)).isEmpty)

        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.replyText(TurnID(1), "今天天气不错。"))
        #expect(Self.updates(d.send(.speakingStyle(.gentle))).isEmpty)
        #expect(Self.updates(d.realtime(.audioDone(TurnID(1)))).isEmpty)
        let ended = d.realtime(.responseDone(TurnID(1), outcome: .completed))
        #expect(Self.updates(ended) == [Self.instruction(.gentle)])
        #expect(Self.lines(ended) == [.sent(style: .gentle, chars: Self.instruction(.gentle).count, reason: .settings)])
    }

    @Test("F-21 §16 item 2: the connection closes before the confirmation ends: nothing is sent; the next setup has the tone")
    func closedFirst() {
        var d = Self.session()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.toolCalls(TurnID(1), [Self.styleCall("sweet", 1)]))
        d.send(.toolFinished(TurnID(1), Self.styleCall("sweet", 1), .success(["style": "sweet"])))
        d.realtime(.replyText(TurnID(1), "好呀。"))
        d.realtime(.failed(RealtimeError(.disconnect)))
        let timer = d.effects.compactMap { if case .schedule(.session(let t), _) = $0, t.kind == .reconnectDelay { t } else { nil } }
        let connect = Self.connects(d.send(.timer(.session(timer.last!))))
        #expect(Self.updates(d.effects).isEmpty)
        #expect(connect.first?.instruction == Self.instruction(.sweet) && connect.first?.update == nil)
        #expect(Self.lines(d.realtime(.setupComplete)).isEmpty)
    }

    @Test("F-21 §16 item 8: record lines carry codes and numbers only")
    func recordLines() {
        var r = ConversationRecorder()
        #expect(r.add(.styleUpdate(.sent(style: .sweet, chars: 1789, reason: .tool)), atMs: 5)
            == ["5 style-update sent style=sweet chars=1789 reason=tool"])
        #expect(r.add(.styleUpdate(.skipped(.same)), atMs: 6) == ["6 style-update skipped reason=same"])
        #expect(r.add(.styleUpdate(.rejected(code: .connectionClosed)), atMs: 7)
            == ["7 style-update rejected code=CONNECTION_CLOSED"])
        #expect(StyleUpdateLine.sent(style: .default, chars: 10, reason: .resume).logLine
            == "style-update sent style=default chars=10 reason=resume")
        #expect(StyleUpdateLine.skipped(.model).logLine == "style-update skipped reason=model")
        #expect(StyleUpdateLine.skipped(.disabled).logLine == "style-update skipped reason=disabled")
    }

    @Test("F-21 §16 item 9: the style block, the 4 000 cap and the base size are unchanged")
    func nothingElse() {
        #expect(PersonaInstruction.maxCharacters == 4000 && PersonaInstruction.maxBaseCharacters == 1707)
        #expect(Self.instruction(.sweet).count <= SessionConfig.maxInstructionCharacters)
        #expect(Self.instruction(.sweet) == Self.base + "\n" + SpeakingStyle.sweet.block)
    }

    @Test("F-21 §16: without the feature nothing changes: no update, connect carries no instruction")
    func off() {
        var d = Drive()
        d.connect()
        #expect(Self.connects(d.effects).map(\.instruction) == [nil])
        Self.ask(&d, style: "sweet")
        #expect(d.send(.speakingStyle(.gentle)).isEmpty)
        #expect(Self.updates(d.effects).isEmpty && Self.lines(d.effects).isEmpty)
    }
}
