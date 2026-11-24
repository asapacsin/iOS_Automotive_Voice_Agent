import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §39 item 2 (T-046zb): one events keyword query on the app's search route (`QwenRoute.eventsSearch`: `max`,
/// forced, sources, thinking off), the query as the only user message and **no system text**. Kept: the search's own
/// answer text, `search_info.search_results` (title, url, site) and `usage.total_tokens`. A 429 or a quota 403 moves the
/// query to the next model of the chain (§36, `QwenFallback`). Queries, checks and store are NovaCore's
/// (`EventSearchRun`).
public struct QwenEventSearcher: EventWebSearcher {
    public typealias Send = QwenWebSearchClient.Send
    private let key: @Sendable () -> String?
    private let send: Send
    private let fallback: QwenFallback
    public let route: QwenRoute

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                route: QwenRoute = .eventsSearch, fallback: QwenFallback = .shared) {
        self.key = key
        self.send = send
        self.route = route
        self.fallback = fallback
    }

    public func request(_ query: String, key: String, route: QwenRoute? = nil) -> URLRequest {
        let route = route ?? self.route
        var request = URLRequest(url: URL(string: QwenRoute.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if route.stream { request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE") }
        let body: JSONValue = [
            "model": .string(route.model),
            "input": ["messages": [["role": "user", "content": [["text": .string(query)]]]]],
            "parameters": route.parameters(),
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let (status, body) = try await fallback.run(route, request: query) { r, left in
            var req = request(query, key: key, route: r)
            req.limit(left ?? timeout)
            return try await send(req)
        }
        guard status == 200 else { throw WebSearchError.http(status, code: QwenWebSearchClient.errorCode(body)) }
        let parsed = QwenWebSearchClient.parse(body)
        if let code = parsed.code { throw WebSearchError.api(code) }
        return EventSearchAnswer(text: parsed.reply.answer, sources: Self.hits(body), tokens: Self.tokens(body))
    }

    /// The last non-empty `output.search_info.search_results`.
    public static func hits(_ body: Data) -> [EventSearchHit] {
        var results: [JSONValue] = []
        for o in QwenWebSearchClient.objects(body) {
            if case .array(let r)? = o["output"]?["search_info"]?["search_results"], !r.isEmpty { results = r }
        }
        return results.compactMap { r in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return EventSearchHit(title: r["title"]?.stringValue ?? "", url: url,
                                  site: r["site_name"]?.stringValue ?? URL(string: url)?.host ?? "")
        }
    }

    /// `usage.total_tokens` of the last chunk that has it (else input + output tokens).
    public static func tokens(_ body: Data) -> Int? {
        var n: Int?
        for o in QwenWebSearchClient.objects(body) {
            guard let u = o["usage"] else { continue }
            if case .int(let t)? = u["total_tokens"] {
                n = Int(t)
            } else if case .int(let i)? = u["input_tokens"], case .int(let out)? = u["output_tokens"] {
                n = Int(i + out)
            }
        }
        return n
    }
}

/// F-18 §39 item 3 (T-046zb): the one extraction call. `QwenRoute.eventsExtract` on the compatible-mode chat endpoint,
/// `response_format: json_object`, thinking off, not streamed; the system text and the user message are NovaCore's
/// (`EventSearchRun.system`, `.user`). Returns the content and `usage.total_tokens`.
public struct QwenEventExtractor: EventExtractor {
    public typealias Send = QwenWebSearchClient.Send
    private let key: @Sendable () -> String?
    private let send: Send
    private let fallback: QwenFallback
    public let route: QwenRoute

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                route: QwenRoute = .eventsExtract, fallback: QwenFallback = .shared) {
        self.key = key
        self.send = send
        self.route = route
        self.fallback = fallback
    }

    public func request(system: String, user: String, key: String, route: QwenRoute? = nil) -> URLRequest {
        let route = route ?? self.route
        var request = URLRequest(url: URL(string: QwenRoute.plannerEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "model": .string(route.model),
            "messages": [["role": "system", "content": .string(system)], ["role": "user", "content": .string(user)]],
            "response_format": ["type": "json_object"],
            "enable_thinking": .bool(route.thinking),
            "stream": false,
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let (status, body) = try await fallback.run(route, request: system + "\n" + user) { r, left in
            var req = request(system: system, user: user, key: key, route: r)
            req.limit(left ?? timeout)
            return try await send(req)
        }
        guard status == 200 else { throw WebSearchError.http(status, code: QwenWebSearchClient.errorCode(body)) }
        return EventModelReply(content: QwenTripPlannerClient.content(body) ?? "", tokens: QwenEventSearcher.tokens(body))
    }
}
