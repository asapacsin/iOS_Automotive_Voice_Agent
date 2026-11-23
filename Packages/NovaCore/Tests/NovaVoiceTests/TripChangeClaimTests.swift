import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools
@testable import NovaVoice

private extension PipelineHarness {
    /// Another model turn of the same driver request (Gemini answers a tool result in a new turn).
    mutating func nextTurn() {
        turn = turn.next()
        send(.turnOpened(turn))
    }
}

private let refused = ToolResult(ok: false, code: .invalidFields,
                                 data: ["problems": ["第2天第3个地点：role 只能是 start、sight、hotel、end"], "changed": false], advice: nil)

@Suite("T-040zk F-15b §58 a trip change is claimed only after it is on the plan")
struct TripChangeClaimTests {
    @Test("T-040zk F-15b row 252: record replay 20261123-102422: set_trip_plan refused, web_search ok, 「我已经…加入了BAMN Coffee」: CLAIM_AFTER_FAILURE, the correction sent, not spoken as done")
    func row252() {
        var h = PipelineHarness()
        h.driver("给我安排一个咖啡的行程，我第二天想喝点咖啡")
        let plan = h.call("t1", "plan_trip")
        h.result(plan, "plan_trip", refused)
        h.close()
        h.nextTurn()
        let search = h.call("s1", "web_search")
        h.result(search, "web_search", .success(["answer": "BAMN Coffee"]))
        h.close()
        h.nextTurn()
        h.say("我已经在您第二天游玩沙坡尾时加入了BAMN Coffee。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripClaimAfterFailure], "\(h.out)")
        #expect(!h.spoken.contains("加入了"))
        #expect(CorrectionReason.tripClaimAfterFailure.instruction
                == "[系统] 行程没有改成，原因在上一个工具结果的 problems 里。如实告诉司机没改成和原因，不要说已经加了。")
        #expect(CorrectionReason.tripClaimAfterFailure.rawValue == "CLAIM_AFTER_FAILURE tool=plan_trip")
        #expect(ClaimLexicon.tripChanged("我已经在您第二天游玩沙坡尾时加入了BAMN Coffee。"))
        #expect(!ClaimLexicon.tripChanged("我没有加入BAMN Coffee，第二天的行程没改。"))
    }

    @Test("T-040zk F-15b row 253: 「我已经在后台更新了行程，可能稍后就会同步」 with no set_trip_plan running: drift, correction sent")
    func row253() {
        var h = PipelineHarness()
        h.driver("没看到")
        let plan = h.call("t1", "plan_trip")
        h.result(plan, "plan_trip", refused)
        h.close()
        h.nextTurn()
        h.say("抱歉，我已经在后台更新了行程，可能稍后就会同步到您的屏幕上。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripClaimAfterFailure], "\(h.out)")
        #expect(!h.spoken.contains("后台"))
        // With no trip write at all in the request: UNVERIFIED_CLAIM.
        var none = PipelineHarness()
        none.driver("加好了吗")
        none.say("我已经在后台更新了行程，可能稍后就会同步。")
        none.close()
        none.advance(by: .seconds(30))
        #expect(none.corrections == [.tripUnverifiedClaim], "\(none.out)")
    }

    @Test("T-040zk F-15b row 254: the same words while a set_trip_plan is running: not drift (TRIP_RESULT_PENDING aside)")
    func row254() {
        var h = PipelineHarness()
        h.driver("第二天加个咖啡馆")
        _ = h.call("t1", "plan_trip")
        h.close()
        h.nextTurn()
        h.say("我在后台更新行程，稍后会同步到屏幕上。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(!h.corrections.contains(.tripClaimAfterFailure) && !h.corrections.contains(.tripUnverifiedClaim), "\(h.out)")
    }

    @Test("T-040zk F-15b row 255: set_trip_plan ok with the café on day 2, 「已经加在第二天了」: proven, spoken")
    func row255() {
        var h = PipelineHarness()
        h.driver("第二天加个咖啡馆")
        let first = h.call("t1", "plan_trip")
        h.result(first, "plan_trip", refused)
        h.close()
        h.nextTurn()
        let second = h.call("t2", "plan_trip")
        h.result(second, "plan_trip", .success(["status": "trip_list"]))
        h.say("BAMN Coffee已经加在第二天了。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty, "\(h.out)")
        #expect(h.spoken.contains("已经加在第二天了"))
        // Another tool's ok never proves it.
        var other = PipelineHarness()
        other.driver("第二天加个咖啡馆")
        let s = other.call("s1", "web_search")
        other.result(s, "web_search", .success(["answer": "BAMN Coffee"]))
        other.say("已经加在第二天了。")
        other.close()
        other.advance(by: .seconds(30))
        #expect(other.corrections == [.tripUnverifiedClaim], "\(other.out)")
    }

    @Test("T-040zk F-15b row 256: async set_trip_plan started: her line says 我在改行程; no done claim until the result")
    func row256() {
        #expect(ToolCatalog.tripEditWorkingLine == "先只说一句：好，我在改行程，好了告诉你。然后不要说话，等结果。")
        #expect(ToolCatalog.setTripPlanDescription.contains("改行程：" + ToolCatalog.tripEditWorkingLine))
        #expect(ToolCatalog.setTripPlanDescription.contains("新行程：" + ToolCatalog.tripWorkingLine))
        var h = PipelineHarness()
        h.driver("第二天加个咖啡馆")
        _ = h.call("t1", "plan_trip")
        h.say("好，我在改行程，好了告诉你。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty && h.spoken.contains("我在改行程"), "\(h.out)")
        var done = PipelineHarness()
        done.driver("第二天加个咖啡馆")
        _ = done.call("t1", "plan_trip")
        done.say("好的，咖啡馆已经加到第二天的行程了。")
        done.close()
        done.advance(by: .seconds(30))
        #expect(done.corrections == [.tripResultPending], "\(done.out)")
    }
}

@Suite("T-040zk F-15b §58 review fixes")
struct TripChangeClaimReviewTests {
    @Test("T-040zk F-15b row 253 (review): a set_trip_plan cancelled or dropped at a reconnect (no result) no longer allows a background claim")
    func endedWriteNoLongerRunning() {
        var h = PipelineHarness()
        h.driver("第二天加个咖啡馆")
        let id = h.call("t1", "plan_trip")
        h.close()
        h.pipeline.callsEnded([id])
        h.driver("好了吗")
        h.say("我已经在后台更新了行程，可能稍后就会同步。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections.contains(.tripUnverifiedClaim), "\(h.out)")
    }

    @Test("T-040zk F-15b row 254 (review): a set_trip_plan still running across 「好了吗」: 「还在后台更新行程」 is not drift")
    func runningWriteAcrossUtterance() {
        var h = PipelineHarness()
        h.driver("第二天加个咖啡馆")
        _ = h.call("t1", "plan_trip")
        h.say("好，我在改行程，好了告诉你。")
        h.close()
        h.driver("好了吗")
        h.say("还在后台更新行程，稍后会同步到屏幕上。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(!h.corrections.contains(.tripUnverifiedClaim) && !h.corrections.contains(.tripClaimAfterFailure), "\(h.out)")
    }
}

@Suite("T-040zo F-15b §62 item 8 a saved trip result is never a failure claim's evidence")
struct TripSavedClaimTests {
    @Test("T-040zo F-15b row 284: replay 74404-84364: a refused write, then a saved one with not_placed; 「行程已经帮您做好了…陈家祠没有找到」: no correction, no CLAIM_AFTER_FAILURE")
    func row284() {
        var h = PipelineHarness()
        h.driver("搞一个广东四天游，然后把这个放进去")
        let first = h.call("t1", "plan_trip")
        h.result(first, "plan_trip", refused)
        h.close()
        h.nextTurn()
        let second = h.call("t2", "plan_trip")
        h.result(second, "plan_trip", .success(["saved": true, "not_placed": [["name": "陈家祠", "searched": "广州"]],
                                                "plan_text": "第1天：广州塔、陈家祠（没找到）"]))
        h.close()
        h.nextTurn()
        h.say("行程已经帮您做好了，四天都安排上了。陈家祠没有找到，您想换一个吗？")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections.isEmpty, "\(h.out)")
        #expect(h.spoken.contains("行程已经帮您做好了"))
        // A failed latest write still disproves a trip claim (§58 stays).
        var f = PipelineHarness()
        f.driver("搞一个广东四天游")
        let only = f.call("t1", "plan_trip")
        f.result(only, "plan_trip", .failure(.plannerFailed))
        f.close()
        f.nextTurn()
        f.say("行程已经改好了。")
        f.close()
        f.advance(by: .seconds(30))
        #expect(f.corrections == [.tripClaimAfterFailure], "\(f.out)")
    }
}
