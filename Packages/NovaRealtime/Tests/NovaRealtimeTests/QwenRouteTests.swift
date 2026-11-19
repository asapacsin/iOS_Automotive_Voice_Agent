import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

private let fixed = Date(timeIntervalSince1970: 1_794_000_000)
private let tokyoZone = TimeZone(identifier: "Asia/Tokyo")!
private let request = TripGroundRequest(city: "Tokyo, Japan", days: 3,
                                        places: [TripGroundPlace(name: "浅草寺", minutes: 60, importance: 3)],
                                        wishes: "酒店靠近新宿站", start: "成田机场", end: "成田机场", hotelNear: "新宿站 (Shinjuku Station)")

private func stream(_ answer: String, sources: Bool) -> Data {
    let escaped = String(decoding: try! JSONEncoder().encode(answer), as: UTF8.self)
    let results = sources ? #"[{"index":1,"title":"Senso-ji","url":"https://www.japan.travel/x"}]"# : "[]"
    return Data("""
    data:{"output":{"choices":[{"message":{"role":"assistant","content":[{"text":\(escaped)}]}}],"search_info":{"search_results":\(results)}}}

    """.utf8)
}

private func first(_ v: JSONValue?) -> JSONValue? {
    guard case .array(let a)? = v else { return nil }
    return a.first
}
private func text(_ m: JSONValue) -> JSONValue? { first(m["content"])?["text"] }

private let goodJSON = #"{"places":[{"name":"浅草寺","english":"Senso-ji","minutes":60,"importance":3}],"hotels":[{"night":1,"name":"新宿华盛顿酒店","english":"Shinjuku Washington Hotel"}],"area":"Tokyo"}"#

@Suite("T-040v F-15b §50 item 9 one Qwen model per job")
struct QwenRouteTests {
    @Test("T-040v F-15b row 154: QwenRoute table and bodies: ground is qwen3.7-plus, agent, forced, sources, thinking off, streamed, date turn")
    func row154() throws {
        #expect(QwenRoute.live.model == "qwen3.7-flash" && QwenRoute.live.search?.strategy == "turbo")
        #expect(QwenRoute.picker.model == "qwen3.7-flash" && QwenRoute.picker.search == nil && !QwenRoute.picker.stream)
        #expect(QwenRoute.ground.model == "qwen3.7-plus" && QwenRoute.ground.search?.strategy == "turbo")
        #expect(QwenRoute.ground.backupModel == "qwen3.7-flash" && QwenRoute.live.backupModel == "qwen3.8-flash")
        #expect(QwenWebSearchClient.model == QwenRoute.live.model)

        let grounder = QwenTripGrounder(key: { "k" }, send: { _ in (200, Data()) }, now: { fixed }, zone: { tokyoZone })
        let r = grounder.request(request, key: "k")
        #expect(r.url?.absoluteString == QwenRoute.endpoint && r.value(forHTTPHeaderField: "X-DashScope-SSE") == "enable")
        let body = try JSONDecoder().decode(JSONValue.self, from: r.httpBody ?? Data())
        #expect(body["model"] == "qwen3.7-plus")
        let p = body["parameters"]
        #expect(p?["enable_thinking"] == false && p?["enable_search"] == true && p?["incremental_output"] == true)
        #expect(p?["search_options"]?["search_strategy"] == "turbo" && p?["search_options"]?["forced_search"] == true
                && p?["search_options"]?["enable_source"] == true)
        #expect(p?["response_format"] == nil)
        guard case .array(let messages)? = body["input"]?["messages"] else { Issue.record("messages"); return }
        #expect(messages.count == 4)
        let system = text(messages[0])?.stringValue ?? ""
        #expect(system.hasPrefix("You are a helpful assistant. You need to extract the places") && system.contains("JSON"))
        #expect(text(messages[1]) == .string(QwenWebSearchClient.dateQuestion))
        #expect(text(messages[2]) == .string(QwenWebSearchClient.dateAnswer(now: fixed, zone: tokyoZone)))
        let input = try JSONDecoder().decode(JSONValue.self, from: Data((text(messages[3])?.stringValue ?? "").utf8))
        #expect(input["city"] == "Tokyo, Japan" && input["days"] == 3 && input["hotel_near"] == "新宿站 (Shinjuku Station)")
        #expect(first(input["places"])?["name"] == "浅草寺" && input["start"] == "成田机场")

        // No model name in any source file outside QwenRoute.swift.
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/NovaRealtime/Search")
        let files = try FileManager.default.contentsOfDirectory(atPath: sources.path).filter { $0.hasSuffix(".swift") && $0 != "QwenRoute.swift" }
        #expect(!files.isEmpty)
        for f in files {
            let text = try String(contentsOf: sources.appendingPathComponent(f), encoding: .utf8)
            let hasModelName = text.contains("qwen3")
            #expect(hasModelName == false, "\(f)")
        }
    }

    @Test("T-040v F-15b row 155: no search result → nosearch; a missing places field → json; a good answer parses")
    func row155() async throws {
        #expect(throws: TripGroundError.noSearch) { try QwenTripGrounder.answer(stream(goodJSON, sources: false)) }
        #expect(throws: TripGroundError.json) {
            try QwenTripGrounder.answer(stream(#"{"hotels":[],"area":"Tokyo"}"#, sources: true))
        }
        #expect(throws: TripGroundError.json) { try QwenTripGrounder.answer(stream("not json", sources: true)) }
        let a = try QwenTripGrounder.answer(stream("```json\n" + goodJSON + "\n```", sources: true))
        #expect(a.places.first?.english == "Senso-ji" && a.hotels.first?.night == 1 && a.area == "Tokyo")

        let sent = Mutex(0)
        let g = QwenTripGrounder(key: { "k" }, send: { _ in
            sent.withLock { $0 += 1 }
            return (200, stream(goodJSON, sources: false))
        })
        await #expect(throws: TripGroundError.noSearch) { try await g.ground(request) }
        let noKey = QwenTripGrounder(key: { nil }, send: { _ in (200, Data()) })
        await #expect(throws: TripGroundError.notConfigured) { try await noKey.ground(request) }
        let http = QwenTripGrounder(key: { "k" }, send: { _ in (500, Data()) })
        await #expect(throws: TripGroundError.failed) { try await http.ground(request) }
        #expect(sent.withLock { $0 } == 1)
    }
}
