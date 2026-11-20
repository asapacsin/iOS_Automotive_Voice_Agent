import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts

private final class Lines: Sendable {
    private let m = Mutex<[String]>([])
    func add(_ l: String) { m.withLock { $0.append(l) } }
    var all: [String] { m.withLock { $0 } }
}

private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let noon = Date(timeIntervalSince1970: 1_795_000_000)  // a fixed instant

final class Now: Sendable {
    private let m: Mutex<Date>
    init(_ d: Date) { m = Mutex(d) }
    var value: Date { m.withLock { $0 } }
    func set(_ d: Date) { m.withLock { $0 = d } }
}

private func budget(_ store: any BudgetStore = MemoryBudgetStore(), clock: ManualClock = ManualClock(),
                    now: Now? = nil, lines: Lines = Lines()) -> CallBudget {
    return CallBudget(store: store, clock: clock, now: { now?.value ?? noon }, zone: { shanghai },
                      log: { lines.add($0) })
}

@Suite("T-046u F-18 §32 CallBudget")
struct CallBudgetTests {
    @Test("T-046u F-18 §32 row 1: one turn asks qwen.live 3 times: 2 allowed, the 3rd refused budget")
    func row1() {
        let b = budget()
        let m = "qwen3.7-flash-2026-07-15"
        #expect(b.ask(.qwenLive, model: m, key: "a") == .allow)
        #expect(b.ask(.qwenLive, model: m, key: "b") == .allow)
        #expect(b.ask(.qwenLive, model: m, key: "c") == .refuse(.budget))
        b.newTurn()
        #expect(b.ask(.qwenLive, model: m, key: "d") == .allow)
        #expect(b.ask(.qwenPicker, model: m, key: "e") == .allow)
        #expect(b.ask(.glmVision, model: "glm", key: "f") == .allow)
        #expect(b.ask(.geminiVision, model: "g", key: "g") == .refuse(.budget))  // 3 over all routes
    }

    @Test("T-046u F-18 §32 row 2: the 41st paid call in one session is refused budget")
    func row2() {
        let b = budget()
        for i in 0..<40 {
            b.newTurn()
            #expect(b.ask(.qwenLive, model: "m", key: "\(i)") == .allow)
        }
        b.newTurn()
        #expect(b.ask(.qwenLive, model: "m", key: "x") == .refuse(.budget))
        b.newSession()
        #expect(b.ask(.qwenLive, model: "m", key: "x") == .allow)
    }

    @Test("T-046u F-18 §32 row 3: the day limit holds over a restart and resets after local midnight")
    func row3() {
        let store = MemoryBudgetStore(BudgetDay(date: CallBudget.date(noon, shanghai), calls: 300))
        let now = Now(noon)
        #expect(budget(store, now: now).ask(.qwenLive, model: "m", key: "a") == .refuse(.budget))
        // Restart: a new budget on the same store.
        #expect(budget(store, now: now).ask(.qwenLive, model: "m", key: "a") == .refuse(.budget))
        now.set(noon.addingTimeInterval(86_400))
        #expect(budget(store, now: now).ask(.qwenLive, model: "m", key: "a") == .allow)
        // Tokens count too.
        let t = MemoryBudgetStore(BudgetDay(date: CallBudget.date(noon, shanghai), tokens: 300_000))
        #expect(budget(t).ask(.qwenLive, model: "m", key: "a") == .refuse(.budget))
    }

    @Test("T-046u F-18 §32 row 4: the same query a 3rd time within 10 min is refused repeat; after 10 min allowed")
    func row4() {
        let clock = ManualClock()
        let b = budget(clock: clock)
        let k = CallBudget.key(.qwenLive, model: "m", text: "  上海油价 ")
        #expect(k == CallBudget.key(.qwenLive, model: "m", text: "上海油价"))
        #expect(CallBudget.key(.qwenPicker, model: "m", text: "x", coordinates: [39.90049])
                == CallBudget.key(.qwenPicker, model: "m", text: "X", coordinates: [39.9002]))
        for _ in 0..<2 { b.newTurn(); #expect(b.ask(.qwenLive, model: "m", key: k) == .allow) }
        b.newTurn()
        #expect(b.ask(.qwenLive, model: "m", key: k) == .refuse(.repeat))
        clock.advance(by: .minutes(10))
        b.newTurn()
        #expect(b.ask(.qwenLive, model: "m", key: k) == .allow)
    }

    @Test("T-046u F-18 §32 row 5 (budget side): a quota error refuses that model until local midnight; tts counted, not capped")
    func row5() {
        let now = Now(noon)
        let store = MemoryBudgetStore()
        let b = budget(store, now: now)
        #expect(b.ask(.qwenLive, model: "m1", key: "a") == .allow)
        b.done(.qwenLive, model: "m1", ok: false, tokens: nil, quotaError: true)
        b.newTurn()
        #expect(b.ask(.qwenLive, model: "m1", key: "b") == .refuse(.quota))
        b.newTurn()
        #expect(b.ask(.qwenLive, model: "m2", key: "b") == .allow)
        #expect(budget(store, now: now).ask(.qwenLive, model: "m1", key: "c") == .refuse(.quota))  // restart
        now.set(noon.addingTimeInterval(86_400))
        #expect(budget(store, now: now).ask(.qwenLive, model: "m1", key: "c") == .allow)
        let t = budget()
        for _ in 0..<400 { #expect(t.ask(.qwenTTS, model: "tts", key: "") == .allow) }
        // Her voice uses none of the shared counters: a search is still allowed after 400 tts calls.
        #expect(t.ask(.qwenLive, model: "m", key: "a") == .allow)
    }

    @Test("T-046u F-18 §32 row 7 (budget side): after a refusal the same turn makes no further paid call")
    func row7() {
        let b = budget()
        #expect(b.ask(.qwenLive, model: "m", key: "a") == .allow)
        #expect(b.ask(.qwenLive, model: "m", key: "b") == .allow)
        #expect(b.ask(.qwenLive, model: "m", key: "c") == .refuse(.budget))
        #expect(b.ask(.qwenPicker, model: "m", key: "d") == .refuse(.budget))
    }

    @Test("T-046u F-18 §32 row 8: paid lines carry counts and refusals, never the query")
    func row8() {
        let lines = Lines()
        let b = budget(lines: lines)
        let k = CallBudget.key(.qwenLive, model: "m", text: "上海油价 31.2304,121.4737")
        #expect(b.ask(.qwenLive, model: "m", key: k) == .allow)
        b.done(.qwenLive, model: "m", ok: true, tokens: CallBudget.reportedTokens(Data(#"data:{"usage":{"total_tokens": 812}}"#.utf8)))
        b.newTurn(); _ = b.ask(.qwenLive, model: "m", key: k); b.newTurn()
        #expect(b.ask(PaidRoute.qwenLive, model: "m", key: k) == BudgetDecision.refuse(.repeat))
        #expect(lines.all == [
            "paid route=qwen.live model=m ok=yes tokens=812 turnN=1 sessionN=1 dayN=1 dayTokens=812",
            "paid route=qwen.live model=m refused=repeat",
        ])
        #expect(!lines.all.joined().contains("上海") && !lines.all.joined().contains("31.2"))
        #expect(CallBudget.reportedTokens(Data(#"{"usageMetadata":{"totalTokenCount":55}}"#.utf8)) == 55)
    }

    @Test("T-046u F-18 §32 item 3: quota codes as the vendors publish them; rate limits are not quota")
    func quotaCodes() {
        #expect(QuotaError.dashScope(status: 403, code: "AllocationQuota.FreeTierOnly", message: nil))
        #expect(QuotaError.dashScope(status: 429, code: "BudgetLimitExceeded", message: nil))
        #expect(QuotaError.dashScope(status: 429, code: "Throttling.AllocationQuota", message: "Free allocated quota exceeded."))
        #expect(!QuotaError.dashScope(status: 429, code: "Throttling.AllocationQuota",
                                      message: "Allocated quota exceeded, please increase your quota limit."))
        #expect(!QuotaError.dashScope(status: 429, code: "Throttling.RateQuota", message: nil))
        #expect(QuotaError.gemini(status: 429, body: Data(#"{"error":{"code":"quota_exceeded"}}"#.utf8)))
        #expect(!QuotaError.gemini(status: 429, body: Data(#"{"error":{"code":"rate_limit_exceeded"}}"#.utf8)))
    }
}
