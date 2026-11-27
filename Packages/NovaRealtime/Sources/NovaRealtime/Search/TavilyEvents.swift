import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §46 items 1-5 (T-046zi, owner order 2026-11-26): Tavily search and Extract with the 设置 「Tavily key」
/// (Keychain `tavily_api_key`, `Authorization: Bearer`, never logged) and the picture download. Replaces the Qiniu
/// clients (§42-§45 withdrawn).
public enum TavilyRoute {
    public static let searchEndpoint = "https://api.tavily.com/search"
    public static let extractEndpoint = "https://api.tavily.com/extract"
    /// Item 2: 20 results, 30 s; item 5's picture search: 5 results.
    public static let maxResults = 20
    public static let imageResults = 5
    public static let searchTimeout = NovaDuration.seconds(30)
    /// Item 4.
    public static let extractTimeout = NovaDuration.seconds(60)
    /// Item 5.
    public static let downloadTimeout = NovaDuration.seconds(15)
    /// Item 2 with §43 item 1: the waits before the second and the third try.
    public static let retryDelays: [NovaDuration] = [.seconds(1), .seconds(3)]
}

public struct TavilyFailure: Error, Sendable, Hashable {
    public let reason: String
    public let status: Int?
    public init(reason: String, status: Int? = nil) {
        self.reason = reason
        self.status = status
    }

    /// §43 item 1: a network error, a timeout, 5xx and 429 are tried again; any other 4xx and a cancelled call are not.
    public var retryable: Bool {
        switch reason {
        case "network", "timeout": true
        case "http": (status ?? 0) == 429 || (status ?? 0) >= 500
        default: false
        }
    }
}

public struct TavilyClient: EventWebSource {
    public typealias Send = QwenWebSearchClient.Send
    public typealias Sleep = @Sendable (NovaDuration) async throws -> Void
    private let key: @Sendable () -> String?
    private let send: Send
    private let sleep: Sleep
    /// Item 2: §41's searcher (千问 key) for a query whose Tavily tries all failed; nil: none.
    private let fallback: (any EventWebSearcher)?
    private let onLine: @Sendable (String) -> Void

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                fallback: (any EventWebSearcher)? = nil,
                sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0.milliseconds)) * 1_000_000) },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.key = key
        self.send = send
        self.fallback = fallback
        self.sleep = sleep
        self.onLine = onLine
    }

    static func post(_ endpoint: String, body: JSONValue, key: String, timeout: NovaDuration) -> URLRequest {
        var request = URLRequest(url: URL(string: endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        request.limit(timeout)
        return request
    }

    /// Item 2 (`images` false) or item 5's picture search (`images` true), exactly as the spec's bodies.
    public static func searchRequest(_ query: String, images: Bool, key: String) -> URLRequest {
        let body: JSONValue = images
            ? ["query": .string(query), "max_results": .int(Int64(TavilyRoute.imageResults)), "include_images": true,
               "include_image_descriptions": true]
            : ["query": .string(query), "max_results": .int(Int64(TavilyRoute.maxResults)), "search_depth": "basic"]
        return post(TavilyRoute.searchEndpoint, body: body, key: key, timeout: TavilyRoute.searchTimeout)
    }

    /// Item 4.
    public static func extractRequest(_ urls: [String], key: String) -> URLRequest {
        let body: JSONValue = ["urls": .array(urls.map { .string($0) }), "include_images": true, "extract_depth": "basic",
                               "format": "markdown"]
        return post(TavilyRoute.extractEndpoint, body: body, key: key, timeout: TavilyRoute.extractTimeout)
    }

    private func exchange(_ request: URLRequest) async throws(TavilyFailure) -> Data {
        let status: Int, body: Data
        do {
            (status, body) = try await send(request)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw TavilyFailure(reason: "cancelled") }
            if (error as? URLError)?.code == .timedOut { throw TavilyFailure(reason: "timeout") }
            throw TavilyFailure(reason: "network")
        }
        guard status == 200 else { throw TavilyFailure(reason: "http", status: status) }
        return body
    }

    /// `results[]` (`title`, `url`, `content`, `published_date`) and `images[]` (a url, or `{url, description}`).
    public static func results(_ body: Data) -> (hits: [EventSearchHit], images: [String])? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: body), case .array(let raw)? = v["results"] else { return nil }
        let hits: [EventSearchHit] = raw.compactMap { r in
            guard let url = r["url"]?.stringValue, !url.isEmpty else { return nil }
            return EventSearchHit(title: r["title"]?.stringValue ?? "", url: url, site: URL(string: url)?.host ?? "",
                                  snippet: r["content"]?.stringValue ?? "", date: r["published_date"]?.stringValue ?? "")
        }
        return (hits, images(v["images"]))
    }

    static func images(_ v: JSONValue?) -> [String] {
        guard case .array(let a)? = v else { return [] }
        return a.compactMap { $0.stringValue ?? $0["url"]?.stringValue }.filter { !$0.isEmpty }
    }

    public func search(_ query: String, images: Bool) async throws -> EventWebResults {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        var attempt = 1
        while true {
            do {
                let body = try await exchange(Self.searchRequest(query, images: images, key: key))
                guard let r = Self.results(body) else { throw TavilyFailure(reason: "unparsed") }
                return EventWebResults(hits: r.hits, images: r.images, attempts: attempt)
            } catch let f as TavilyFailure {
                guard !images, f.retryable, attempt <= TavilyRoute.retryDelays.count, !Task.isCancelled else {
                    return try await qwen(query, after: f, attempts: attempt, images: images)
                }
                try? await sleep(TavilyRoute.retryDelays[attempt - 1])
                attempt += 1
            }
        }
    }

    /// Item 2 with §45 item 1: the query once on §41's search; its sources stand for the results, the answer text as
    /// the first one's content. Picture searches and a cancelled call get no fallback.
    private func qwen(_ query: String, after f: TavilyFailure, attempts: Int, images: Bool) async throws -> EventWebResults {
        guard !images, f.reason != "cancelled", !Task.isCancelled, let fallback else { throw f }
        onLine("fallback provider=qwen job=events after=\(f.reason)" + (f.status.map { " status=\($0)" } ?? ""))
        let a: EventSearchAnswer
        do { a = try await fallback.search(query, timeout: TavilyRoute.searchTimeout) } catch WebSearchError.notConfigured { throw f }
        let hits = a.sources.enumerated().map { i, h in
            EventSearchHit(title: h.title, url: h.url, site: URL(string: h.url)?.host ?? "", snippet: i == 0 ? a.text : h.snippet)
        }
        return EventWebResults(hits: hits, images: [], attempts: attempts)
    }

    public func extract(_ urls: [String]) async throws -> [EventPage] {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let body = try await exchange(Self.extractRequest(urls, key: key))
        return Self.pages(body)
    }

    /// Item 4: `results[]` (`url`, `title`, `raw_content`, `images`).
    public static func pages(_ body: Data) -> [EventPage] {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: body), case .array(let raw)? = v["results"] else { return [] }
        return raw.compactMap { r in
            guard let url = r["url"]?.stringValue else { return nil }
            return EventPage(url: url, title: r["title"]?.stringValue ?? "", rawContent: r["raw_content"]?.stringValue ?? "",
                             images: images(r["images"]))
        }
    }

    /// Item 5: GET, `User-Agent: Mozilla/5.0`, 15 s; nil on a failure or a non-200.
    public static func downloadRequest(_ url: String) -> URLRequest? {
        guard let u = URL(string: url), let s = u.scheme?.lowercased(), s == "https" || s == "http" else { return nil }
        var request = URLRequest(url: u)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.limit(TavilyRoute.downloadTimeout)
        return request
    }

    public func download(_ url: String) async -> Data? {
        guard let request = Self.downloadRequest(url), let (status, data) = try? await send(request), status == 200 else { return nil }
        return data
    }
}

/// F-18 §46 items 1, 5, 6: the omni model (`QwenRoute.omniModel`) on the Beijing compatible-mode endpoint with the 千问 key, streamed
/// (`stream_options.include_usage`), `modalities` text, 120 s; the answer is the joined `delta.content`. A 429, 5xx or
/// timeout is tried again after 5, 10, 20 s (4 tries).
public struct QwenOmniReader: EventReader {
    public static let model = QwenRoute.omniModel
    public static let timeout = NovaDuration.seconds(120)
    public static let retryDelays: [NovaDuration] = [.seconds(5), .seconds(10), .seconds(20)]
    public typealias Send = QwenWebSearchClient.Send
    private let key: @Sendable () -> String?
    private let send: Send
    private let sleep: TavilyClient.Sleep

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                sleep: @escaping TavilyClient.Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0.milliseconds)) * 1_000_000) }) {
        self.key = key
        self.send = send
        self.sleep = sleep
    }

    public static func request(_ content: JSONValue, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: QwenRoute.plannerEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "model": .string(model),
            "messages": [["role": "user", "content": content]],
            "modalities": ["text"],
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        request.limit(timeout)
        return request
    }

    /// Item 5: the picture first, then the prompt.
    public static func pictureContent(_ dataURL: String, prompt: String) -> JSONValue {
        [["type": "image_url", "image_url": ["url": .string(dataURL)]], ["type": "text", "text": .string(prompt)]]
    }

    /// The joined `choices[0].delta.content` of the `data:` lines.
    public static func text(_ body: Data) -> String {
        var out = ""
        for line in String(decoding: body, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard payload != "[DONE]", let v = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)),
                  case .array(let choices)? = v["choices"], let first = choices.first,
                  let piece = first["delta"]?["content"]?.stringValue else { continue }
            out += piece
        }
        return out
    }

    func call(_ content: JSONValue) async throws -> String {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        var attempt = 0
        while true {
            var retry = false
            do {
                let (status, body) = try await send(Self.request(content, key: key))
                if status == 200 { return Self.text(body) }
                retry = status == 429 || status >= 500
                if !retry { throw WebSearchError.http(status, code: QwenWebSearchClient.errorCode(body)) }
            } catch let e as URLError where e.code == .timedOut {
                retry = true
            }
            guard retry, attempt < Self.retryDelays.count, !Task.isCancelled else { throw WebSearchError.timeout }
            try await sleep(Self.retryDelays[attempt])
            attempt += 1
        }
    }

    public func picture(_ dataURL: String, prompt: String) async throws -> String {
        try await call(Self.pictureContent(dataURL, prompt: prompt))
    }

    public func text(_ prompt: String) async throws -> String { try await call(.string(prompt)) }
}

/// F-18 §46 item 1 (review 2026-11-26): the extraction on the Tavily path with item 1's retry: a 429, 5xx or timeout
/// is tried again after 5, 10, 20 s (4 tries). Any other answer, and a cancelled call, is not.
public struct RetryingEventExtractor: EventExtractor {
    private let base: any EventExtractor
    private let sleep: TavilyClient.Sleep
    private let onLine: @Sendable (String) -> Void

    public init(_ base: any EventExtractor,
                sleep: @escaping TavilyClient.Sleep = { try await Task.sleep(nanoseconds: UInt64(max(0, $0.milliseconds)) * 1_000_000) },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.base = base
        self.sleep = sleep
        self.onLine = onLine
    }

    static func retryable(_ error: any Error) -> Bool {
        if case EventExtractError.http(let status, _) = error { return status == 429 || status >= 500 }
        if let e = error as? WebSearchError, e == .timeout { return true }
        return (error as? URLError)?.code == .timedOut
    }

    public func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply {
        var attempt = 0
        while true {
            do {
                return try await base.extract(system: system, user: user, timeout: timeout)
            } catch {
                guard Self.retryable(error), attempt < QwenOmniReader.retryDelays.count, !Task.isCancelled else { throw error }
                onLine("events extract retry attempt=\(attempt + 2)")
                try await sleep(QwenOmniReader.retryDelays[attempt])
                attempt += 1
            }
        }
    }
}
