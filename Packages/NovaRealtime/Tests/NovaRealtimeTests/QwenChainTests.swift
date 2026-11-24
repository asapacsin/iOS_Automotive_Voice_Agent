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
    @Test("T-046y F-18 §36 item 1: one ordered list per job; every listed model evaluated, the rest awaiting row 35; no model name outside QwenRoute")
    func table() {
        #expect(QwenRoute.Job.allCases.count == 6 && QwenRoute.all.count == 6)
        #expect(QwenRoute.live.chain.map(\.model) == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        #expect(QwenRoute.live.awaitingEval.map(\.model) == ["qwen3.8-max"])
        #expect(QwenRoute.ground.chain.map(\.model) == ["qwen3.7-plus", "qwen3.7-flash-2026-07-15"])
        #expect(QwenRoute.picker.chain.map(\.model) == ["qwen3.8-flash"])
        #expect(QwenRoute.picker.awaitingEval.map(\.model) == ["qwen3.8-max", "qwen3.8-max-0902"])
        #expect(QwenRoute.planner.chain.map(\.model) == ["qwen3.8-flash"] && QwenRoute.plannerModel == "qwen3.8-flash")
        #expect(QwenRoute.eventsLoop.chain.allSatisfy(\.thinking) && QwenRoute.eventsLoop.awaitingEval.allSatisfy(\.thinking))
        #expect(QwenRoute.eventsLoop.awaitingEval.map(\.model) == ["qwen3.8-max-0902", "qwen3.8-2.4t-a95b"])
        #expect(QwenRoute.eventsSearch.chain.allSatisfy { $0.search?.strategy == "max" })
        for r in QwenRoute.all {
            #expect(Set(r.chain.map(\.model)).isDisjoint(with: r.awaitingEval.map(\.model)), "\(r.job)")
        }
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
        let sender = Sender { $0 == "qwen3.7-flash-2026-07-15" ? (429, throttled) : (200, liveAnswer) }
        let client = QwenWebSearchClient(key: { "k" }, send: sender.send, fallback: fallback)
        _ = try await client.search("q", attempt: 1)
        #expect(sender.sent == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        #expect(lines.all == ["qwen fallback job=live from=qwen3.7-flash-2026-07-15 to=qwen3.8-flash reason=rate"])
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
