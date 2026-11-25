import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaRealtime

/// F-18 §36 (T-046y): every Qwen job has an ordered model list; 429 / quota 403 move to the next entry.
private final class Sender: Sendable {
    let models = Mutex<[String]>([])
    private let reply: @Sendable (String) -> (Int, String)
    init(_ reply: @escaping @Sendable (String) -> (Int, String)) { self.reply = reply }
    var send: QwenWebSearchClient.Send {
        { [self] request in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
            let model = body["model"]?.stringValue ?? ""
            models.withLock { $0.append(model) }
            let (status, text) = reply(model)
            return (status, Data(text.utf8))
        }
    }
    var sent: [String] { models.withLock { $0 } }
}

private final class Lines: Sendable {
    private let m = Mutex<[String]>([])
    func add(_ l: String) { m.withLock { $0.append(l) } }
    var all: [String] { m.withLock { $0 } }
}

private let quota403 = #"{"code":"AllocationQuota.FreeTierOnly","message":"m"}"#
private let throttled = #"{"code":"Throttling.RateQuota","message":"m"}"#
private let planAnswer = #"{"choices":[{"message":{"role":"assistant","content":"{\"days\":[],\"done\":true}"}}]}"#
private let liveAnswer = #"data:{"output":{"choices":[{"message":{"content":[{"text":"晴"}]}}],"search_info":{"search_results":[{"title":"t","url":"https://w.example/x"}]}}}"#

/// The planner job on three sibling models, as §36 item 1 lists them once row 35 passes.
private let threePlanners = QwenRoute(job: .planner, chain: [
    .init(model: "m1", search: nil, thinking: false), .init(model: "m2", search: nil, thinking: false),
    .init(model: "m3", search: nil, thinking: false)], stream: false, budget: .seconds(30))

@Suite("T-046y F-18 §36 Qwen backup chains")
struct QwenChainTests {
    @Test("T-046zc F-18 §40 rows 57-58: Beijing endpoints; search jobs deepseek-v4.1-flash → -1017 → qwen4-max, text jobs qwen3.8-max-0902 → deepseek-v4.1-flash → -1017 → kimi-k3.1-pro → qwen4-max; awaitingEval empty; only the five models")
    func table() {
        #expect(QwenRoute.Job.allCases.count == 6 && QwenRoute.all.count == 6)
        #expect(QwenRoute.endpoint == "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation")
        #expect(QwenRoute.plannerEndpoint == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        let search = ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "qwen4-max"]
        let text = ["qwen3.8-max-0902", "deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "kimi-k3.1-pro", "qwen4-max"]
        for r in [QwenRoute.live, .ground, .eventsSearch] { #expect(r.chain.map(\.model) == search, "\(r.job)") }
        for r in [QwenRoute.picker, .planner, .eventsExtract] { #expect(r.chain.map(\.model) == text, "\(r.job)") }
        #expect(QwenRoute.plannerModel == "qwen3.8-max-0902")
        #expect(QwenRoute.live.chain.allSatisfy { $0.search?.strategy == "turbo" } && QwenRoute.ground.chain.allSatisfy { $0.search?.strategy == "turbo" })
        #expect(QwenRoute.eventsSearch.chain.allSatisfy { $0.search?.strategy == "max" && $0.search?.forced == true && $0.search?.enableSource == true })
        #expect([QwenRoute.picker, .planner, .eventsExtract].allSatisfy { $0.chain.allSatisfy { $0.search == nil } })
        #expect(!QwenRoute.eventsExtract.stream)
        for r in QwenRoute.all {
            #expect(r.awaitingEval.isEmpty, "\(r.job)")
            #expect(r.chain.allSatisfy { !$0.thinking }, "\(r.job)")
            // Row 58: only item 3's five models.
            #expect(Set(r.chain.map(\.model)).isSubset(of: QwenRoute.allowedModels), "\(r.job)")
        }
        #expect(QwenRoute.allowedModels == Set(text))
    }

    @Test("T-046zc F-18 §40 row 59: 403 AllocationQuota.FreeTierOnly on the first planner model: the next answers; record fallback reason=quota")
    func row59() async throws {
        let lines = Lines()
        let fallback = QwenFallback(clock: ManualClock(), log: { lines.add($0) })
        let freeTier = #"{"code":"AllocationQuota.FreeTierOnly","message":"free tier used up"}"#
        let sender = Sender { $0 == "qwen3.8-max-0902" ? (403, freeTier) : (200, planAnswer) }
        let client = QwenTripPlannerClient(key: { "k" }, send: sender.send, fallback: fallback)
        let text = try await client.complete(system: "S", messages: [TripPlannerMessage(role: .user, content: "U")])
        #expect(text == #"{"days":[],"done":true}"#)
        #expect(sender.sent == ["qwen3.8-max-0902", "deepseek-v4.1-flash"])
        #expect(lines.all.contains("qwen fallback job=planner from=qwen3.8-max-0902 to=deepseek-v4.1-flash reason=quota"), "\(lines.all)")
    }

    @Test("T-046y F-18 §36 row 33: planner first model 403 quota, second 200: plan made by the second; record fallback and exhausted")
    func row33() async throws {
        let lines = Lines()
        let fallback = QwenFallback(clock: ManualClock(), log: { lines.add($0) })
        let sender = Sender { $0 == "m1" ? (403, quota403) : (200, planAnswer) }
        let client = QwenTripPlannerClient(key: { "k" }, send: sender.send, route: threePlanners, fallback: fallback)
        let text = try await client.complete(system: "S", messages: [TripPlannerMessage(role: .user, content: "U")])
        #expect(text == #"{"days":[],"done":true}"#)
        #expect(sender.sent == ["m1", "m2"])
        #expect(lines.all == ["qwen exhausted model=m1", "qwen fallback job=planner from=m1 to=m2 reason=quota"])
        #expect(fallback.usedUpModels() == ["m1"])
        // The next round starts at the first entry not marked.
        _ = try await client.complete(system: "S", messages: [])
        #expect(sender.sent == ["m1", "m2", "m2"])
    }

    @Test("T-046y F-18 §36 row 34: all three planner entries 403: PLANNER_FAILED path; later calls fail at once with no request until 24 h or a restart")
    func row34() async throws {
        let clock = ManualClock()
        let lines = Lines()
        let fallback = QwenFallback(clock: clock, log: { lines.add($0) })
        let sender = Sender { _ in (403, quota403) }
        let client = QwenTripPlannerClient(key: { "k" }, send: sender.send, route: threePlanners, fallback: fallback)
        await #expect(throws: TripPlannerModelError.http(403)) { try await client.complete(system: "S", messages: []) }
        #expect(sender.sent == ["m1", "m2", "m3"])
        #expect(lines.all.filter { $0.hasPrefix("qwen exhausted") }.count == 3)
        await #expect(throws: TripPlannerModelError.http(403)) { try await client.complete(system: "S", messages: []) }
        #expect(sender.sent.count == 3)
        clock.advance(by: .seconds(23 * 3600))
        await #expect(throws: TripPlannerModelError.http(403)) { try await client.complete(system: "S", messages: []) }
        #expect(sender.sent.count == 3)
        clock.advance(by: .seconds(3600))
        await #expect(throws: TripPlannerModelError.http(403)) { try await client.complete(system: "S", messages: []) }
        #expect(sender.sent.count == 6)
        // A restart is a new process-wide state.
        let restarted = QwenTripPlannerClient(key: { "k" }, send: Sender { _ in (200, planAnswer) }.send, route: threePlanners,
                                              fallback: QwenFallback(clock: clock))
        _ = try await restarted.complete(system: "S", messages: [])
        // Any other error is the job's failure: no move.
        let other = Sender { _ in (500, "{}") }
        let c500 = QwenTripPlannerClient(key: { "k" }, send: other.send, route: threePlanners, fallback: QwenFallback(clock: clock))
        await #expect(throws: TripPlannerModelError.http(500)) { try await c500.complete(system: "S", messages: []) }
        #expect(other.sent == ["m1"])
    }

    @Test("T-046y F-18 §36 row 36: 429 on the live route: 60 s cooldown, next entry used, no exhausted mark")
    func row36() async throws {
        let clock = ManualClock()
        let lines = Lines()
        let fallback = QwenFallback(clock: clock, log: { lines.add($0) })
        let sender = Sender { $0 == "deepseek-v4.1-flash" ? (429, throttled) : (200, liveAnswer) }
        let client = QwenWebSearchClient(key: { "k" }, send: sender.send, fallback: fallback)
        _ = try await client.search("q", attempt: 1)
        #expect(sender.sent == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017"])
        #expect(lines.all == ["qwen fallback job=live from=deepseek-v4.1-flash to=deepseek-v4.1-flash-1017 reason=rate"])
        #expect(fallback.usedUpModels().isEmpty && fallback.skipped(.live) == .rateLimit)
        clock.advance(by: .seconds(60))
        #expect(fallback.skipped(.live) == nil)
    }

    @Test("T-046y F-18 §36 item 2: a later entry gets only what is left of the job's time; none left: no call")
    func budgetLeft() async throws {
        let clock = ManualClock()
        let fallback = QwenFallback(clock: clock)
        let timeouts = Mutex<[NovaDuration?]>([])
        let last = try await fallback.run(threePlanners) { route, timeout in
            timeouts.withLock { $0.append(timeout) }
            clock.advance(by: .seconds(20))
            return (429, Data(throttled.utf8))
        }
        #expect(last.status == 429)  // the last reply stands; the caller's failure path runs
        #expect(timeouts.withLock { $0 } == [nil, .seconds(10)])
    }
}
