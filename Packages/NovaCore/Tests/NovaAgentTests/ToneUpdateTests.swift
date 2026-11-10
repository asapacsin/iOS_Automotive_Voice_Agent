import Testing
@testable import NovaAgent
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice

@Suite("T-034c F-21 §16 a new tone applies at once")
struct ToneUpdateTests {
    static let base = "BASE"
    let t1 = TurnID.initial.next()
    let call = ToolCall(id: CallID("c1")!, name: SpeakingStyleHandler.tool, arguments: ["style": "sweet"])

    func connected(model: String = ToneUpdateSetup.supportedModel, style: SpeakingStyle = .default,
                   resume: SessionResume? = nil, resumeStyle: SpeakingStyle? = nil) -> (AgentState, [AgentEffect]) {
        var state = AgentState(truthfulness: TruthfulnessTuning(), resume: resume,
                               tone: ToneUpdateSetup(base: Self.base, model: model, style: style, resumeStyle: resumeStyle))
        var effects = state.handle(.start, at: .zero)
        effects += state.handle(.realtime(.setupComplete, connection: state.session.connection), at: .zero)
        return (state, effects)
    }

    func realtime(_ state: inout AgentState, _ event: RealtimeEvent, at now: NovaInstant = .zero) -> [AgentEffect] {
        state.handle(.realtime(event, connection: state.session.connection), at: now)
    }

    func updates(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { if case .provider(.contextUpdate(let text)) = $0 { text } else { nil } }
    }

    func lines(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap { if case .styleLine(let line) = $0 { line.logLine } else { nil } }
    }

    func sweetResult(_ style: SpeakingStyle = .sweet) -> ToolResult {
        .success(["style": .string(style.rawValue)])
    }

    /// The tool call of turn 1 and its result; returns the effects of the result.
    func toolTurn(_ state: inout AgentState, result: ToolResult) -> [AgentEffect] {
        _ = realtime(&state, .responseStarted(t1))
        _ = realtime(&state, .toolCalls(t1, [call]))
        return state.handle(.toolFinished(t1, call, result), at: .zero)
    }

    @Test("F-21 §16 row 2: nothing before the confirmation turn's turnComplete; one update after it, base kept, sweet block")
    func afterConfirmation() {
        var (state, start) = connected()
        // The first setup carries the current tone (item 5: a setup without a handle needs no update).
        #expect(start.contains(.provider(.connect(connection: state.session.connection, resume: nil,
                                                  instruction: PersonaInstruction.build(base: Self.base, style: .default)))))
        var effects = toolTurn(&state, result: sweetResult())
        effects += realtime(&state, .replyText(t1, "好呀～"))
        effects += realtime(&state, .audioDone(t1))
        #expect(updates(effects).isEmpty)
        let done = realtime(&state, .responseDone(t1, outcome: .completed))
        let sent = updates(done)
        #expect(sent == [PersonaInstruction.build(base: Self.base, style: .sweet)])
        #expect(sent.first?.hasPrefix(Self.base + "\n") == true)
        #expect(sent.first?.hasSuffix(SpeakingStyle.sweet.block) == true)
        #expect(lines(done) == ["style-update sent style=sweet chars=\(sent[0].count) reason=tool"])
        // The update is the last effect of that turn end, after her reply closed.
        #expect(done.last == .styleLine(.sent(style: .sweet, chars: sent[0].count, reason: .tool)))
        // One update only: the next turn end sends nothing.
        let t2 = t1.next()
        _ = realtime(&state, .responseStarted(t2))
        _ = realtime(&state, .replyText(t2, "今天晴"))
        #expect(updates(realtime(&state, .responseDone(t2, outcome: .completed))).isEmpty)
    }

    @Test("F-21 §16 row 2: a call turn that ends before any confirmation words waits for the answering turn")
    func waitsForAnswerWords() {
        var (state, _) = connected()
        _ = realtime(&state, .responseStarted(t1))
        _ = realtime(&state, .toolCalls(t1, [call]))
        _ = state.handle(.toolFinished(t1, call, sweetResult()), at: .zero)
        #expect(updates(realtime(&state, .responseDone(t1, outcome: .completed))).isEmpty)
        let t2 = t1.next()
        _ = realtime(&state, .responseStarted(t2))
        _ = realtime(&state, .replyText(t2, "好呀～"))
        #expect(updates(realtime(&state, .responseDone(t2, outcome: .completed))).count == 1)
    }

    @Test("F-21 §16 row 3: the same tone again sends nothing (skipped same); STYLE_NOT_ALLOWED sends nothing")
    func sameAndNotAllowed() {
        var (state, _) = connected(style: .sweet)
        var effects = toolTurn(&state, result: sweetResult())
        #expect(lines(effects) == ["style-update skipped reason=same"])
        effects += realtime(&state, .replyText(t1, "好呀"))
        effects += realtime(&state, .responseDone(t1, outcome: .completed))
        #expect(updates(effects).isEmpty)

        var (other, _) = connected()
        var refused = toolTurn(&other, result: ToolDispatcher.failure(.styleNotAllowed))
        refused += realtime(&other, .replyText(t1, "这个语气不行"))
        refused += realtime(&other, .responseDone(t1, outcome: .completed))
        #expect(updates(refused).isEmpty)
        #expect(lines(refused).isEmpty)
    }

    @Test("F-21 §16 row 4: a confirmation turn that ends with interrupted sends the update at interrupted")
    func atInterrupted() {
        var (state, _) = connected()
        _ = toolTurn(&state, result: sweetResult())
        _ = realtime(&state, .replyText(t1, "好呀"))
        let cut = realtime(&state, .interrupted(t1, reason: .bargeIn))
        #expect(updates(cut).count == 1)
        #expect(updates(realtime(&state, .responseDone(t1, outcome: .cancelled))).isEmpty)
    }

    /// Closes the socket and fires the reconnect delay; returns the effects of the new connect.
    func reconnect(_ state: inout AgentState, at now: NovaInstant) -> [AgentEffect] {
        let closed = realtime(&state, .closed, at: now)
        guard let timer = closed.compactMap({ effect -> AgentTimer? in
            if case .schedule(let t, _) = effect, case .session(let s) = t, s.kind == .reconnectDelay { t } else { nil }
        }).first else { return [] }
        return state.handle(.timer(timer), at: now + .seconds(1))
    }

    func connect(_ effects: [AgentEffect]) -> (resume: String?, instruction: String?, update: String?)? {
        for effect in effects {
            if case .provider(.connect(_, let resume, let instruction, let update)) = effect {
                return (resume, instruction, update)
            }
        }
        return nil
    }

    @Test("F-21 §16 row 5: after a resumed setup the update goes with it when the tone changed; none when the same; none without a handle")
    func afterResume() {
        // Current ≠ the chain's original: the connect with the handle carries the update.
        var (state, _) = connected()
        _ = realtime(&state, .resumptionHandle("h1"))
        _ = toolTurn(&state, result: sweetResult())
        _ = realtime(&state, .replyText(t1, "好呀"))
        _ = realtime(&state, .responseDone(t1, outcome: .completed))
        let resumed = reconnect(&state, at: .zero + .seconds(10))
        let c = connect(resumed)
        #expect(c?.resume == "h1")
        #expect(c?.instruction == nil)
        #expect(c?.update == PersonaInstruction.build(base: Self.base, style: .sweet))
        // The line is written when that setup completes, not per attempt.
        #expect(lines(resumed).isEmpty)
        let complete = realtime(&state, .setupComplete, at: .zero + .seconds(12))
        #expect(lines(complete).contains { $0.hasSuffix("reason=resume") && $0.contains("style=sweet") })
        #expect(updates(complete).isEmpty)

        // Current = original: nothing.
        var (same, _) = connected()
        _ = realtime(&same, .resumptionHandle("h1"))
        let back = reconnect(&same, at: .zero + .seconds(10))
        #expect(connect(back)?.update == nil)
        #expect(lines(back).isEmpty)

        // No handle: the setup carries the current tone, no update.
        var (fresh, _) = connected()
        _ = toolTurn(&fresh, result: sweetResult())
        _ = realtime(&fresh, .replyText(t1, "好呀"))
        _ = realtime(&fresh, .responseDone(t1, outcome: .completed))
        let plain = connect(reconnect(&fresh, at: .zero + .seconds(10)))
        #expect(plain?.resume == nil)
        #expect(plain?.update == nil)
        #expect(plain?.instruction == PersonaInstruction.build(base: Self.base, style: .sweet))
    }

    @Test("F-21 §16 item 5: a give-up resume compares with the tone kept with the handle; the core keeps it at the give-up")
    func giveUpChain() {
        let (_, start) = connected(style: .sweet, resume: SessionResume(handle: "h9"), resumeStyle: .default)
        #expect(connect(start)?.update == PersonaInstruction.build(base: Self.base, style: .sweet))
        let (_, kept) = connected(style: .sweet, resume: SessionResume(handle: "h9"), resumeStyle: .sweet)
        #expect(connect(kept)?.update == nil)
    }

    @Test("F-21 §16 item 7: a slow resumed setup counts the 2 s from setupComplete; a close before it counts too")
    func slowResume() {
        var (state, _) = connected()
        _ = realtime(&state, .resumptionHandle("h1"))
        _ = state.handle(.styleChanged(.sweet), at: .zero)
        _ = reconnect(&state, at: .zero + .seconds(10))
        _ = realtime(&state, .setupComplete, at: .zero + .seconds(16))
        #expect(lines(realtime(&state, .failed(RealtimeError(.connectionClosed)), at: .zero + .seconds(17)))
                == ["style-update rejected code=CONNECTION_CLOSED"])

        var (early, _) = connected()
        _ = realtime(&early, .resumptionHandle("h1"))
        _ = early.handle(.styleChanged(.sweet), at: .zero)
        _ = reconnect(&early, at: .zero + .seconds(10))
        #expect(lines(realtime(&early, .failed(RealtimeError(.connectionClosed)), at: .zero + .seconds(20)))
                == ["style-update rejected code=CONNECTION_CLOSED"])
    }

    @Test("F-21 §16 row 4: the answering turn interrupted before any words still sends the update")
    func interruptedBeforeWords() {
        var (state, _) = connected()
        _ = toolTurn(&state, result: sweetResult())
        #expect(updates(realtime(&state, .interrupted(t1, reason: .bargeIn))).count == 1)
    }

    @Test("F-21 §16 item 4: a 设置 change while reconnecting goes in the next setup; while connecting, at setupComplete")
    func settingsWhileNotConnected() {
        var (state, _) = connected()
        let closed = realtime(&state, .closed, at: .zero + .seconds(1))
        #expect(state.handle(.styleChanged(.gentle), at: .zero + .seconds(1)).isEmpty)
        let timer = closed.compactMap { effect -> AgentTimer? in
            if case .schedule(let t, _) = effect, case .session(let s) = t, s.kind == .reconnectDelay { t } else { nil }
        }.first!
        let next = state.handle(.timer(timer), at: .zero + .seconds(2))
        #expect(connect(next)?.instruction == PersonaInstruction.build(base: Self.base, style: .gentle))
        #expect(updates(realtime(&state, .setupComplete, at: .zero + .seconds(3))).isEmpty)

        var connecting = AgentState(truthfulness: TruthfulnessTuning(),
                                    tone: ToneUpdateSetup(base: Self.base, model: ToneUpdateSetup.supportedModel, style: .default))
        _ = connecting.handle(.start, at: .zero)
        #expect(connecting.handle(.styleChanged(.lively), at: .zero).isEmpty)
        let done = realtime(&connecting, .setupComplete)
        #expect(updates(done) == [PersonaInstruction.build(base: Self.base, style: .lively)])
    }

    @Test("F-21 §16 item 5: the core keeps the chain's tone right after the handle at a give-up")
    func keepsChainTone() {
        var (state, _) = connected()
        _ = realtime(&state, .resumptionHandle("h1"))
        var effects: [AgentEffect] = []
        var now = NovaInstant.zero
        effects += realtime(&state, .closed, at: now)
        var n = 0
        while state.session.state == .reconnecting, n < 100 {
            n += 1
            now = now + .seconds(8)
            effects += realtime(&state, .failed(RealtimeError(.connection)), at: now)
        }
        let keep = effects.firstIndex(of: .keepResumption("h1"))
        #expect(keep != nil)
        #expect(keep.map { effects[$0 + 1] } == .keepToneChain(.default))
    }

    @Test("F-21 §16 row 6: on another model nothing is sent (skipped model)")
    func otherModel() {
        var (state, _) = connected(model: "gemini-3.1-flash-live-preview")
        var effects = toolTurn(&state, result: sweetResult())
        effects += realtime(&state, .replyText(t1, "好呀"))
        effects += realtime(&state, .responseDone(t1, outcome: .completed))
        #expect(updates(effects).isEmpty)
        #expect(lines(effects) == ["style-update skipped reason=model"])
    }

    @Test("F-21 §16 row 7: a close within 2 s of an update stops updates; later changes are skipped, no update after the reconnect")
    func rejection() {
        var (state, _) = connected()
        _ = realtime(&state, .resumptionHandle("h1"))
        _ = toolTurn(&state, result: sweetResult())
        _ = realtime(&state, .replyText(t1, "好呀"))
        #expect(updates(realtime(&state, .responseDone(t1, outcome: .completed))).count == 1)
        // A 1007 after setupComplete reaches the core as CONNECTION_CLOSED (GeminiLiveProvider).
        let failed = realtime(&state, .failed(RealtimeError(.connectionClosed)), at: .zero + .seconds(1))
        #expect(lines(failed) == ["style-update rejected code=CONNECTION_CLOSED"])
        let timer = failed.compactMap { effect -> AgentTimer? in
            if case .schedule(let t, _) = effect, case .session(let s) = t, s.kind == .reconnectDelay { t } else { nil }
        }.first
        let again = state.handle(.timer(timer!), at: .zero + .seconds(2))
        #expect(connect(again)?.resume == "h1")
        #expect(connect(again)?.update == nil)
        #expect(lines(again) == ["style-update skipped reason=disabled"])
        _ = realtime(&state, .setupComplete, at: .zero + .seconds(2))
        #expect(lines(state.handle(.styleChanged(.gentle), at: .zero + .seconds(3))) == ["style-update skipped reason=disabled"])

        // MALFORMED counts too; a close after 2 s does not.
        var (late, _) = connected()
        _ = toolTurn(&late, result: sweetResult())
        _ = realtime(&late, .replyText(t1, "好呀"))
        _ = realtime(&late, .responseDone(t1, outcome: .completed))
        #expect(lines(realtime(&late, .failed(RealtimeError(.connectionClosed)), at: .zero + .seconds(3))).isEmpty)
        var (bad, _) = connected()
        _ = toolTurn(&bad, result: sweetResult())
        _ = realtime(&bad, .replyText(t1, "好呀"))
        _ = realtime(&bad, .responseDone(t1, outcome: .completed))
        #expect(lines(realtime(&bad, .failed(RealtimeError(.malformed)), at: .zero + .milliseconds(500)))
                == ["style-update rejected code=MALFORMED"])
    }

    @Test("F-21 §16 row 8: a 设置 change while listening is sent at once; while she replies, when that reply ends")
    func settingsPath() {
        var (state, _) = connected()
        let now = state.handle(.styleChanged(.lively), at: .zero)
        #expect(updates(now) == [PersonaInstruction.build(base: Self.base, style: .lively)])
        #expect(lines(now).first?.hasSuffix("reason=settings") == true)

        _ = realtime(&state, .responseStarted(t1))
        _ = realtime(&state, .replyText(t1, "好的"))
        #expect(updates(state.handle(.styleChanged(.gentle), at: .zero)).isEmpty)
        let end = realtime(&state, .responseDone(t1, outcome: .completed))
        #expect(updates(end) == [PersonaInstruction.build(base: Self.base, style: .gentle)])
        #expect(lines(end).first?.hasSuffix("reason=settings") == true)
    }

    @Test("F-21 §16 item 2: a connection that closes before the turn ends sends nothing")
    func closedFirst() {
        var (state, _) = connected()
        _ = toolTurn(&state, result: sweetResult())
        _ = realtime(&state, .replyText(t1, "好呀"))
        let closed = realtime(&state, .closed, at: .zero + .seconds(1))
        #expect(updates(closed).isEmpty)
    }

    @Test("F-21 §16 item 8: style-update record lines are codes and numbers only")
    func recordLines() {
        var recorder = ConversationRecorder()
        #expect(recorder.add(.styleUpdate(.sent(style: .sweet, chars: 1_234, reason: .tool)), atMs: 5)
                == ["5 style-update sent style=sweet chars=1234 reason=tool"])
        #expect(recorder.add(.styleUpdate(.skipped(.same)), atMs: 6) == ["6 style-update skipped reason=same"])
        #expect(recorder.add(.styleUpdate(.rejected(code: .malformed)), atMs: 7) == ["7 style-update rejected code=MALFORMED"])
    }

    @Test("F-21 §16: without a tone setup nothing changes (no instruction on connect, no update)")
    func offByDefault() {
        var state = AgentState(truthfulness: TruthfulnessTuning())
        let start = state.handle(.start, at: .zero)
        #expect(start.contains(.provider(.connect(connection: state.session.connection, resume: nil))))
        _ = realtime(&state, .setupComplete)
        _ = toolTurn(&state, result: sweetResult())
        _ = realtime(&state, .replyText(t1, "好呀"))
        #expect(updates(realtime(&state, .responseDone(t1, outcome: .completed))).isEmpty)
    }
}
