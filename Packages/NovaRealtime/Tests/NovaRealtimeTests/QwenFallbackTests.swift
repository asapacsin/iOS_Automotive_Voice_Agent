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
        #expect(fake.models == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        let sent = fake.sent.withLock { $0 }
        #expect(dropModel(sent[0].body) == dropModel(sent[1].body))
        #expect(lines.all == ["qwen fallback route=live from=qwen3.7-flash to=qwen3.8-flash reason=429 ok=yes ms=300"])
        #expect(fallback.skipped(.live) == .rateLimit)

        clock.advance(by: .seconds(59))
        _ = try await client.search("北京天气", attempt: 1)
        #expect(fake.models == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash", "qwen3.8-flash"])
        clock.advance(by: .seconds(1))
        #expect(fallback.skipped(.live) == nil)
        _ = try await client.search("北京天气", attempt: 1)
        #expect(fake.models.last == "qwen3.7-flash-2026-07-15")
    }

    @Test("T-040x F-15b row 157: picker quota 403 switches and skips the primary until restart; InvalidApiKey 403, 401, 500, timeout never switch")
    func row157() async throws {
        let (fake, fallback, clock, lines) = rig([(10, .http(403, quota403)), (10, .http(200, pickAnswer))])
        let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
        #expect(try await picker.pick(choices) == [1])
        #expect(fake.models == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        #expect(lines.all == ["qwen fallback route=picker from=qwen3.7-flash to=qwen3.8-flash reason=quota ok=yes ms=20"])
        clock.advance(by: .minutes(10))
        #expect(fallback.skipped(.picker) == .quota)
        #expect(try await picker.pick(choices) == [1])
        #expect(fake.models == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash", "qwen3.8-flash"])
        // A new process (restart) starts with the primary again.
        #expect(QwenFallback(clock: clock).skipped(.picker) == nil)

        for reply in [FakeQwen.Reply.http(403, #"{"code":"InvalidApiKey","message":"m"}"#), .http(401, "{}"), .http(500, "{}"),
                      .fail(.timedOut)] {
            let (fake, fallback, _, lines) = rig([(10, reply), (10, .http(200, pickAnswer))])
            let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
            await #expect(throws: (any Error).self) { try await picker.pick(choices) }
            #expect(fake.models == ["qwen3.7-flash-2026-07-15"])
            #expect(lines.all.isEmpty)
            #expect(fallback.skipped(.picker) == nil)
        }
    }

    @Test("T-040x F-15b row 158: an error after the answer started never switches; a backup that also 429s gets no second switch")
    func row158() async throws {
        let started = #"data:{"output":{"choices":[{"message":{"content":[{"text":"晴"}]}}]}}"# + "\n"
            + #"data:{"code":"Throttling.RateQuota","message":"m"}"#
        let (fake, fallback, _, lines) = rig([(10, .http(200, started))])
        let client = QwenWebSearchClient(key: { "k" }, send: fake.send, fallback: fallback)
        await #expect(throws: WebSearchError.api("Throttling.RateQuota")) { try await client.search("q", attempt: 1) }
        #expect(fake.models == ["qwen3.7-flash-2026-07-15"] && lines.all.isEmpty)

        let (twice, fallback2, _, lines2) = rig([(10, .http(429, throttled))])
        let live = QwenWebSearchClient(key: { "k" }, send: twice.send, fallback: fallback2)
        await #expect(throws: WebSearchError.http(429, code: "Throttling.RateQuota")) { try await live.search("q", attempt: 1) }
        #expect(twice.models == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        #expect(lines2.all == ["qwen fallback route=live from=qwen3.7-flash to=qwen3.8-flash reason=429 ok=no ms=20"])

        // ground: backup is qwen3.7-flash with turbo; its 429 falls back to the model's places (failed), one switch.
        let (g, fallback3, _, lines3) = rig([(10, .http(429, throttled))])
        let grounder = QwenTripGrounder(key: { "k" }, send: g.send, fallback: fallback3)
        let request = TripGroundRequest(city: "Tokyo, Japan", days: 1, places: [TripGroundPlace(name: "浅草寺", minutes: 60, importance: 3)],
                                        wishes: nil, start: nil, end: nil, hotelNear: nil)
        await #expect(throws: TripGroundError.failed) { try await grounder.ground(request) }
        #expect(g.models == ["qwen3.7-plus", "qwen3.7-flash-2026-07-15"])
        #expect(g.sent.withLock { $0.map(\.strategy) } == ["turbo", "turbo"])
        #expect(lines3.all == ["qwen fallback route=ground from=qwen3.7-plus to=qwen3.7-flash reason=429 ok=no ms=20"])
    }

    @Test("T-040x F-15b row 159: picker primary 429 at 2.0 s: the backup gets 0.5 s; at 2.5 s the failure path (高德's first result)")
    func row159() async throws {
        let (fake, fallback, _, lines) = rig([(2000, .http(429, throttled)), (500, .fail(.timedOut))])
        let picker = QwenPlacePicker(key: { "k" }, send: fake.send, fallback: fallback)
        await #expect(throws: (any Error).self) { try await picker.pick(choices) }
        let sent = fake.sent.withLock { $0 }
        #expect(sent.map(\.model) == ["qwen3.7-flash-2026-07-15", "qwen3.8-flash"])
        #expect(sent[1].timeout == 0.5)
        #expect(lines.all == ["qwen fallback route=picker from=qwen3.7-flash to=qwen3.8-flash reason=429 ok=no ms=2500"])

        // A 429 that arrives with no budget left: no backup call.
        let (late, fallback2, _, lines2) = rig([(2500, .http(429, throttled))])
        let p2 = QwenPlacePicker(key: { "k" }, send: late.send, fallback: fallback2)
        await #expect(throws: QwenPlacePicker.PickError.http(429)) { try await p2.pick(choices) }
        #expect(late.models == ["qwen3.7-flash-2026-07-15"])
        #expect(lines2.all == ["qwen fallback route=picker from=qwen3.7-flash to=qwen3.8-flash reason=429 ok=no ms=2500"])
    }
}
