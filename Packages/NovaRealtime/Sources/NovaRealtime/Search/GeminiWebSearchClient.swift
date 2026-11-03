import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-18 §16 item 4 (T-046d): the only Gemini `WebSearchService`. One `generateContent` request to the search model
/// with Google Search on, using the existing Keychain Gemini key in the `x-goog-api-key` header. The system
/// instruction carries the phone's date and time zone and is never sent to the voice model.
public struct GeminiWebSearchClient: WebSearchService {
    /// One constant: changing the search model is a one-line change.
    public static let model = "gemini-2.5-flash-lite"
    public static let endpoint = "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent"

    public typealias Send = @Sendable (URLRequest) async throws -> (status: Int, body: Data)

    private let credentials: any RealtimeCredentialSource
    private let send: Send
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone

    public init(credentials: any RealtimeCredentialSource, send: @escaping Send = GeminiWebSearchClient.urlSession,
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.credentials = credentials
        self.send = send
        self.now = now
        self.zone = zone
    }

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
        return "今天是\(date)，\(weekdays[(c.weekday! - 1) % 7])，时区\(zone.identifier)。必须用 Google 搜索查，不要凭记忆回答。用一两句中文回答，给出具体的数字、地点和日期。查不到就说查不到。"
    }

    public func request(_ query: String, key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: Self.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        let body: JSONValue = [
            "systemInstruction": ["parts": [["text": .string(Self.instruction(now: now(), zone: zone()))]]],
            "contents": [["role": "user", "parts": [["text": .string(query)]]]],
            "tools": [["google_search": [:]]],
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func search(_ query: String) async throws -> WebSearchReply {
        guard case .apiKey(let key)? = try? await credentials.credential(), !key.isEmpty else {
            throw WebSearchError.notConfigured
        }
        let status: Int
        let body: Data
        do {
            (status, body) = try await send(request(query, key: key))
        } catch let error as URLError where error.code == .timedOut {
            throw WebSearchError.timeout
        } catch {
            throw Task.isCancelled ? WebSearchError.timeout : WebSearchError.network
        }
        guard status == 200 else { throw WebSearchError.http(status) }
        return Self.parse(body)
    }

    /// Text parts of the first candidate, `webSearchQueries`, `groundingChunks[].web` and the suggestion HTML.
    /// Anything missing comes back empty; the executor decides whether the reply searched.
    public static func parse(_ data: Data) -> WebSearchReply {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .array(let candidates)? = json["candidates"], let first = candidates.first else {
            return WebSearchReply(answer: "", queries: [], sources: [], suggestionHTML: nil)
        }
        var answer = ""
        if case .array(let parts)? = first["content"]?["parts"] {
            for part in parts where part["thought"]?.boolValue != true {
                answer += part["text"]?.stringValue ?? ""
            }
        }
        let meta = first["groundingMetadata"]
        var queries: [String] = []
        if case .array(let q)? = meta?["webSearchQueries"] { queries = q.compactMap(\.stringValue).filter { !$0.isEmpty } }
        var sources: [WebSearchSource] = []
        if case .array(let chunks)? = meta?["groundingChunks"] {
            for chunk in chunks {
                guard let web = chunk["web"] else { continue }
                let title = web["title"]?.stringValue ?? ""
                // Hosts only: the chunk's domain, or the URI's host unless it is Google's redirect.
                let uriHost = web["uri"]?.stringValue.flatMap { URL(string: $0)?.host }
                let host = web["domain"]?.stringValue ?? (uriHost?.hasSuffix("vertexaisearch.cloud.google.com") == false ? uriHost! : "")
                sources.append(WebSearchSource(title: title, host: host))
            }
        }
        let html = meta?["searchEntryPoint"]?["renderedContent"]?.stringValue
        return WebSearchReply(answer: answer.trimmingCharacters(in: .whitespacesAndNewlines), queries: queries,
                              sources: sources, suggestionHTML: html?.isEmpty == false ? html : nil)
    }
}
