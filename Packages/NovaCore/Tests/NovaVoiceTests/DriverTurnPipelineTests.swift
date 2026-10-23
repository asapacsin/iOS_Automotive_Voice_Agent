import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

struct PipelineHarness {
    var pipeline = DriverTurnPipeline()
    var now = NovaInstant.zero
    var timers: [PipelineTimer.Kind: (PipelineTimer, NovaInstant)] = [:]
    var out: [PipelineOutput] = []
    var turn = TurnID.initial

    var spoken: String { out.compactMap { if case .speechText(_, let s) = $0 { s } else { nil } }.joined() }
    var corrections: [CorrectionReason] { out.compactMap { if case .sendCorrection(let r) = $0 { r } else { nil } } }

    @discardableResult
    mutating func send(_ input: PipelineInput) -> [PipelineOutput] {
        let o = pipeline.handle(input, at: now)
        out += o
        for e in o {
            if case .schedule(let t, let at) = e { timers[t.kind] = (t, at) }
            if case .cancelTimer(let k) = e { timers[k] = nil }
        }
        return o
    }

    mutating func advance(by d: NovaDuration) {
        let target = now + d
        while let (k, (t, at)) = timers.min(by: { $0.value.1 < $1.value.1 }), at <= target {
            now = at; timers[k] = nil; send(.timerFired(t))
        }
        now = target
    }

    mutating func driver(_ text: String) {
        send(.driverUtterance(text))
        turn = turn.next()
        send(.turnOpened(turn))
    }

    mutating func say(_ text: String) { send(.replyText(turn, text)) }
    mutating func close() { send(.audioDone(turn)); send(.turnClosed(turn, .completed)) }

    mutating func call(_ id: String, _ name: String) -> CallID {
        let callID = CallID(id)!
        send(.toolCalls(turn, [ToolCall(id: callID, name: name, arguments: [:])]))
        return callID
    }

    mutating func result(_ id: CallID, _ name: String, _ r: ToolResult) {
        send(.toolResult(turn, ToolResponse(id: id, name: name, result: r)))
    }
}

@Suite("T-019 F-06 reply truthfulness")
struct DriverTurnPipelineTests {
    @Test("F-06 W3 a claim with no tool call is not spoken and a correction is sent")
    func claimWithoutTool() {
        var h = PipelineHarness()
        h.driver("打开空调")
        h.say("好的，空调已打开")
        #expect(h.spoken.isEmpty)
        h.close()
        #expect(h.spoken.isEmpty)
        #expect(h.out.contains(.voided(h.turn)))
        // Grace: a tool may still follow, so the nudge waits 20 s.
        h.advance(by: .milliseconds(19_999))
        #expect(h.corrections.isEmpty)
        h.advance(by: .milliseconds(1))
        #expect(h.corrections == [.actionAskedNoToolCall])
    }

    @Test("F-06 a tool call during the grace period cancels the correction")
    func graceCancelledByTool() {
        var h = PipelineHarness()
        h.driver("打开空调")
        h.say("空调已打开")
        h.close()
        h.advance(by: .seconds(5))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        _ = h.call("c1", "control_climate")
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty)
    }

    @Test("F-06 W1 the claim is held until control_climate returns ok, then spoken")
    func heldUntilOk() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.say("好的，")
        h.send(.replyAudio(h.turn, PCMBuffer(sampleRate: 24_000, samples: [1, 2])))
        h.say("空调已打开。")
        #expect(h.spoken.isEmpty)
        h.result(c, "control_climate", .success(["power": true]))
        #expect(h.spoken == "好的，空调已打开。")
        // Audio and text come out together, in order.
        let kinds = h.out.compactMap { e -> String? in
            switch e { case .speechText: "t"; case .speechAudio: "a"; default: nil }
        }
        #expect(kinds == ["t", "a", "t"])
        h.close()
        h.advance(by: .seconds(60))
        #expect(h.corrections.isEmpty)
    }

    @Test("F-06 control_climate ok=false: no success claim is heard")
    func failedTool() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.say("空调已打开")
        h.result(c, "control_climate", .failure(.vehicleUnavailable))
        #expect(h.spoken.isEmpty)
        #expect(h.out.contains(.voided(h.turn)))
        h.advance(by: .milliseconds(1500))
        #expect(h.corrections == [.claimAfterFailure])
    }

    @Test("F-06 an honest failure sentence after ok=false is spoken")
    func honestFailure() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.result(c, "control_climate", .failure(.vehicleUnavailable))
        h.say("抱歉，空调暂时无法打开。")
        h.close()
        #expect(h.spoken == "抱歉，空调暂时无法打开。")
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty)
    }

    @Test("F-06 导航已开始 before NAVIGATING is corrected with NAVIGATION_NOT_STARTED")
    func navigationNotStarted() {
        var h = PipelineHarness()
        h.driver("导航去珠海站")
        let c = h.call("c1", "start_navigation")
        h.result(c, "start_navigation", .success())
        h.send(.navigationPhase(.calculatingRoute))
        h.say("导航已开始")
        h.close()
        #expect(h.spoken.isEmpty)
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.navigationNotStarted])
        #expect(CorrectionReason.navigationNotStarted.rawValue == "NAVIGATION_NOT_STARTED")
    }

    @Test("F-06 导航已开始 is released once the phase is NAVIGATING")
    func navigationStarted() {
        var h = PipelineHarness()
        h.driver("导航去珠海站")
        let c = h.call("c1", "start_navigation")
        h.result(c, "start_navigation", .success())
        h.send(.navigationPhase(.calculatingRoute))
        h.say("导航已开始")
        #expect(h.spoken.isEmpty)
        h.send(.navigationPhase(.navigating))
        #expect(h.spoken == "导航已开始")
    }

    @Test("F-06 正在播放 without verified playback: MUSIC_NOT_CONFIRMED")
    func musicNotConfirmed() {
        var h = PipelineHarness()
        h.driver("放首歌")
        let c = h.call("c1", "control_music")
        h.result(c, "control_music", .success())
        h.say("正在播放音乐")
        h.close()
        h.advance(by: .seconds(2))
        #expect(h.spoken.isEmpty)
        #expect(h.corrections == [.musicNotConfirmed])
    }

    @Test("F-06 a partial scenario cannot be claimed as done")
    func partial() {
        var h = PipelineHarness()
        h.driver("有蚊子")
        let c = h.call("c1", "run_scenario")
        h.result(c, "run_scenario", .success(["partial": true]))
        h.say("已为您关好车窗")
        h.close()
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.partialScenario])
    }

    @Test("F-06 an ambiguous referent asks for clarification")
    func clarify() {
        var h = PipelineHarness()
        h.driver("再低一点")
        let c = h.call("c1", "control_seat")
        h.result(c, "control_seat", .failure(.ambiguousReferent))
        h.say("已调低")
        h.close()
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.clarifyReferent])
    }

    @Test("F-06 one corrective nudge per utterance")
    func oneNudge() {
        var h = PipelineHarness()
        h.driver("打开空调")
        h.say("空调已打开")
        h.close()
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.say("已经打开了")
        h.close()
        h.advance(by: .seconds(60))
        #expect(h.corrections.count == 1)
    }

    @Test("F-06 an action request answered with chat only is nudged after the grace")
    func noToolNoClaim() {
        var h = PipelineHarness()
        h.driver("打开空调")
        h.say("好的，我来看看。")
        h.close()
        #expect(h.spoken == "好的，我来看看。")
        h.advance(by: .seconds(20))
        #expect(h.corrections == [.actionAskedNoToolCall])
    }

    @Test("F-06 negated sentences are not claims")
    func negation() {
        #expect(ClaimLexicon.claim(in: "抱歉，空调没能打开") == nil)
        #expect(ClaimLexicon.claim(in: "好的，空调已打开") == .action)
        #expect(ClaimLexicon.claim(in: "导航已开始，请注意安全") == .navigationStarted)
    }

    @Test("F-06 W3 no output 3 s after the driver: one re-ask; give up at 5 s")
    func emptyResponse() {
        var h = PipelineHarness()
        h.send(.driverUtterance("今天天气怎么样"))
        h.advance(by: .milliseconds(2999))
        #expect(!h.out.contains(.reask(DriverTurnPipeline.reaskText)))
        h.advance(by: .milliseconds(1))
        #expect(h.out.contains(.reask("请回应我刚才说的话。")))
        h.advance(by: .milliseconds(1999))
        #expect(!h.out.contains(.gaveUp))
        h.advance(by: .milliseconds(1))
        #expect(h.out.contains(.gaveUp))
        #expect(h.out.filter { if case .reask = $0 { true } else { false } }.count == 1)
    }

    @Test("F-06 an answer within 3 s cancels the re-ask")
    func answerCancelsReask() {
        var h = PipelineHarness()
        h.driver("今天天气怎么样")
        h.say("今天晴。")
        h.advance(by: .seconds(10))
        #expect(!h.out.contains { if case .reask = $0 { true } else { false } })
    }

    @Test("F-06 a phantom turn (no real utterance, short reply) is dropped silently")
    func phantom() {
        var h = PipelineHarness()
        h.send(.driverUtterance("嗯"))
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.say("我在。")
        #expect(h.spoken.isEmpty)
        h.close()
        #expect(h.spoken.isEmpty)
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty)
    }

    @Test("F-06 a long reply without a fresh utterance is not a phantom")
    func notPhantom() {
        var h = PipelineHarness()
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.say("前方三公里有一个服务区，可以在那里休息一下再继续出发。")
        #expect(!h.spoken.isEmpty)
    }

    @Test("F-06 W1 the hold budget voids an unproven claim after 120 events")
    func holdBudget() {
        var h = PipelineHarness()
        h.driver("打开空调")
        _ = h.call("c1", "control_climate")
        h.say("空调已打开")
        for _ in 0..<120 { h.send(.replyAudio(h.turn, PCMBuffer(sampleRate: 24_000, samples: [0]))) }
        #expect(h.out.contains(.voided(h.turn)))
        #expect(h.spoken.isEmpty)
    }

    @Test("F-06 short and length rules")
    func lengths() {
        let t = TruthfulnessTuning()
        #expect(DriverTurnPipeline.isShort("好的，我在。", t))
        #expect(!DriverTurnPipeline.isShort(String(repeating: "好", count: 13), t))
        #expect(DriverTurnPipeline.isShort(String(repeating: "a", count: 40), t))
        #expect(!DriverTurnPipeline.isShort(String(repeating: "a", count: 41), t))
        #expect(DriverTurnPipeline.length("嗯。") == 1)
    }

@Suite("T-019 F-06 review regressions")
struct DriverTurnPipelineRegressionTests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 audio before its transcript is not heard after a failed tool (B1, row 2)")
    func audioBeforeTextAfterFailure() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.result(c, "control_climate", .failure(.vehicleUnavailable))
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 0)
        h.say("空调已打开")
        h.close()
        #expect(audioOut(h) == 0 && h.spoken.isEmpty)
    }

    @Test("F-06 audio before its transcript is not heard with no tool call (B1, row 1)")
    func audioBeforeTextNoTool() {
        var h = PipelineHarness()
        h.driver("打开空调")
        h.send(.replyAudio(h.turn, pcm))
        h.say("好的，空调已打开")
        h.close()
        #expect(audioOut(h) == 0 && h.spoken.isEmpty)
    }

    @Test("F-06 a read-only ok result does not prove an action claim (B2)")
    func readOnlyDoesNotProve() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let read = h.call("c1", "control_climate")
        let act = h.call("c2", "control_climate")
        h.say("空调已打开")
        h.result(read, "control_climate", .success(["action": "get_state", "power_on": false]))
        h.result(act, "control_climate", .failure(.vehicleUnavailable))
        h.close()
        #expect(h.spoken.isEmpty)
    }

    @Test("F-06 a later 导航已开始 is judged as a navigation claim (B3, row 3)")
    func strongerLaterClaim() {
        var h = PipelineHarness()
        h.driver("导航去加油站")
        let c = h.call("c1", "navigate_to")
        h.say("已为您找到附近的加油站。")
        h.result(c, "navigate_to", .success(["status": "awaiting_route_selection_on_screen"]))
        h.say("导航已开始。")
        h.close()
        // The search result was true and may be heard; the start claim never is.
        #expect(!h.spoken.contains("导航已开始"))
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.navigationNotStarted])
    }

    @Test("F-06 the hold budget never releases audio unjudged while a call pends (B4)")
    func budgetWithPendingCall() {
        var h = PipelineHarness()
        h.driver("打开空调")
        _ = h.call("c1", "control_climate")
        for _ in 0..<121 { h.send(.replyAudio(h.turn, pcm)) }
        #expect(audioOut(h) == 0)
    }

    @Test("F-06 a stale music flag does not prove 正在播放 after control_music failed")
    func staleMusic() {
        var h = PipelineHarness()
        h.send(.musicPlaying(true))
        h.driver("放首歌")
        let c = h.call("c1", "control_music")
        h.result(c, "control_music", .failure(.vehicleUnavailable))
        h.say("正在播放音乐")
        h.close()
        #expect(h.spoken.isEmpty)
    }

    @Test("F-06 a claim still pending when the turn closes is voided and nudged")
    func closedWhilePending() {
        var h = PipelineHarness()
        h.driver("打开空调")
        _ = h.call("c1", "control_climate")
        h.say("空调已打开")
        h.close()
        #expect(h.out.contains(.voided(h.turn)))
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.unverifiedClaim])
    }

    @Test("F-06 a proven turn releases audio and text, later chunks flow straight through")
    func provenFlows() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.send(.replyAudio(h.turn, pcm))
        h.say("空调已打开，")
        h.result(c, "control_climate", .success(["power_on": true]))
        #expect(audioOut(h) == 1 && h.spoken == "空调已打开，")
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 2)
    }
}

@Suite("T-019 F-06 review 2 regressions")
struct DriverTurnPipelineReview2Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 negation in a later clause does not hide the claim (B-a, row 2)")
    func clauseNegation() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.result(c, "control_climate", .failure(.vehicleUnavailable))
        h.say("已为您打开空调，如果还没凉下来请告诉我。")
        h.close()
        #expect(!h.spoken.contains("已为您打开空调"))
    }

    @Test("F-06 an implicit request (我有点热) is held whole (B-b, row 1)")
    func implicitRequest() {
        for said in ["我有点热", "关一下车窗"] {
            var h = PipelineHarness()
            h.driver(said)
            h.send(.replyAudio(h.turn, pcm))
            h.say("已为您把空调调低两度。")
            h.close()
            #expect(audioOut(h) == 0 && h.spoken.isEmpty, "\(said)")
        }
    }

    @Test("F-06 an ok action turn keeps all its audio past the hold budget (B-c)")
    func okTurnKeepsAudio() {
        var h = PipelineHarness()
        h.driver("把温度调到24度")
        let c = h.call("c1", "control_climate")
        h.result(c, "control_climate", .success(["temperature_c": 24]))
        for _ in 0..<200 { h.send(.replyAudio(h.turn, pcm)) }
        h.say("好的，温度现在是24度。")
        h.close()
        #expect(audioOut(h) == 200 && h.spoken == "好的，温度现在是24度。")
    }

    @Test("F-06 the honest answer to a correction is not a phantom (B-d)")
    func correctionAnswerHeard() {
        var h = PipelineHarness()
        h.driver("打开空调")
        let c = h.call("c1", "control_climate")
        h.result(c, "control_climate", .failure(.vehicleUnavailable))
        h.say("空调已打开")
        h.close()
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.claimAfterFailure])
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.send(.replyAudio(h.turn, pcm))
        h.say("抱歉，空调打开失败了。")
        h.close()
        #expect(h.spoken == "抱歉，空调打开失败了。" && audioOut(h) == 1)
    }

    @Test("F-06 a chat turn shows text as judged and plays its audio at the end")
    func chatTurn() {
        var h = PipelineHarness()
        h.driver("今天星期几")
        h.send(.replyAudio(h.turn, pcm))
        h.say("今天星期五。")
        #expect(h.spoken == "今天星期五。" && audioOut(h) == 0)
        h.close()
        #expect(audioOut(h) == 1)
    }
}
}
