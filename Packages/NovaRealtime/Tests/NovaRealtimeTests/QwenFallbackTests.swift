import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaRealtime

/// A fake transport: replies in order (the last one repeats), each after the manual clock moves `after` ms.
private final class FakeQwen: Sendable {
    struct Sent: Sendable {
        let model: String
        let strategy: String?
        let body: JSONValue
        let timeout: TimeInterval
    }

    enum Reply: Sendable {
        case http(Int, String)
        case fail(URLError.Code)
    }

    let sent = Mutex<[Sent]>([])
    private let replies: Mutex<[(after: Int64, reply: Reply)]>
    private let clock: ManualClock

    init(_ clock: ManualClock, _ replies: [(after: Int64, reply: Reply)]) {
        self.clock = clock
        self.replies = Mutex(replies)
    }

    var models: [String] { sent.withLock { $0.map(\.model) } }

    var send: QwenWebSearchClient.Send {
        { [self] request in
            let body = (try? JSONDecoder().decode(JSONValue.self, from: request.httpBody ?? Data())) ?? .null
            sent.withLock {
                $0.append(Sent(model: body["model"]?.stringValue ?? "",
                               strategy: body["parameters"]?["search_options"]?["search_strategy"]?.stringValue,
                               body: body, timeout: request.timeoutInterval))
            }
            let next = replies.withLock { r in r.count > 1 ? r.removeFirst() : r[0] }
            clock.advance(by: .milliseconds(next.after))
            switch next.reply {
            case .http(let status, let text): return (status, Data(text.utf8))
            case .fail(let code): throw URLError(code)
            }
        }
    }
}

private final class Lines: Sendable {
    private let m = Mutex<[String]>([])
    func add(_ l: String) { m.withLock { $0.append(l) } }
    var all: [String] { m.withLock { $0 } }
}

private func rig(_ replies: [(after: Int64, reply: FakeQwen.Reply)]) -> (FakeQwen, QwenFallback, ManualClock, Lines) {
    let clock = ManualClock()
    let lines = Lines()
    let fallback = QwenFallback(clock: clock, log: { l in lines.add(l) })
    return (FakeQwen(clock, replies), fallback, clock, lines)
}

private let liveAnswer = #"data:{"output":{"choices":[{"message":{"content":[{"text":"晴，20度。"}]}}],"search_info":{"search_results":[{"title":"t","url":"https://weather.example/x"}]}}}"#
private let pickAnswer = #"{"output":{"choices":[{"message":{"content":"1: 2"}}]}}"#
private let quota403 = #"{"code":"AllocationQuota.FreeTierOnly","message":"m"}"#
private let throttled = #"{"code":"Throttling.RateQuota","message":"m"}"#

private func place(_ name: String) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: 39.9, longitude: 116.4, datum: .gcj02),
          distanceMeters: nil, district: nil)
}
private let choices = [PlaceChoice(asked: "北京故宫", city: "北京", candidates: [place("北京故宫博物院北院区"), place("故宫博物院")])]

private func dropModel(_ v: JSONValue) -> JSONValue {
    guard case .object(var o) = v else { return v }
    o["model"] = nil
    return .object(o)
}

@Suite("T-040x F-15b §50 item 10 backup Qwen model on 429 or used-up quota")
struct QwenFallbackTests {
    @Test("T-040x F-15b row 156: live 429 before any answer: one backup request, same body except model; answer used; backup first within 60 s")
    func row156() async throws {
        let (fake, fallback, clock, lines) = rig([(100, .http(429, throttled)), (200, .http(200, liveAnswer))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        let reply = try await client.search("北京天气", attempt: 1)
        #expect(reply.answer == "晴，20度。")
        #expect(fake.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017"])
        let sent = fake.sent.withLock { $0 }
        #expect(dropModel(sent[0].body) == dropModel(sent[1].body))
        #expect(lines.all == ["qwen fallback job=live from=deepseek-v4.1-flash to=deepseek-v4.1-flash-1017 reason=rate"])
        #expect(fallback.skipped(.live) == .rateLimit)

        clock.advance(by: .seconds(59))
        _ = try await client.search("北京天气", attempt: 1)
        #expect(fake.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "deepseek-v4.1-flash-1017"])
        clock.advance(by: .seconds(1))
        #expect(fallback.skipped(.live) == nil)
        _ = try await client.search("北京天气", attempt: 1)
        #expect(fake.models.last == "deepseek-v4.1-flash")
    }

    @Test("T-046zc F-18 §40 item 2 (replaces §59's one-model picker): quota 403 or 429 on the first picker model moves to deepseek-v4.1-flash; InvalidApiKey 403, 401, 500, timeout one call, no move, no mark")
    func pickerChain() async throws {
        let moves: [(FakeQwen.Reply, String)] = [(.http(403, quota403), "quota"), (.http(429, throttled), "rate")]
        for (reply, why) in moves {
            let (fake, fallback, _, lines) = rig([(10, reply), (10, .http(200, pickAnswer))])
            let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
            #expect(try await picker.pick(choices) == [1])
            #expect(fake.models == ["qwen3.8-max-0902", "deepseek-v4.1-flash"])
            #expect(lines.all.contains("qwen fallback job=picker from=qwen3.8-max-0902 to=deepseek-v4.1-flash reason=\(why)"), "\(lines.all)")
            #expect(fallback.skipped(.picker) == (why == "quota" ? .quota : .rateLimit))
        }
        for reply in [FakeQwen.Reply.http(403, #"{"code":"InvalidApiKey","message":"m"}"#), .http(401, "{}"), .http(500, "{}"), .fail(.timedOut)] {
            let (fake, fallback, _, lines) = rig([(10, reply), (10, .http(200, pickAnswer))])
            let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
            await #expect(throws: (any Error).self) { try await picker.pick(choices) }
            #expect(fake.models == ["qwen3.8-max-0902"])
            #expect(fallback.skipped(.picker) == nil && lines.all.isEmpty)
        }
    }

    @Test("T-040x F-15b row 158: an error after the answer started never switches; 429 on every entry tries each once (F-18 §40 chain)")
    func row158() async throws {
        let started = #"data:{"output":{"choices":[{"message":{"content":[{"text":"晴"}]}}]}}"# + "\n"
            + #"data:{"code":"Throttling.RateQuota","message":"m"}"#
        let (fake, fallback, _, lines) = rig([(10, .http(200, started))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        await #expect(throws: WebSearchError.api("Throttling.RateQuota")) { try await client.search("q", attempt: 1) }
        #expect(fake.models == ["deepseek-v4.1-flash"] && lines.all.isEmpty)

        let (twice, fallback2, _, lines2) = rig([(10, .http(429, throttled))])
        let live = QwenWebSearchClient(key: { "k" }, send: twice.send, fallback: fallback2)
        await #expect(throws: WebSearchError.http(429, code: "Throttling.RateQuota")) { try await live.search("q", attempt: 1) }
        // F-18 §36 item 2 with §40: each entry at most once; the last 429 stands.
        #expect(twice.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "qwen4-max"])
        #expect(lines2.all == ["qwen fallback job=live from=deepseek-v4.1-flash to=deepseek-v4.1-flash-1017 reason=rate",
                               "qwen fallback job=live from=deepseek-v4.1-flash-1017 to=qwen4-max reason=rate"])

        // ground (F-18 §40): every entry with turbo; the last 429 falls back to the model's places (failed).
        let (g, fallback3, _, lines3) = rig([(10, .http(429, throttled))])
        let grounder = QwenTripGrounder(key: { "k" }, send: g.send, fallback: fallback3)
        let request = TripGroundRequest(city: "Tokyo, Japan", days: 1, places: [TripGroundPlace(name: "浅草寺", minutes: 60, importance: 3)],
                                        wishes: nil, start: nil, end: nil, hotelNear: nil)
        await #expect(throws: TripGroundError.failed) { try await grounder.ground(request) }
        #expect(g.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "qwen4-max"])
        #expect(g.sent.withLock { $0.map(\.strategy) } == ["turbo", "turbo", "turbo"])
        #expect(lines3.all.count == 2 && lines3.all.first == "qwen fallback job=ground from=deepseek-v4.1-flash to=deepseek-v4.1-flash-1017 reason=rate")
    }

    @Test("T-046zc F-18 §40 with F-15b row 260: picker 429 at 2.0 s: the next model gets only the 0.5 s left of the 2.5 s")
    func row260Transport() async throws {
        let (fake, fallback, _, _) = rig([(2000, .http(429, throttled)), (100, .http(200, pickAnswer))])
        let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
        #expect(try await picker.pick(choices) == [1])
        #expect(fake.models == ["qwen3.8-max-0902", "deepseek-v4.1-flash"])
        #expect(fake.sent.withLock { $0.last?.timeout } == 0.5)
        #expect(picker.model == "qwen3.8-max-0902")
    }
}

/// F-18 §32 (T-046u) rows 5-7 through the real `QwenFallback` and `QwenWebSearchClient`.
@Suite("T-046u F-18 §32 budget in QwenFallback")
struct QwenFallbackBudgetTests {
    private func setup(_ replies: [(after: Int64, reply: FakeQwen.Reply)]) -> (FakeQwen, QwenFallback, CallBudget) {
        let clock = ManualClock()
        let budget = CallBudget(clock: clock)
        return (FakeQwen(clock, replies), QwenFallback(clock: clock, budget: budget), budget)
    }

    @Test("T-046u F-18 §32 row 5: a quota 403 tries the backup once; later calls skip the used-up model")
    func row5() async throws {
        let (fake, fallback, budget) = setup([(10, .http(403, quota403)), (10, .http(200, liveAnswer))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        _ = try await client.search("q1", attempt: 1)
        #expect(fake.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017"])
        budget.newTurn()
        let fresh = QwenFallback(clock: ManualClock(), budget: budget)  // a restart keeps the day's breaker
        let again = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fresh)
        _ = try await again.search("q2", attempt: 1)
        #expect(fake.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017", "deepseek-v4.1-flash-1017"])
    }

    @Test("T-046u F-18 §32 row 6: a 429 rate limit is retried once on the backup; the breaker stays closed")
    func row6() async throws {
        let (fake, fallback, budget) = setup([(10, .http(429, throttled)), (10, .http(200, liveAnswer))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        _ = try await client.search("q", attempt: 1)
        #expect(fake.models == ["deepseek-v4.1-flash", "deepseek-v4.1-flash-1017"])
        budget.newTurn()
        #expect(budget.ask(.qwenLive, model: "deepseek-v4.1-flash", key: "other") == .allow)
    }

    @Test("T-046u F-18 §32 row 7: a refused call sends nothing and reaches the tool as WebSearchError.budget")
    func row7() async throws {
        let (fake, fallback, _) = setup([(10, .http(200, liveAnswer))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        _ = try await client.search("q", attempt: 1)
        _ = try await client.search("q", attempt: 1)
        await #expect(throws: WebSearchError.budget(.budget)) { try await client.search("q", attempt: 1) }
        #expect(fake.models.count == 2)
    }
}
