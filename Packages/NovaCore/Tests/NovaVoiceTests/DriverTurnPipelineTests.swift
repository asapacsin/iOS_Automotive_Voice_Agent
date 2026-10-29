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

    @Test("F-06 W3 no output 6 s after the driver: one re-ask; give up at 10 s")
    func emptyResponse() {
        var h = PipelineHarness()
        h.send(.driverUtterance("今天天气怎么样"))
        h.advance(by: .milliseconds(5999))
        #expect(!h.out.contains(.reask(DriverTurnPipeline.reaskText)))
        h.advance(by: .milliseconds(1))
        #expect(h.out.contains(.reask("请回应我刚才说的话。")))
        h.advance(by: .milliseconds(3999))
        #expect(!h.out.contains(.gaveUp))
        h.advance(by: .milliseconds(1))
        #expect(h.out.contains(.gaveUp))
        #expect(h.out.filter { if case .reask = $0 { true } else { false } }.count == 1)
    }

    @Test("F-06 an answer within 6 s cancels the re-ask")
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

@Suite("T-019 F-06 review 3 regressions")
struct DriverTurnPipelineReview3Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 an ok navigate_to does not release audio before 导航已开始 is proven (B1, row 3)")
    func navigationAudio() {
        var h = PipelineHarness()
        h.driver("导航去加油站")
        let c = h.call("c1", "navigate_to")
        h.result(c, "navigate_to", .success(["status": "awaiting_route_selection_on_screen"]))
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 0)
        h.say("导航已开始。")
        h.close()
        #expect(audioOut(h) == 0 && h.spoken.isEmpty)
    }

    @Test("F-06 an ok control_music does not release audio while playback is unconfirmed (B1)")
    func musicAudio() {
        var h = PipelineHarness()
        h.driver("放首歌")
        let c = h.call("c1", "control_music")
        h.result(c, "control_music", .success())
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 0)
    }

    @Test("F-06 a false action claim is not carried by a true music or navigation claim (B2, row 2)")
    func everyClaimProven() {
        var h = PipelineHarness()
        h.send(.musicPlaying(true))
        h.driver("打开空调再放首歌")
        let a = h.call("c1", "control_climate")
        let m = h.call("c2", "play_music")
        h.result(a, "control_climate", .failure(.vehicleUnavailable))
        h.result(m, "play_music", .success())
        h.say("空调已打开，正在为您播放周杰伦。")
        h.close()
        #expect(h.spoken.isEmpty)

        var n = PipelineHarness()
        n.send(.navigationPhase(.navigating))
        n.driver("打开空调")
        let c = n.call("c1", "control_climate")
        n.result(c, "control_climate", .failure(.vehicleUnavailable))
        n.say("已为您打开空调，导航已开始。")
        n.close()
        #expect(n.spoken.isEmpty)
    }

    @Test("F-06 an honest clarification after AMBIGUOUS_REFERENT is heard without a nudge")
    func clarification() {
        var h = PipelineHarness()
        h.driver("再低一点")
        let c = h.call("c1", "control_seat")
        h.result(c, "control_seat", .failure(.ambiguousReferent))
        h.say("请问您是要调低座椅还是空调温度？")
        h.close()
        #expect(h.spoken == "请问您是要调低座椅还是空调温度？")
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty)
    }
}

@Suite("T-019 F-06 review 4 regressions")
struct DriverTurnPipelineReview4Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 audio of an unread music claim is held after the action claim is proven (L1)")
    func mixedMusic() {
        var h = PipelineHarness()
        h.driver("打开空调再放首歌")
        let a = h.call("c1", "control_climate")
        let m = h.call("c2", "play_music")
        h.result(a, "control_climate", .success(["power_on": true]))
        h.result(m, "play_music", .success())
        h.say("空调已打开，")
        #expect(h.spoken == "空调已打开，")
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 0)
        h.say("正在为您播放周杰伦。")
        h.close()
        #expect(audioOut(h) == 0 && !h.spoken.contains("正在为您播放"))
    }

    @Test("F-06 a navigation request keeps audio held when only climate ran (L3, row 3)")
    func navigationRequestOnlyClimate() {
        var h = PipelineHarness()
        h.driver("打开空调然后导航回家")
        let a = h.call("c1", "control_climate")
        h.result(a, "control_climate", .success(["power_on": true]))
        h.send(.replyAudio(h.turn, pcm))
        #expect(audioOut(h) == 0)
        h.say("空调已打开，导航已开始。")
        h.close()
        #expect(audioOut(h) == 0 && !h.spoken.contains("导航已开始"))
    }

    @Test("F-06 an ok navigate_to does not prove 已为您开启导航 (L2)")
    func navigateToIsNotActionProof() {
        var h = PipelineHarness()
        h.driver("导航去珠海站")
        let c = h.call("c1", "navigate_to")
        h.result(c, "navigate_to", .success(["status": "awaiting_route_selection_on_screen"]))
        h.say("好的，已为您开启导航。")
        h.close()
        #expect(h.spoken.isEmpty)
    }

    @Test("F-06 verified playback after generationComplete keeps a true 正在播放 (L4)")
    func lateMusicProof() {
        var h = PipelineHarness()
        h.driver("放周杰伦的歌")
        let m = h.call("c1", "play_music")
        h.result(m, "play_music", .success())
        h.send(.replyAudio(h.turn, pcm))
        h.say("正在为您播放周杰伦。")
        h.send(.audioDone(h.turn))
        h.send(.musicPlaying(true))
        h.send(.turnClosed(h.turn, .completed))
        #expect(h.spoken == "正在为您播放周杰伦。" && audioOut(h) == 1)
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty)
    }
}

@Suite("T-019 F-06 review 5 regressions")
struct DriverTurnPipelineReview5Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 the hold budget never releases audio while navigation evidence is outstanding (B1)")
    func budgetWithOutstandingEvidence() {
        var h = PipelineHarness()
        h.driver("打开空调然后导航回家")
        let a = h.call("c1", "control_climate")
        h.result(a, "control_climate", .success(["power_on": true]))
        for i in 0..<130 {
            h.send(.replyAudio(h.turn, pcm))
            if i % 10 == 0 && i < 110 { h.say("好的") }
        }
        #expect(audioOut(h) == 0)
        h.say("导航已开始。")
        h.close()
        #expect(audioOut(h) == 0 && !h.spoken.contains("导航已开始"))
    }

    @Test("F-06 honest evidenced lines are heard: navigation started, route chosen, music stopped (N1)")
    func evidencedActionClaims() {
        var h = PipelineHarness()
        h.driver("导航去珠海站")
        let c = h.call("c1", "navigate_to")
        h.result(c, "navigate_to", .success())
        h.send(.navigationPhase(.navigating))
        h.say("好的，已为您开始导航。")
        h.close()
        #expect(h.spoken == "好的，已为您开始导航。")

        var m = PipelineHarness()
        m.send(.musicPlaying(true))
        m.driver("关掉音乐")
        let s = m.call("c1", "control_music")
        m.send(.musicPlaying(false))
        m.result(s, "control_music", .success(["status": "stopped"]))
        m.say("好的，已为您关闭音乐。")
        m.close()
        #expect(m.spoken == "好的，已为您关闭音乐。")
        m.advance(by: .seconds(30))
        #expect(m.corrections.isEmpty)
    }
}

@Suite("T-019 F-06 review 6 regressions")
struct DriverTurnPipelineReview6Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 a song already playing does not prove a new 正在播放 (stale evidence)")
    func staleMusic() {
        var h = PipelineHarness()
        h.send(.musicPlaying(true))
        h.driver("播放周杰伦的晴天")
        let c = h.call("c1", "play_music")
        h.result(c, "play_music", .success(["status": "requested_unverified"]))
        h.send(.replyAudio(h.turn, pcm))
        h.say("正在为您播放晴天。")
        h.close()
        #expect(audioOut(h) == 0 && h.spoken.isEmpty)
        // A fresh playback report after the call proves the next one.
        var g = PipelineHarness()
        g.send(.musicPlaying(true))
        g.driver("播放周杰伦的晴天")
        let d = g.call("c1", "play_music")
        g.result(d, "play_music", .success())
        g.send(.musicPlaying(false))
        g.send(.musicPlaying(true))
        g.say("正在为您播放晴天。")
        g.close()
        #expect(g.spoken == "正在为您播放晴天。")
    }

    @Test("F-06 navigating to the old destination does not prove a new 导航已开始 (row 3)")
    func staleNavigation() {
        var h = PipelineHarness()
        h.send(.navigationPhase(.navigating))
        h.driver("导航去机场")
        let c = h.call("c1", "navigate_to")
        h.result(c, "navigate_to", .success(["status": "awaiting_route_selection_on_screen"]))
        h.send(.navigationPhase(.navigating))  // a republished snapshot is not a new start
        h.say("导航已开始。")
        h.close()
        #expect(!h.spoken.contains("导航已开始"))
        h.advance(by: .seconds(2))
        #expect(h.corrections == [.navigationNotStarted])
    }
}

@Suite("T-019 F-06 review 7 regressions")
struct DriverTurnPipelineReview7Tests {
    let pcm = PCMBuffer(sampleRate: 24_000, samples: [0])
    func audioOut(_ h: PipelineHarness) -> Int { h.out.filter { if case .speechAudio = $0 { true } else { false } }.count }

    @Test("F-06 row 1: a music or navigation claim with no tool call is not proven by old state")
    func noToolOldState() {
        var h = PipelineHarness()
        h.send(.musicPlaying(true))
        h.driver("放首稻香")
        h.send(.replyAudio(h.turn, pcm))
        h.say("好的，正在为您播放稻香。")
        h.close()
        #expect(audioOut(h) == 0 && h.spoken.isEmpty)
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.musicNotConfirmed])

        var n = PipelineHarness()
        n.send(.navigationPhase(.navigating))
        n.driver("导航去公司")
        n.send(.replyAudio(n.turn, pcm))
        n.say("好的，导航已开始。")
        n.close()
        #expect(audioOut(n) == 0 && n.spoken.isEmpty)
    }

    @Test("F-06 a repeated playing report of the old track is not fresh evidence")
    func repeatedPlayingReport() {
        var h = PipelineHarness()
        h.send(.musicPlaying(true))
        h.driver("播放周杰伦的晴天")
        let c = h.call("c1", "play_music")
        h.result(c, "play_music", .success())
        h.send(.musicPlaying(true))
        h.say("正在为您播放晴天。")
        h.close()
        #expect(h.spoken.isEmpty)
    }
}

@Suite("T-019 F-06 review 8 follow-up")
struct DriverTurnPipelineReview8Tests {
    @Test("F-06 a question about the running navigation or song is answered truthfully")
    func questionsDoNotStale() {
        var h = PipelineHarness()
        h.send(.navigationPhase(.navigating))
        h.driver("导航还要多久到")
        h.say("正在为您导航，预计还有十分钟。")
        h.close()
        #expect(h.spoken == "正在为您导航，预计还有十分钟。")
        h.driver("还有多远")
        h.say("正在为您导航，还有五公里。")
        h.close()
        #expect(h.spoken.hasSuffix("还有五公里。"))

        var m = PipelineHarness()
        m.send(.musicPlaying(true))
        m.driver("现在播放的是什么歌")
        m.say("现在正在播放的是晴天。")
        m.close()
        #expect(m.spoken == "现在正在播放的是晴天。")
        m.advance(by: .seconds(30))
        #expect(m.corrections.isEmpty)
    }
}
}
