import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools
@testable import NovaVoice

private let savedWithMissing = ToolResult(ok: true, code: nil, data: [
    "status": "trip_plan", "saved": true,
    "not_placed": [["name": "大三巴牌坊", "searched": "澳门", "reason": "not_found"]],
], advice: nil)

@Suite("T-040zw F-15b §70 item 3 she says only what was placed")
struct TripNotPlacedClaimTests {
    @Test("T-040zw F-15b §70 row 332: plan_trip ok with not_placed 大三巴牌坊; her reply names it as planned: UNVERIFIED_CLAIM tool=plan_trip")
    func row332() {
        var h = PipelineHarness()
        h.driver("周日去澳门，大三巴和威尼斯人")
        let plan = h.call("t1", "plan_trip")
        h.result(plan, "plan_trip", savedWithMissing)
        h.close()
        h.turn = h.turn.next()
        h.send(.turnOpened(h.turn))
        h.say("好的，周日的行程排好了：先去大三巴牌坊，再去威尼斯人。")
        h.close()
        h.advance(by: .seconds(30))
        #expect(h.corrections == [.tripUnverifiedClaim], "\(h.out)")
        #expect(CorrectionReason.tripUnverifiedClaim.rawValue == "UNVERIFIED_CLAIM tool=plan_trip")
        // Saying it was not found is honest.
        var ok = PipelineHarness()
        ok.driver("周日去澳门，大三巴和威尼斯人")
        let plan2 = ok.call("t1", "plan_trip")
        ok.result(plan2, "plan_trip", savedWithMissing)
        ok.close()
        ok.turn = ok.turn.next()
        ok.send(.turnOpened(ok.turn))
        // In two chunks, the name first: judged on the whole reply (review 2026-11-26).
        ok.say("行程排好了，不过大三巴牌坊")
        ok.say("地图没找到。")
        ok.close()
        ok.advance(by: .seconds(30))
        #expect(ok.corrections.isEmpty, "\(ok.out)")
        #expect(DriverTurnPipeline.notPlacedNames(savedWithMissing.data["not_placed"]) == ["大三巴牌坊"])
    }
}
