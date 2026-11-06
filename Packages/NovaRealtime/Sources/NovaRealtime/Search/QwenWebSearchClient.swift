import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §17 items 3-4 (T-046e): the only `WebSearchService`. One streamed request to `qwen3.7-flash` on Alibaba Cloud
/// Model Studio (Singapore, multimodal API) with search on, using its own Keychain key in the `Authorization` header
/// only. The FreshPrompt system text and date turn carry the phone's date and time zone (§24) and are never sent to the voice model.
public struct QwenWebSearchClient: WebSearchService {
    /// One constant: changing the search model is a one-line change.
    public static let model = "qwen3.7-flash"
    public static let endpoint = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    /// §20 item 1, §22 item 1: each search option is one constant. `turbo` searches every time; `agent` let the model skip it.
    public static let searchStrategy = "turbo"
    public static let enableSource = true
    public static let forcedSearch = true

    private let key: @Sendable () -> String?
    private let send: Send
    /// §18 item 7: nil with the record off, so no exchange is built.
    private let onExchange: (@Sendable (WebSearchExchange) -> Void)?
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current },
                onExchange: (@Sendable (WebSearchExchange) -> Void)? = nil) {
        self.key = key
        self.onExchange = onExchange
        self.send = send
        self.now = now
        self.zone = zone
    }

    /// The whole stream is read before parsing (§17 item 3); she only gets the finished answer.
    public static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// F-18 §24 item 2 (T-046m): `November 05, 2026` from the phone's date in its zone (`en_US_POSIX`, Gregorian).
    public static func englishDate(now: Date, zone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "MMMM dd, yyyy"
        return f.string(from: now)
    }

    /// F-18 §24 items 2-3: copied from FreshPrompt (github.com/freshllms/freshqa, freshprompt.ipynb) with nothing
    /// added; only the date and zone are filled in. No refusal, exact-day, language or length rule (owner rule
    /// 2026-11-05: the search prompt is never our own wording).
    public static func instruction(now: Date, zone: TimeZone) -> String {
        "You are a helpful assistant. Answer as concisely as possible. Knowledge cutoff: \(englishDate(now: now, zone: zone))."
    }

    /// The FreshPrompt date turn: user `What's today's date?`, assistant `Today is {date} in {zone}.`
    public static let dateQuestion = "What's today's date?"
    public static func dateAnswer(now: Date, zone: TimeZone) -> String {
        "Today is \(englishDate(now: now, zone: zone)) in \(zone.identifier)."
    }

    public func request(_ query: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        let date = now()
        let zone = zone()
        let body: JSONValue = [
            "model": .string(Self.model),
            "input": ["messages": [
                ["role": "system", "content": [["text": .string(Self.instruction(now: date, zone: zone))]]],
                ["role": "user", "content": [["text": .string(Self.dateQuestion)]]],
                ["role": "assistant", "content": [["text": .string(Self.dateAnswer(now: date, zone: zone))]]],
                ["role": "user", "content": [["text": .string(query)]]],
            ]],
            "parameters": [
                "result_format": "message",
                "incremental_output": true,
                "enable_thinking": false,
                "enable_search": true,
                "search_options": ["search_strategy": .string(Self.searchStrategy), "enable_source": .bool(Self.enableSource),
                                   "forced_search": .bool(Self.forcedSearch)],
            ],
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func search(_ query: String, attempt: Int) async throws -> WebSearchReply {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let request = request(query, key: key)
        let started = ContinuousClock.now
        func ms() -> Int {
            let d = ContinuousClock.now - started
            return Int(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000)
        }
        // §18 items 1-2: the exact body sent, never the headers (the key is only there).
        func exchange(status: Int?, body: Data?, error: String?, urlError: Int?) {
            guard let onExchange else { return }
            let sent = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
            let counts = body.map(Self.counts) ?? Counts()
            onExchange(WebSearchExchange(attempt: attempt, requestBody: sent, status: status, ms: ms(),
                                         bytes: body?.count ?? 0, responseBody: body.map { String(decoding: $0, as: UTF8.self) },
                                         error: error, urlError: urlError, chunks: counts.chunks,
                                         answerChars: counts.answerChars, sources: counts.sources,
                                         searchCount: counts.searchCount))
        }
        let status: Int
        let body: Data
        do {
            (status, body) = try await send(request)
        } catch {
            let urlError = (error as? URLError)?.code.rawValue
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                exchange(status: nil, body: nil, error: "cancelled", urlError: urlError)
                throw WebSearchError.timeout
            }
            if (error as? URLError)?.code == .timedOut {
                exchange(status: nil, body: nil, error: "timeout", urlError: urlError)
                throw WebSearchError.timeout
            }
            exchange(status: nil, body: nil, error: "network", urlError: urlError)
            throw WebSearchError.network
        }
        exchange(status: status, body: body, error: nil, urlError: nil)
        guard status == 200 else { throw WebSearchError.http(status, code: Self.errorCode(body)) }
        let parsed = Self.parse(body)
        if let code = parsed.code { throw WebSearchError.api(code) }
        return parsed.reply
    }

    struct Counts {
        var chunks = 0
        var answerChars = 0
        var sources = 0
        var searchCount: Int?
    }

    /// §18 item 5: from the same parser the executor's reply comes from, over the whole body.
    static func counts(_ data: Data) -> Counts {
        let objects = objects(data)
        let reply = parse(data).reply
        var count: Int?
        for o in objects {
            if case .int(let n)? = o["usage"]?["plugins"]?["search"]?["count"] { count = Int(n) }
        }
        return Counts(chunks: objects.count, answerChars: reply.answer.count, sources: reply.sources.count, searchCount: count)
    }

    /// The JSON objects in a body: each `data:` line of a stream, or the whole body when it is one JSON object.
    /// Lines that are not JSON are ignored.
    static func objects(_ data: Data) -> [JSONValue] {
        let text = String(decoding: data, as: UTF8.self)
        var out: [JSONValue] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8)), case .object = v { out.append(v) }
        }
        if out.isEmpty, let v = try? JSONDecoder().decode(JSONValue.self, from: data), case .object = v { out.append(v) }
        return out
    }

    /// The first non-empty error `code` in a body (a non-200 reply or an error chunk). `message` is never read.
    static func errorCode(_ data: Data) -> String? {
        for o in objects(data) {
            if let code = o["code"]?.stringValue, !code.isEmpty { return code }
        }
        return nil
    }

    /// §17 item 4: the answer joins `output.choices[0].message.content` from every chunk (a string or a list of
    /// `{"text": ...}`), leaving out `reasoning_content`; sources are the last non-empty
    /// `output.search_info.search_results`. Anything missing comes back empty; the executor decides.
    public static func parse(_ data: Data) -> (reply: WebSearchReply, code: String?) {
        var answer = ""
        var results: [JSONValue] = []
        let objects = objects(data)
        for o in objects {
            let output = o["output"]
            if case .array(let choices)? = output?["choices"], let first = choices.first {
                switch first["message"]?["content"] {
                case .string(let s)?: answer += s
                case .array(let parts)?: for p in parts { answer += p["text"]?.stringValue ?? "" }
                default: break
                }
            }
            if case .array(let r)? = output?["search_info"]?["search_results"], !r.isEmpty { results = r }
        }
        let code = objects.lazy.compactMap { $0["code"]?.stringValue }.first { !$0.isEmpty }
        let sources = results.map { r in
            WebSearchSource(title: r["title"]?.stringValue ?? "",
                            host: r["url"]?.stringValue.flatMap { URL(string: $0)?.host } ?? "")
        }
        return (WebSearchReply(answer: answer.trimmingCharacters(in: .whitespacesAndNewlines), sources: sources), code)
    }
}
