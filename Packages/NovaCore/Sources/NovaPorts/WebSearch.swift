import Foundation

/// F-18 §16 item 4, §17 item 6 (T-046e): a provider-neutral web search (I-13). One request per call; the caller
/// decides whether the reply really searched (§17 item 5).
public protocol WebSearchService: Sendable {
    /// `attempt` counts from 1 within one `web_search` call (§18 items 1-2).
    func search(_ query: String, attempt: Int) async throws -> WebSearchReply
}

public struct WebSearchSource: Sendable, Hashable {
    public let title: String
    public let host: String
    public init(title: String, host: String) {
        self.title = title
        self.host = host
    }
}

public struct WebSearchReply: Sendable, Hashable {
    /// The answer text (may be empty when the model wrote nothing).
    public let answer: String
    /// The search results the provider returned.
    public let sources: [WebSearchSource]

    public init(answer: String, sources: [WebSearchSource]) {
        self.answer = answer
        self.sources = sources
    }
}

/// Why a request failed. Carries codes only, never text (I-8). `code` is the provider's error code, uncleaned.
public enum WebSearchError: Error, Sendable, Hashable {
    case timeout
    case network
    case http(Int, code: String? = nil)
    /// An error `code` inside a 200 stream.
    case api(String)
    case notConfigured
}

/// F-18 §18 item 7 (T-046f): one request to the search provider and what came back, for the local record only
/// (F-12 §17, I-7, I-8). Never the key or the headers: there is no field for them. Built only when someone listens.
public struct WebSearchExchange: Sendable, Hashable {
    public let attempt: Int
    /// The exact JSON body sent.
    public let requestBody: String
    /// nil when no reply came.
    public let status: Int?
    public let ms: Int
    public let bytes: Int
    /// The raw response body, whole (the record cuts it).
    public let responseBody: String?
    /// `timeout`, `network` or `cancelled` when no reply came.
    public let error: String?
    /// The `URLError` code, when there was one.
    public let urlError: Int?
    /// Parser counts over the whole body (§18 item 5).
    public let chunks: Int
    public let answerChars: Int
    public let sources: Int
    public let searchCount: Int?

    public init(attempt: Int, requestBody: String, status: Int?, ms: Int, bytes: Int, responseBody: String?,
                error: String?, urlError: Int?, chunks: Int = 0, answerChars: Int = 0, sources: Int = 0,
                searchCount: Int? = nil) {
        self.attempt = attempt
        self.requestBody = requestBody
        self.status = status
        self.ms = ms
        self.bytes = bytes
        self.responseBody = responseBody
        self.error = error
        self.urlError = urlError
        self.chunks = chunks
        self.answerChars = answerChars
        self.sources = sources
        self.searchCount = searchCount
    }
}
