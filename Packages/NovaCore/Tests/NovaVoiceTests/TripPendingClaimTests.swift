import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-040ze F-15b §52 item 12 no done before the trip result")
struct TripPendingClaimTests {
    @Test("T-040ze F-15b row 206 (unit): a done claim while set_trip_plan runs is drift (TRIP_RESULT_PENDING), not spoken; the honest working line is")
    func row206() {
        var h = PipelineHarness()
        h.driver("先千岁机场吧")
        _ = h.call("t1", "set_trip_plan")
        h.say("好的，我已经为您将行程起点设为新千岁机场。")
        h.close()
        #expect(h.out.contains(.voided(h.turn)))
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripResultPending], "\(h.out)")
        #expect(!h.spoken.contains("已经为您"))
        #expect(CorrectionReason.tripResultPending.instruction == "[系统] TRIP_RESULT_PENDING：结果还没回来，不要说已经做好。")
        #expect(ClaimLexicon.claim(in: "我已经为您将行程起点设为新千岁机场") == .action)

        var honest = PipelineHarness()
        honest.driver("先千岁机场吧")
        _ = honest.call("t1", "set_trip_plan")
        honest.say("好，我规划一下，大概半分钟。")
        honest.close()
        honest.advance(by: .seconds(30))
        #expect(honest.corrections.isEmpty && honest.spoken.contains("我规划一下"))

        // Once the result is back, a done claim is proven by it.
        var after = PipelineHarness()
        after.driver("先千岁机场吧")
        let id = after.call("t1", "set_trip_plan")
        after.result(id, "set_trip_plan", .success(["status": "trip_list"]))
        after.say("改好了，起点是新千岁机场。")
        after.close()
        after.advance(by: .seconds(30))
        #expect(!after.corrections.contains(.tripResultPending))
        #expect(AsyncTool.setTripPlan.isTrip && !AsyncTool.webSearch.isTrip && AsyncTool(name: "make_trip_list") == nil)
    }
}

@Suite("T-040zh F-15b §55 item 10 no done claim while the plan has issues")
struct TripNeedsFixClaimTests {
}

@Suite("T-040zh F-15b §55 item 10 review: only a plan-done claim, only within the driver request")
struct TripNeedsFixScopeTests {
}

@Suite("T-046v F-18 §33 item 7 blaming the network after LIVE_INFO_UNAVAILABLE")
struct NetworkBlameTests {
    @Test("T-046v F-18 §33 row 16 (reply side): 「网络有问题」 after LIVE_INFO_UNAVAILABLE reason=quota is drift (NETWORK_BLAMED)")
    func row16() {
        var h = PipelineHarness()
        h.driver("厦门中山路附近有什么景点")
        let id = h.call("s1", "web_search")
        h.result(id, "web_search", .failure(.liveInfoUnavailable, data: ["reason": "quota"]))
        h.say("抱歉，网络有问题，现在查不了。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.networkBlamed], "\(h.out)")
        #expect(!h.spoken.contains("网络"))
        #expect(CorrectionReason.networkBlamed.instruction.hasPrefix("[系统] NETWORK_BLAMED："))

        var ok = PipelineHarness()
        ok.driver("厦门中山路附近有什么景点")
        let s = ok.call("s1", "web_search")
        ok.result(s, "web_search", .failure(.liveInfoUnavailable, data: ["reason": "quota"]))
        ok.say("现在查不了网上的信息。")
        ok.close()
        ok.advance(by: .seconds(30))
        #expect(!ok.corrections.contains(.networkBlamed), "\(ok.out)")
    }
}
