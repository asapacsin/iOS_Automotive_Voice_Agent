import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaVoice

@Suite("T-031b F-12 §14 item 12 claims per tool")
struct ClaimTopicTests {
    @Test("F-12 row 6 「车窗开了」: fan ok only → disproven; window ok → proven; fan ok + window failed → disproven")
    func perTool() {
        var fanOnly = PipelineHarness()
        fanOnly.driver("有点闷")
        let f = fanOnly.call("c1", "control_climate")
        fanOnly.result(f, "control_climate", .success(["action": "adjust_fan", "fan_level": 3]))
        fanOnly.say("车窗打开了，风量也调大了。")
        fanOnly.close()
        #expect(fanOnly.spoken.isEmpty)
        #expect(fanOnly.out.contains(.voided(fanOnly.turn)))

        var window = PipelineHarness()
        window.driver("有点闷")
        let w = window.call("c1", "control_window")
        window.result(w, "control_window", .success(["action": "set"]))
        window.say("车窗打开了。")
        window.close()
        #expect(window.spoken == "车窗打开了。")

        var mixed = PipelineHarness()
        mixed.driver("有点闷")
        let a = mixed.call("c1", "control_climate")
        let b = mixed.call("c2", "control_window")
        mixed.result(a, "control_climate", .success(["action": "adjust_fan"]))
        mixed.result(b, "control_window", .failure(.vehicleExecutionFailed))
        mixed.say("车窗打开了。")
        mixed.close()
        #expect(mixed.spoken.isEmpty)
        mixed.advance(by: .seconds(2))
        #expect(mixed.corrections == [.claimAfterFailure])
    }

    @Test("F-12 item 12 topics: negated clauses and unnamed claims")
    func topics() {
        #expect(ClaimLexicon.claimedTopics(in: "车窗打开了，空调没能打开") == [.windows])
        #expect(ClaimLexicon.claimedTopics(in: "搞定了") == [])
        // Review: compound words only, so honest replies are not disproven.
        #expect(ClaimLexicon.unbackedTopics(in: "已为您打开车窗通风", proofs: [("control_window", [:])]).isEmpty)
        #expect(ClaimLexicon.claimedTopics(in: "座椅已调到合适的高度") == [])
        #expect(ClaimLexicon.claimedTopics(in: "已为你换成温柔风格") == [])
        #expect(ClaimLexicon.claimedTopics(in: "调到了22度") == [.climate])
        #expect(ClaimLexicon.claimedTopics(in: "风量调到了3档") == [.fan])
        #expect(ClaimLexicon.unbackedTopics(in: "风量调到了3档", proofs: [("control_climate", [:])]).isEmpty)
        #expect(ClaimLexicon.unbackedTopics(in: "车窗都开了一半，空调打开了",
                                            proofs: [("run_scenario", ["done": ["车窗开到50%"]])]) == [.climate])
    }
}
