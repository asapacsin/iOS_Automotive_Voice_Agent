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
    @Test("T-040zh F-15b row 228 (unit): 「我为您规划好了」 while the last trip result is trip_needs_fix with a round left is drift (TRIP_NEEDS_FIX); after a trip_list it is not")
    func row228() {
        var h = PipelineHarness()
        h.driver("帮我规划一下上海五天的行程")
        let id = h.call("t1", "set_trip_plan")
        h.result(id, "set_trip_plan", .success(["status": "trip_needs_fix", "round": 1]))
        h.say("我为您规划好了上海五天的行程。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripNeedsFix], "\(h.out)")
        #expect(!h.spoken.contains("规划好了"))
        #expect(ClaimLexicon.claim(in: "我为您规划好了") == .action)
        #expect(CorrectionReason.tripNeedsFix.instruction.hasPrefix("[系统] TRIP_NEEDS_FIX："))

        // The fixed plan comes back as trip_list: the claim is proven by it.
        var fixed = PipelineHarness()
        fixed.driver("帮我规划一下上海五天的行程")
        let first = fixed.call("t1", "set_trip_plan")
        fixed.result(first, "set_trip_plan", .success(["status": "trip_needs_fix", "round": 1]))
        let second = fixed.call("t2", "set_trip_plan")
        fixed.result(second, "set_trip_plan", .success(["status": "trip_list"]))
        fixed.say("我为您规划好了上海五天的行程。")
        fixed.close()
        fixed.advance(by: .seconds(30))
        #expect(!fixed.corrections.contains(.tripNeedsFix), "\(fixed.out)")
    }
}
