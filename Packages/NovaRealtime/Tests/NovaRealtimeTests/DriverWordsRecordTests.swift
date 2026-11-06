import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaRealtime

@Suite("T-046l F-18 §23 item 5 the record keeps the driver's words")
struct DriverWordsRecordTests {
    @Test("F-18 §23 row 5: the item 5 message is the user content and in the §18 exchange body; model unchanged")
    func record() async throws {
        let message = "query: 横琴后天（2026年11月6日）天气\n\nquestion: 后天横琴天气怎么样\nanswer: "
        let seen = Mutex<[WebSearchExchange]>([])
        let client = QwenWebSearchClient(key: { TestKey.value }, send: { _ in (200, Data(WebSearchClientTests.stream.utf8)) },
                                         onExchange: { x in seen.withLock { $0.append(x) } })
        _ = try await client.search(message, attempt: 1)
        let x = try #require(seen.withLock { $0 }.first)
        let body = try JSONDecoder().decode(JSONValue.self, from: Data(x.requestBody.utf8))
        guard case .array(let messages)? = body["input"]?["messages"], messages.count == 4,
              case .array(let parts)? = messages[3]["content"], let first = parts.first else {
            Issue.record("unexpected body shape")
            return
        }
        #expect(first["text"] == .string(message))
        #expect(QwenWebSearchClient.model == "qwen3.7-flash")
    }
}
