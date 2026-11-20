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
