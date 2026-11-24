import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaRealtime

@Suite("T-046x F-18 §35 item 3 events loop clients")
struct QwenEventClientsTests {
    @Test("T-046za F-18 §38 item 5: a whole (non-streamed) turn gives its tool calls and usage")
    func wholeToolCalls() {
        let body = #"{"choices":[{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_b","type":"function","function":{"name":"open_page","arguments":"{\"url\":\"https://a.example/x\"}"}}]}}],"usage":{"total_tokens":77}}"#
        let r = QwenEventChatClient.parse(Data(body.utf8))
        #expect(r.tokens == 77)
        #expect(r.toolCalls == [EventToolCall(id: "call_b", name: "open_page", arguments: #"{"url":"https://a.example/x"}"#)])
    }

    @Test("T-046x F-18 §35 item 3: a streamed turn assembles tool calls by index and reads usage")
    func streamedToolCalls() {
        let body = """
        data: {"choices":[{"delta":{"reasoning_content":"想一想"}}]}
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_a","function":{"name":"search","arguments":"{\\"query\\":"}}]}}]}
        data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"珠海 活动\\"}"}}]}}]}
        data: {"choices":[],"usage":{"total_tokens":1234}}
        data: [DONE]
        """
        let r = QwenEventChatClient.parse(Data(body.utf8))
        #expect(r.content.isEmpty && r.tokens == 1234)
        #expect(r.toolCalls == [EventToolCall(id: "call_a", name: "search", arguments: #"{"query":"珠海 活动"}"#)])
    }

    @Test("T-046za F-18 §38 row 45 (replaces §35 item 3's request): qwen3.8-max, thinking off, no stream, the tools on every turn; the last step adds tool_choice none")
    func request() throws {
        let c = QwenEventChatClient(key: { "k" }, tools: ["x"])
        let msgs = [EventChatMessage(role: .assistant, content: "", toolCalls: [EventToolCall(id: "1", name: "open_page", arguments: "{}")]),
                    EventChatMessage(role: .tool, content: "page", toolCallID: "1")]
        let req = c.request(msgs, lastStep: false, key: "k", timeout: .seconds(100))
        let body = try JSONDecoder().decode(JSONValue.self, from: req.httpBody!)
        #expect(body["model"] == "qwen3.8-max" && body["enable_thinking"] == false && body["tools"] == ["x"])
        #expect(body["stream"] == nil && body["stream_options"] == nil && body["tool_choice"] == nil)
        guard case .array(let m)? = body["messages"] else { Issue.record("no messages"); return }
        #expect(m[1]["tool_call_id"] == "1" && m[0]["tool_calls"] != nil)
        let last = try JSONDecoder().decode(JSONValue.self, from: c.request(msgs, lastStep: true, key: "k", timeout: .seconds(5)).httpBody!)
        #expect(last["tools"] == ["x"] && last["tool_choice"] == "none")
    }

    @Test("T-046x F-18 §35 item 3: search returns links only; open_page asks zh-CN with a desktop agent, http(s) only")
    func searchAndPage() {
        let body = #"data: {"output":{"choices":[{"message":{"content":"答案"}}],"search_info":{"search_results":[{"title":"AI嘉年华","url":"https://zh.bendibao.com/a.shtm","site_name":"珠海本地宝"}]}}}"#
        #expect(QwenEventSearcher.hits(Data(body.utf8)) == [EventSearchHit(title: "AI嘉年华", url: "https://zh.bendibao.com/a.shtm", site: "珠海本地宝")])
        let r = EventPageClient.request("https://zh.bendibao.com/a.shtm")
        #expect(r?.value(forHTTPHeaderField: "Accept-Language")?.hasPrefix("zh-CN") == true && r?.timeoutInterval == 20)
        #expect(EventPageClient.request("file:///etc/passwd") == nil)
    }
}
