import Foundation
import NovaKit

// F-18 §39 ports (item 10: the search and extraction clients live in NovaRealtime, next to the Qwen clients)

/// One source a search returned (`search_info.search_results`).
public struct EventSearchHit: Sendable, Hashable {
    public let title: String
    public let url: String
    public let site: String
    public init(title: String, url: String, site: String) {
        self.title = title
        self.url = url
        self.site = site
    }
}

/// §39 item 2: what one search keeps: the search's own answer text and its sources.
public struct EventSearchAnswer: Sendable, Hashable {
    public let text: String
    public let sources: [EventSearchHit]
    /// `usage.total_tokens`, when given.
    public let tokens: Int?
    /// F-18 §41 item 5: the number of `web_search_call` items, when known.
    public let searches: Int?
    public init(text: String, sources: [EventSearchHit], tokens: Int? = nil, searches: Int? = nil) {
        self.text = text
        self.sources = sources
        self.tokens = tokens
        self.searches = searches
    }
}

/// §39 item 2: one keyword query on the app's search route (`QwenRoute.eventsSearch`), the query as the only user
/// message, no system text.
public protocol EventWebSearcher: Sendable {
    func search(_ query: String, timeout: NovaDuration) async throws -> EventSearchAnswer
}

public struct EventModelReply: Sendable, Hashable {
    public let content: String
    public let tokens: Int?
    public init(content: String, tokens: Int? = nil) {
        self.content = content
        self.tokens = tokens
    }
}

/// §39 item 3 (amended 2026-11-25): a non-200 extraction answer with its error body (the record prints 300 chars).
public enum EventExtractError: Error, Sendable, Hashable {
    case http(status: Int, body: String)
}

/// §39 item 3: the one extraction call (`QwenRoute.eventsExtract`, `json_object`).
public protocol EventExtractor: Sendable {
    func extract(system: String, user: String, timeout: NovaDuration) async throws -> EventModelReply
}
