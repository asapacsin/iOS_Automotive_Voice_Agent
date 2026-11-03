import Foundation

/// F-18 §16 item 4, §17 item 6 (T-046e): a provider-neutral web search (I-13). One request per call; the caller
/// decides whether the reply really searched (§17 item 5).
public protocol WebSearchService: Sendable {
    func search(_ query: String) async throws -> WebSearchReply
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
