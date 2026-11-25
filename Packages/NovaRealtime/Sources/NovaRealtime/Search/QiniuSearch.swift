import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §42 (T-046ze, owner order 2026-11-25): the 七牛云 (Qiniu) web search API returns plain results (no model
/// tokens); a model on Qiniu's chat completions reads them. With no 七牛云 key every search job stays on §41
/// (`QwenWebSearchClient`, `QwenTripGrounder`, `QwenEventSearcher`) unchanged; a failed Qiniu model call falls back to
/// the same job on §41 with the 千问 key (item 3). The key goes in the `Authorization` header only, never in logs.
public enum QiniuRoute {
    /// §42 item 2.
    public static let searchEndpoint = "https://api.qnaigc.com/v1/search/web"
    /// §42 item 3.
    public static let chatEndpoint = "https://api.qnaigc.com/v1/chat/completions"
    public static let model = "deepseek/deepseek-v4-flash-20260731"
    public static let maxResults = 20
    public static let searchTimeout = NovaDuration.seconds(15)
    /// §42 item 5: the results that go into FreshPrompt's evidence block.
    public static let evidenceCount = 10
}

/// §42 item 2: one kept result.
public struct QiniuResult: Sendable, Hashable {
    public let title, url, content, date, source: String
    public init(title: String, url: String, content: String, date: String, source: String) {
        self.title = title
        self.url = url
        self.content = content
        self.date = date
        self.source = source
    }
}

/// §42 item 2: a failed search (non-200, `success: false`, timeout, network). A 429 is `rate_limit`, never retried.
public struct QiniuFailure: Error, Sendable, Hashable {
    public let reason: String
    public let status: Int?
    public init(reason: String, status: Int? = nil) {
        self.reason = reason
        self.status = status
    }
}

/// §42 item 6: a model answer with its tokens (prompt, completion, reasoning).
public struct QiniuChatReply: Sendable, Hashable {
    public let content: String
    public let prompt, completion, reasoning: Int?
    public var total: Int? {
        guard prompt != nil || completion != nil else { return nil }
        return (prompt ?? 0) + (completion ?? 0)
    }
    public var tokensText: String { "\(prompt ?? 0),\(completion ?? 0),\(reasoning ?? 0)" }
}

/// §42 items 2-3: the two Qiniu calls.
public struct QiniuClient: Sendable {
    public typealias Send = QwenWebSearchClient.Send
    private let send: Send

    public init(send: @escaping Send = QwenWebSearchClient.urlSession) { self.send = send }

    public static func searchRequest(_ query: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: QiniuRoute.searchEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = ["query": .string(query), "max_results": .int(Int64(QiniuRoute.maxResults)), "search_type": "web"]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        request.limit(QiniuRoute.searchTimeout)
        return request
    }

    public static func chatRequest(_ messages: [(role: String, text: String)], key: String, json: Bool,
                                   timeout: NovaDuration?) -> URLRequest {
        var request = URLRequest(url: URL(string: QiniuRoute.chatEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: JSONValue] = [
            "model": .string(QiniuRoute.model),
            "messages": .array(messages.map { ["role": .string($0.role), "content": .string($0.text)] }),
            "stream": false,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try? JSONValue.canonicalEncoder().encode(JSONValue.object(body))
        request.limit(timeout)
        return request
    }

    /// §42 item 2: the results, or `QiniuFailure`.
    public func search(_ query: String, key: String) async throws(QiniuFailure) -> [QiniuResult] {
        let status: Int, body: Data
        do {
            (status, body) = try await send(Self.searchRequest(query, key: key))
        } catch {
            if (error as? URLError)?.code == .timedOut { throw QiniuFailure(reason: "timeout") }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw QiniuFailure(reason: "cancelled") }
            throw QiniuFailure(reason: "network")
        }
        if status == 429 { throw QiniuFailure(reason: "rate_limit", status: 429) }
        guard status == 200 else { throw QiniuFailure(reason: "http", status: status) }
        guard let results = Self.results(body) else { throw QiniuFailure(reason: "unsuccessful", status: status) }
        return results
    }

    /// `data.results[]` of a `success: true` body; nil otherwise.
    public static func results(_ body: Data) -> [QiniuResult]? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: body), v["success"] == true,
              case .array(let raw)? = v["data"]?["results"] else { return nil }
        return raw.compactMap { r in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return QiniuResult(title: r["title"]?.stringValue ?? "", url: url, content: r["content"]?.stringValue ?? "",
                               date: r["date"]?.stringValue ?? "", source: r["source"]?.stringValue ?? "")
        }
    }

    /// §42 item 3: one chat call; a non-200 or an empty answer throws `QiniuFailure`.
    public func chat(_ messages: [(role: String, text: String)], key: String, json: Bool = false,
                     timeout: NovaDuration?) async throws(QiniuFailure) -> QiniuChatReply {
        let status: Int, body: Data
        do {
            (status, body) = try await send(Self.chatRequest(messages, key: key, json: json, timeout: timeout))
        } catch {
            if (error as? URLError)?.code == .timedOut { throw QiniuFailure(reason: "timeout") }
            throw QiniuFailure(reason: "network")
        }
        if status == 429 { throw QiniuFailure(reason: "rate_limit", status: 429) }
        guard status == 200, let reply = Self.reply(body) else { throw QiniuFailure(reason: "http", status: status) }
        return reply
    }

    /// `choices[0].message.content` and `usage` (`prompt_tokens`, `completion_tokens`,
    /// `completion_tokens_details.reasoning_tokens`).
    public static func reply(_ body: Data) -> QiniuChatReply? {
        guard let content = QwenTripPlannerClient.content(body), !content.isEmpty else { return nil }
        let u = (try? JSONDecoder().decode(JSONValue.self, from: body))?["usage"]
        func n(_ v: JSONValue?) -> Int? { v?.intValue.map(Int.init) }
        return QiniuChatReply(content: content, prompt: n(u?["prompt_tokens"]), completion: n(u?["completion_tokens"]),
                              reasoning: n(u?["completion_tokens_details"]?["reasoning_tokens"]))
    }

    /// §42 item 6: the search record line.
    static func searchLine(_ job: String, ms: Int64, results: Int?, failure: QiniuFailure?) -> String {
        var s = "search provider=qiniu job=\(job) ms=\(ms) results=\(results ?? 0)"
        if let failure {
            s += " failed=yes reason=\(failure.reason)"
            if let status = failure.status { s += " status=\(status)" }
        } else {
            s += " failed=no"
        }
        return s
    }

    /// §42 item 6: the model record line.
    static func modelLine(_ job: String, ms: Int64, reply: QiniuChatReply?, failure: QiniuFailure?) -> String {
        var s = "model provider=qiniu job=\(job) model=\(QiniuRoute.model) ms=\(ms) tokens=\(reply?.tokensText ?? "0,0,0")"
        if let failure { s += " failed=yes reason=\(failure.reason)" + (failure.status.map { " status=\($0)" } ?? "") }
        return s
    }
}

// MARK: FreshPrompt evidence (§42 item 5)

public enum FreshPromptEvidence {
    /// §42 item 5: the top results as FreshPrompt's evidence rows, oldest date first (dates that do not parse first, as
    /// the notebook's `sort_values(na_position='first')`), each
    /// `\n\nsource: …\ndate: …\ntitle: …\nsnippet: …\nhighlight: …` (`snippet` = `content`, `highlight` empty), copied from
    /// freshprompt.ipynb `freshprompt_format` (github.com/freshllms/freshqa, read 2026-11-25).
    public static func block(_ results: [QiniuResult]) -> String {
        let top = Array(results.prefix(QiniuRoute.evidenceCount))
        let sorted = top.enumerated().sorted { a, b in
            let da = day(a.element.date), db = day(b.element.date)
            switch (da, db) {
            case (nil, nil): return a.offset < b.offset
            case (nil, _): return true
            case (_, nil): return false
            case let (x?, y?): return x == y ? a.offset < b.offset : x < y
            }
        }.map(\.element)
        return sorted.map { r in
            "\n\nsource: \(source(r.url))\ndate: \(displayDate(r.date))\ntitle: \(r.title)\nsnippet: \(r.content)\nhighlight: "
        }.joined()
    }

    /// The notebook's `extract_source_webpage`: the link's domain without `www.`.
    static func source(_ url: String) -> String {
        let host = URL(string: url)?.host ?? ""
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The notebook's `format_date`: `Nov 17, 2026`; a date that does not parse stays as given.
    static func displayDate(_ text: String) -> String {
        guard let d = day(text) else { return text }
        let p = d.split(separator: "-").compactMap { Int($0) }
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard p.count == 3, (1...12).contains(p[1]) else { return text }
        return "\(months[p[1] - 1]) \(p[2] < 10 ? "0" : "")\(p[2]), \(p[0])"
    }

    /// Her query in the user message the executor builds: `query: Q\n\nquestion: …\nanswer: ` (driver words) or
    /// `question: Q\nanswer: `; any other text is the query itself.
    public static func query(_ text: String) -> String {
        if text.hasPrefix("query: "), let r = text.range(of: "\n\nquestion: ") {
            return String(text[text.index(text.startIndex, offsetBy: 7)..<r.lowerBound])
        }
        if text.hasPrefix("question: ") {
            var q = String(text.dropFirst(10))
            if q.hasSuffix("\nanswer: ") { q = String(q.dropLast(9)) }
            return q
        }
        return text
    }

    /// `YYYY-MM-DD` (or `YYYY-MM-DD hh:mm…`, `YYYY/MM/DD`) as a comparable string; nil when it does not parse.
    static func day(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        guard t.count >= 10 else { return nil }
        let d = String(t.prefix(10))
        let parts = d.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts.allSatisfy({ Int($0) != nil }) else { return nil }
        return d
    }

    /// The user message with the evidence inserted before its `\n\nquestion: ` (FreshPrompt's layout: query, evidence,
    /// question). A message without that marker gets FreshPrompt's own frame around it.
    public static func message(_ text: String, results: [QiniuResult]) -> String {
        let evidence = block(results)
        if text.hasPrefix("query: "), let r = text.range(of: "\n\nquestion: ") {
            return String(text[..<r.lowerBound]) + evidence + String(text[r.lowerBound...])
        }
        if text.hasPrefix("question: ") {
            return "query: \(query(text))" + evidence + "\n\n" + text
        }
        return "query: \(text)" + evidence + "\n\nquestion: \(text)\nanswer: "
    }
}

// MARK: Jobs

/// §42 item 4: one events query on Qiniu search. A failed search (429 included) throws and is counted failed; it is
/// never retried and does not fall back (row 71).
public struct QiniuEventSearcher: EventWebSearcher {
    private let key: @Sendable () -> String?
    private let client: QiniuClient
    private let onLine: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    public init(key: @escaping @Sendable () -> String?, client: QiniuClient = QiniuClient(),
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key
        self.client = client
        self.onLine = onLine
    }

    public func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let t0 = clock.now
        do {
            let results = try await client.search(query, key: key)
            onLine(QiniuClient.searchLine("events", ms: elapsed(t0), results: results.count, failure: nil))
            let hits = results.map {
                EventSearchHit(title: $0.title, url: $0.url, site: $0.source.isEmpty ? (URL(string: $0.url)?.host ?? "") : $0.source,
                               snippet: $0.content, date: $0.date)
            }
            // The titles and snippets stand in for the search's answer text (§39 item 4's naming-query rule).
            let text = results.map { $0.title + " " + $0.content }.joined(separator: "\n")
            return EventSearchAnswer(text: text, sources: hits, tokens: 0, searches: 1)
        } catch {
            onLine(QiniuClient.searchLine("events", ms: elapsed(t0), results: nil, failure: error))
            throw error
        }
    }


}

/// §42 items 3-4: the extraction on Qiniu's model; a failed call falls back to `fallback` (§41's extractor, 千问 key).
public struct QiniuEventExtractor: EventExtractor {
    private let key: @Sendable () -> String?
    private let client: QiniuClient
    private let fallback: any EventExtractor
    private let onLine: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    public init(key: @escaping @Sendable () -> String?, fallback: any EventExtractor, client: QiniuClient = QiniuClient(),
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key
        self.client = client
        self.fallback = fallback
        self.onLine = onLine
    }

    public func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        guard let key = key(), !key.isEmpty else { return try await fallback.extract(system: system, user: user, timeout: timeout) }
        let t0 = clock.now
        do {
            let reply = try await client.chat([("system", system), ("user", user)], key: key, json: true, timeout: timeout)
            onLine(QiniuClient.modelLine("events_extract", ms: elapsed(t0), reply: reply, failure: nil))
            return EventModelReply(content: reply.content, tokens: reply.total)
        } catch {
            onLine(QiniuClient.modelLine("events_extract", ms: elapsed(t0), reply: nil, failure: error)
                   + " fallback=qwen")
            return try await fallback.extract(system: system, user: user, timeout: timeout)
        }
    }
}

/// §42 item 5 (`live`): one Qiniu search with her query, then Qiniu's model with FreshPrompt's messages (§24 item 2)
/// and the top 10 results as the evidence block. No 七牛云 key, a failed search or a failed model call: `fallback`
/// (§41's `QwenWebSearchClient`) answers.
public struct QiniuWebSearchClient: WebSearchService {
    private let key: @Sendable () -> String?
    private let client: QiniuClient
    private let fallback: any WebSearchService
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private let onLine: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    public init(key: @escaping @Sendable () -> String?, fallback: any WebSearchService, client: QiniuClient = QiniuClient(),
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key
        self.client = client
        self.fallback = fallback
        self.now = now
        self.zone = zone
        self.onLine = onLine
    }

    /// FreshPrompt's four messages (§24 item 2), the question carrying the evidence block.
    public func messages(_ query: String, results: [QiniuResult]) -> [(role: String, text: String)] {
        let date = now(), zone = zone()
        return [
            ("system", QwenWebSearchClient.instruction(now: date, zone: zone)),
            ("user", QwenWebSearchClient.dateQuestion),
            ("assistant", QwenWebSearchClient.dateAnswer(now: date, zone: zone)),
            ("user", FreshPromptEvidence.message(query, results: results)),
        ]
    }

    public func search(_ query: String, attempt: Int) async throws -> WebSearchReply {
        guard let key = key(), !key.isEmpty else { return try await fallback.search(query, attempt: attempt) }
        let t0 = clock.now
        let results: [QiniuResult]
        do {
            // §42 item 5: the search gets her query (§19/§21 rewrites), not the FreshPrompt message around it.
            results = try await client.search(FreshPromptEvidence.query(query), key: key)
            onLine(QiniuClient.searchLine("live", ms: elapsed(t0), results: results.count, failure: nil))
        } catch {
            onLine(QiniuClient.searchLine("live", ms: elapsed(t0), results: nil, failure: error) + " fallback=qwen")
            return try await fallback.search(query, attempt: attempt)
        }
        // "The search ran" = at least one result; none: §41 answers.
        guard !results.isEmpty else {
            onLine("search provider=qiniu job=live no_results=yes fallback=qwen")
            return try await fallback.search(query, attempt: attempt)
        }
        let t1 = clock.now
        do {
            let reply = try await client.chat(messages(query, results: results), key: key, timeout: nil)
            onLine(QiniuClient.modelLine("live", ms: elapsed(t1), reply: reply, failure: nil))
            // "The search ran" = at least one result; the sources are the evidence rows.
            let sources = results.prefix(QiniuRoute.evidenceCount).map {
                WebSearchSource(title: $0.title, host: URL(string: $0.url)?.host ?? "")
            }
            return WebSearchReply(answer: reply.content.trimmingCharacters(in: .whitespacesAndNewlines), sources: Array(sources))
        } catch {
            onLine(QiniuClient.modelLine("live", ms: elapsed(t1), reply: nil, failure: error) + " fallback=qwen")
            return try await fallback.search(query, attempt: attempt)
        }
    }
}

/// §42 item 5 (`ground`): one Qiniu search with the trip input, then Qiniu's model with `QwenTripGrounder`'s messages
/// and the evidence block. Grounded only with at least one result. No key or a failed call: `fallback` (§41).
public struct QiniuTripGrounder: TripGrounder {
    private let key: @Sendable () -> String?
    private let client: QiniuClient
    private let fallback: any TripGrounder
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private let onLine: @Sendable (String) -> Void
    private let clock = ContinuousClock()

    public init(key: @escaping @Sendable () -> String?, fallback: any TripGrounder, client: QiniuClient = QiniuClient(),
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key
        self.client = client
        self.fallback = fallback
        self.now = now
        self.zone = zone
        self.onLine = onLine
    }

    /// The search query: the city and the places named (the input's values, no instruction text).
    public static func query(_ r: TripGroundRequest) -> String {
        ([r.city] + r.places.map(\.name)).joined(separator: " ")
    }

    public func messages(_ r: TripGroundRequest, results: [QiniuResult]) -> [(role: String, text: String)] {
        let date = now(), zone = zone()
        return [
            ("system", QwenTripGrounder.searchSystem + " " + QwenTripGrounder.jsonSystem),
            ("user", QwenWebSearchClient.dateQuestion),
            ("assistant", QwenWebSearchClient.dateAnswer(now: date, zone: zone)),
            ("user", FreshPromptEvidence.message(QwenTripGrounder.input(r), results: results)),
        ]
    }

    public func ground(_ r: TripGroundRequest) async throws -> TripGroundAnswer {
        guard let key = key(), !key.isEmpty else { return try await fallback.ground(r) }
        let t0 = clock.now
        let results: [QiniuResult]
        do {
            results = try await client.search(Self.query(r), key: key)
            onLine(QiniuClient.searchLine("ground", ms: elapsed(t0), results: results.count, failure: nil))
        } catch {
            onLine(QiniuClient.searchLine("ground", ms: elapsed(t0), results: nil, failure: error) + " fallback=qwen")
            return try await fallback.ground(r)
        }
        guard !results.isEmpty else { throw TripGroundError.noSearch }
        let t1 = clock.now
        let reply: QiniuChatReply
        do {
            reply = try await client.chat(messages(r, results: results), key: key, timeout: QwenRoute.ground.budget)
            onLine(QiniuClient.modelLine("ground", ms: elapsed(t1), reply: reply, failure: nil))
        } catch {
            onLine(QiniuClient.modelLine("ground", ms: elapsed(t1), reply: nil, failure: error) + " fallback=qwen")
            return try await fallback.ground(r)
        }
        return try QwenTripGrounder.fields(reply.content)
    }
}

/// Milliseconds since `t0` on the continuous clock.
func elapsed(_ t0: ContinuousClock.Instant) -> Int64 {
    let d = ContinuousClock.now - t0
    return d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000
}
