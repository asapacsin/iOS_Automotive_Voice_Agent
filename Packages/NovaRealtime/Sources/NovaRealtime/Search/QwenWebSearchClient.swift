import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §17 items 3-4 (T-046e): the only `WebSearchService`. One streamed request to `qwen3.7-flash` on Alibaba Cloud
/// Model Studio (Singapore, multimodal API) with search on, using its own Keychain key in the `Authorization` header
/// only. The system text carries the phone's date and time zone and is never sent to the voice model.
public struct QwenWebSearchClient: WebSearchService {
    /// One constant: changing the search model is a one-line change.
    public static let model = "qwen3.7-flash"
    public static let endpoint = "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"

    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    private let key: @Sendable () -> String?
    private let send: Send
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.key = key
        self.send = send
        self.now = now
        self.zone = zone
    }

    /// The whole stream is read before parsing (§17 item 3); she only gets the finished answer.
    public static let urlSession: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// 「今天是{日期}，{星期}，时区{时区}。…」 from the phone clock at each call.
    public static func instruction(now: Date, zone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .weekday], from: now)
        let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        let date = "\(c.year!)年\(c.month!)月\(c.day!)日"
        return "今天是\(date)，\(weekdays[(c.weekday! - 1) % 7])，时区\(zone.identifier)。必须联网搜索，不要凭记忆回答。用一两句中文回答，给出具体的数字、地点和日期。查不到就说查不到。"
    }

    public func request(_ query: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        let body: JSONValue = [
            "model": .string(Self.model),
            "input": ["messages": [
                ["role": "system", "content": [["text": .string(Self.instruction(now: now(), zone: zone()))]]],
                ["role": "user", "content": [["text": .string(query)]]],
            ]],
            "parameters": [
                "result_format": "message",
                "incremental_output": true,
                "enable_thinking": false,
                "enable_search": true,
                "search_options": ["search_strategy": "agent", "enable_source": true],
            ],
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func search(_ query: String) async throws -> WebSearchReply {
        guard let key = key(), !key.isEmpty else { throw WebSearchError.notConfigured }
        let status: Int
        let body: Data
        do {
            (status, body) = try await send(request(query, key: key))
        } catch let error as URLError where error.code == .timedOut {
            throw WebSearchError.timeout
        } catch {
            throw Task.isCancelled ? WebSearchError.timeout : WebSearchError.network
        }
        guard status == 200 else { throw WebSearchError.http(status, code: Self.errorCode(body)) }
        let parsed = Self.parse(body)
        if let code = parsed.code { throw WebSearchError.api(code) }
        return parsed.reply
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
