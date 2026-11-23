import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

@Suite("T-046u F-18 §32 web_search refusal")
struct SearchBudgetTests {
    @Test("T-046u F-18 §32 row 7: a budget refusal is LIVE_INFO_UNAVAILABLE reason=…, one request, no retry")
    func row7() async {
        for reason in [BudgetReason.budget, .repeat, .quota] {
            let service = ScriptedSearch([.fail(.budget(reason)), .reply(grounded)])
            let ex = WebSearchExecutor(service: service, clock: ManualClock())
            let r = await ex.execute(searchCall())
            #expect(r.code == .liveInfoUnavailable)
            #expect(r.data["reason"] == .string(reason.rawValue))
            #expect(r.advice == WebSearchExecutor.budgetAdvice)
            #expect(service.calls.withLock { $0 } == 1)
        }
    }
}

@Suite("T-046v F-18 §33 item 7 quota refusal wording")
struct QuotaWordingTests {
    @Test("T-046v F-18 §33 row 16 (executor side): LIVE_INFO_UNAVAILABLE reason=quota has no network wording in next")
    func row16() async {
        let service = ScriptedSearch([.fail(.budget(.quota))])
        let r = await WebSearchExecutor(service: service, clock: ManualClock()).execute(searchCall())
        #expect(r.code == .liveInfoUnavailable && r.data["reason"] == .string("quota"))
        let advice = r.advice ?? ""
        #expect(advice.hasPrefix("现在查不了网上的信息"))
        #expect(!advice.contains("联网") && !advice.contains("连不上网"))
        #expect(!advice.replacingOccurrences(of: "不要说网络有问题", with: "").contains("网络"))
    }
}
