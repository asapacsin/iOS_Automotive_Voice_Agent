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
    @Test("T-040zo F-15b §62 item 10: qwen3.8-flash on the compatible-mode endpoint, json_object, thinking off, system then the conversation; the answer is choices[0].message.content")
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
        #expect(req.url?.absoluteString == "https://dashscope-intl.aliyuncs.com/compatible-mode/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer k")
        let body = try JSONDecoder().decode(JSONValue.self, from: try #require(req.httpBody))
        #expect(body["model"] == "qwen3.8-flash" && client.model == "qwen3.8-flash")
        #expect(body["response_format"]?["type"] == "json_object" && body["enable_thinking"] == false && body["stream"] == false)
        #expect(body["messages"] == [["role": "system", "content": "S"], ["role": "user", "content": "U"], ["role": "assistant", "content": "A"]])
        #expect(body["enable_search"] == nil)
    }

    @Test("T-040zo F-15b §62 item 7: an HTTP error throws http(status); no key is notConfigured; no backup model is asked")
    func errors() async {
        let calls = Mutex(0)
        let failing = QwenTripPlannerClient(key: { "k" }, send: { _ in
            calls.withLock { $0 += 1 }
            return (429, Data("{}".utf8))
        })
        await #expect(throws: TripPlannerModelError.http(429)) { try await failing.complete(system: "S", messages: []) }
        #expect(calls.withLock { $0 } == 1)
        let none = QwenTripPlannerClient(key: { nil }, send: { _ in (200, Data()) })
        await #expect(throws: TripPlannerModelError.notConfigured) { try await none.complete(system: "S", messages: []) }
    }
}
