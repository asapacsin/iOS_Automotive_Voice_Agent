import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools
@testable import NovaVoice

/// F-15b §70 item 3 (T-040zw): a stop from `not_placed`, named in her reply as planned, gets UNVERIFIED_CLAIM tool=plan_trip.

private let withMiss = ToolResult.success([
    "status": "trip_list",
    "not_placed": [["name": "大三巴牌坊", "reason": "not_found"]],
    "stops": [["index": 1, "name": "澳门旅游塔"]],
])

@Suite("T-040zw F-15b §70 she names only placed stops")
struct TripNotPlacedClaimTests {
    @Test("T-040zw F-15b §70 row 332: plan_trip result with not_placed 大三巴牌坊; her reply names 大三巴牌坊 as planned: UNVERIFIED_CLAIM tool=plan_trip")
    func row332() {
        var h = PipelineHarness()
        h.driver("周日去澳门，大三巴和旅游塔")
        let plan = h.call("t1", "plan_trip")
        h.result(plan, "plan_trip", withMiss)
        h.say("周日的行程排好了：先去大三巴牌坊，再去澳门旅游塔。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripUnverifiedClaim], "\(h.out)")
        #expect(!h.spoken.contains("大三巴牌坊"))
        #expect(CorrectionReason.tripUnverifiedClaim.rawValue == "UNVERIFIED_CLAIM tool=plan_trip")
        // Saying only what was placed is not corrected.
        var ok = PipelineHarness()
        ok.driver("周日去澳门，大三巴和旅游塔")
        let p2 = ok.call("t1", "plan_trip")
        ok.result(p2, "plan_trip", withMiss)
        ok.say("周日的行程排好了，去澳门旅游塔。")
        ok.close()
        ok.advance(by: .seconds(30))
        #expect(ok.corrections.isEmpty, "\(ok.out)")
        // Saying the map did not find it (what `next` asks) is honest, not a claim.
        var honest = PipelineHarness()
        honest.driver("周日去澳门，大三巴和旅游塔")
        let p3 = honest.call("t1", "plan_trip")
        honest.result(p3, "plan_trip", withMiss)
        honest.say("排好了澳门旅游塔；大三巴牌坊地图没找到。")
        honest.close()
        honest.advance(by: .seconds(30))
        #expect(honest.corrections.isEmpty, "\(honest.out)")
    }
}
