import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaRealtime

@Suite("T-040zo F-15b §62 item 10 the trip planner client")
struct TripPlannerClientTests {
    @Test("T-040zo F-15b §62 item 10 with F-18 §40: qwen3.8-max-0902 on the compatible-mode endpoint, json_object, thinking off, system then the conversation; the answer is choices[0].message.content")
    func request() async throws {
        let sent = Mutex<URLRequest?>(nil)
        let client = QwenTripPlannerClient(key: { "k" }, send: { req in
            sent.withLock { $0 = req }
            return (200, Data(#"{"choices":[{"message":{"role":"assistant","content":"{\"days\":[],\"done\":true}"}}],"usage":{"total_tokens":9}}"#.utf8))
        })
        let text = try await client.complete(system: "S", messages: [TripPlannerMessage(role: .user, content: "U"),
                                                                     TripPlannerMessage(role: .assistant, content: "A")])
        #expect(text == #"{"days":[],"done":true}"#)
        let req = try #require(sent.withLock { $0 })
        #expect(req.url?.absoluteString == "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
        #expect(body["model"] == "qwen3.8-max-0902" && client.model == "qwen3.8-max-0902")
        #expect(body["response_format"]?["type"] == "json_object" && body["enable_thinking"] == false && body["stream"] == false)
        #expect(body["messages"] == [["role": "system", "content": "S"], ["role": "user", "content": "U"], ["role": "assistant", "content": "A"]])
        #expect(body["enable_search"] == nil)
    }

    @Test("T-040zo F-15b §62 item 7 (with F-18 §40's planner list): a 429 on every model throws http(429) after each model once; no key is notConfigured")
    func errors() async {
        let calls = Mutex(0)
        let failing = QwenTripPlannerClient(key: { "k" }, send: { _ in
            calls.withLock { $0 += 1 }
            return (429, Data("{}".utf8))
        }, fallback: QwenFallback(clock: ManualClock()))
        await #expect(throws: TripPlannerModelError.http(429)) { try await failing.complete(system: "S", messages: []) }
        #expect(calls.withLock { $0 } == QwenRoute.planner.chain.count)
        let none = QwenTripPlannerClient(key: { nil }, send: { _ in (200, Data()) })
        await #expect(throws: TripPlannerModelError.notConfigured) { try await none.complete(system: "S", messages: []) }
    }
}
