import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §35 items 3, 10 (T-046x): the browse loop's model. `QwenRoute.eventsLoop` on the compatible-mode chat
/// endpoint with the loop's two tools, streamed and read to the end; a 429 or a quota 403 moves the turn to the next
/// model of the chain (§36, `QwenFallback`). The loop, its texts and the date check are in NovaCore
/// (`EventBrowseLoop`); this only sends one turn and returns the text, the tool calls and `usage.total_tokens`.
public struct QwenEventChatClient: EventChatModel {
    public typealias Send = QwenWebSearchClient.Send

    public let route: QwenRoute
    private let key: @Sendable () -> String?
    private let send: Send
    private let fallback: QwenFallback
    private let tools: JSONValue

    public init(key: @escaping @Sendable () -> String?, tools: JSONValue, send: @escaping Send = QwenWebSearchClient.urlSession,
                route: QwenRoute = .eventsLoop, fallback: QwenFallback = .shared) {
        self.key = key
        self.tools = tools
        self.send = send
        self.route = route
        self.fallback = fallback
    }

    public func request(_ messages: [EventChatMessage], lastStep: Bool, key: String, route: QwenRoute? = nil,
                        timeout: NovaDuration) -> URLRequest {
        let route = route ?? self.route
        var request = URLRequest(url: URL(string: QwenRoute.plannerEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = max(1, Double(timeout.milliseconds) / 1000)
        var body: [String: JSONValue] = [
            "model": .string(route.model),
            "messages": .array(messages.map(Self.json)),
            "enable_thinking": .bool(route.thinking),
            "tools": tools,
        ]
        // F-18 §38 item 5: the PoC's call is not streamed (no `stream` field); a streamed route still can be.
        if route.stream {
            body["stream"] = true
            body["stream_options"] = ["include_usage": true]
        }
        // §38 item 6: the last step keeps the tools but the model must answer.
        if lastStep { body["tool_choice"] = "none" }
        request.httpBody = try? JSONValue.canonicalEncoder().encode(JSONValue.object(body))
        return request
    }

    static func json(_ m: EventChatMessage) -> JSONValue {
        var o: [String: JSONValue] = ["role": .string(m.role.rawValue), "content": .string(m.content)]
        if !m.toolCalls.isEmpty {
            o["tool_calls"] = .array(m.toolCalls.map {
                ["id": .string($0.id), "type": "function", "function": ["name": .string($0.name), "arguments": .string($0.arguments)]]
            })
        }
        if let id = m.toolCallID { o["tool_call_id"] = .string(id) }
        return .object(o)
    }

    public func turn(_ messages: [EventChatMessage], lastStep: Bool, timeout: NovaDuration) async throws -> EventChatReply {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let text = messages.map(\.content).joined(separator: "\n")
        let (status, body) = try await fallback.run(route, request: text) { route, left in
            try await send(request(messages, lastStep: lastStep, key: key, route: route, timeout: left ?? timeout))
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return Self.parse(body)
    }

    /// A chat completion, whole or streamed (`data:` lines): `content` joined, `tool_calls` assembled by `index`
    /// (`reasoning_content` left out), `usage.total_tokens` from the last chunk that has it.
    public static func parse(_ body: Data) -> EventChatReply {
        var content = ""
        var calls: [Int: (id: String, name: String, args: String)] = [:]
        var tokens: Int?
        for o in QwenWebSearchClient.objects(body) {
            if let t = o["usage"]?["total_tokens"], case .int(let n) = t { tokens = Int(n) }
            guard case .array(let choices)? = o["choices"], let first = choices.first else { continue }
            let m = first["delta"] ?? first["message"]
            content += m?["content"]?.stringValue ?? ""
            if case .array(let tc)? = m?["tool_calls"] {
                for (n, c) in tc.enumerated() {
                    var i = n
                    if case .int(let v)? = c["index"] { i = Int(v) }
                    var cur = calls[i] ?? ("", "", "")
                    if let id = c["id"]?.stringValue, !id.isEmpty { cur.id = id }
                    if let name = c["function"]?["name"]?.stringValue, !name.isEmpty { cur.name = name }
                    cur.args += c["function"]?["arguments"]?.stringValue ?? ""
                    calls[i] = cur
                }
            }
        }
        let list = calls.keys.sorted().map { i -> EventToolCall in
            let c = calls[i]!
            return EventToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, name: c.name, arguments: c.args)
        }
        return EventChatReply(content: content, toolCalls: list, tokens: tokens)
    }
}

/// F-18 §35 item 3: the loop's `search(query)`: the app's search route (`QwenRoute.eventsSearch`, `max`, forced,
/// sources) returning title, url and site of up to 10 results; the answer text is not returned.
public struct QwenEventSearcher: EventSearcher {
    private let client: QwenWebSearchClient

    public init(key: @escaping @Sendable () -> String?, send: @escaping QwenWebSearchClient.Send = QwenWebSearchClient.urlSession) {
        client = QwenWebSearchClient(key: key, send: send)
    }

    public func search(_ query: String) async throws -> [EventSearchHit] {
        guard let key = client.keyValue(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let route = QwenRoute.eventsSearch
        let (status, body) = try await QwenFallback.shared.run(route, request: query) { r, timeout in
            var req = client.request(query, key: key, route: r)
            req.limit(timeout)
            return try await client.sender(req)
        }
        guard status == 200 else { throw URLError(.badServerResponse) }
        return Self.hits(body)
    }

    /// The last non-empty `output.search_info.search_results`, up to 10.
    public static func hits(_ body: Data) -> [EventSearchHit] {
        var results: [JSONValue] = []
        for o in QwenWebSearchClient.objects(body) {
            if case .array(let r)? = o["output"]?["search_info"]?["search_results"], !r.isEmpty { results = r }
        }
        return results.prefix(10).compactMap { r in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return EventSearchHit(title: r["title"]?.stringValue ?? "", url: url,
                                  site: r["site_name"]?.stringValue ?? URL(string: url)?.host ?? "")
        }
    }
}

/// F-18 §35 item 3: `open_page(url)`: 20 s, at most 2 MB, a desktop browser user agent, `zh-CN`; http(s) only.
public struct EventPageClient: EventPageFetcher {
    public static let timeout: TimeInterval = 20
    public static let maxBytes = 2 * 1024 * 1024
    public static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    private let send: QwenWebSearchClient.Send

    public init(send: @escaping QwenWebSearchClient.Send = QwenWebSearchClient.urlSession) { self.send = send }

    public static func request(_ url: String) -> URLRequest? {
        guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        var r = URLRequest(url: u)
        r.timeoutInterval = timeout
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        return r
    }

    public func open(_ url: String) async throws -> String {
        guard let req = Self.request(url) else { throw URLError(.unsupportedURL) }
        let (status, body) = try await send(req)
        guard (200..<300).contains(status) else { throw URLError(.badServerResponse) }
        return String(decoding: body.prefix(Self.maxBytes), as: UTF8.self)
    }
}
