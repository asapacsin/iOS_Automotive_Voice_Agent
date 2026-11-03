import Foundation

/// F-18 §16 item 4 (T-046d): a provider-neutral web search (I-13). One request per call; the caller decides
/// whether the reply really searched (§16 item 5).
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
    /// The searches the search model ran (`webSearchQueries`).
    public let queries: [String]
    /// One per grounding chunk.
    public let sources: [WebSearchSource]
    /// Search Suggestions HTML (`searchEntryPoint.renderedContent`), shown only to the driver.
    public let suggestionHTML: String?

    public init(answer: String, queries: [String], sources: [WebSearchSource], suggestionHTML: String?) {
        self.answer = answer
        self.queries = queries
        self.sources = sources
        self.suggestionHTML = suggestionHTML
    }
}

/// Why a request failed. Carries codes only, never text (I-8).
public enum WebSearchError: Error, Sendable, Hashable {
    case timeout
    case network
    case http(Int)
    case notConfigured
}
