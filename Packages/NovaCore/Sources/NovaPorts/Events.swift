import Foundation
import NovaKit

// F-18 §35 ports (F-18 §35 item 10: the chat client, the search and the page fetch live in NovaRealtime)

/// One tool call the loop model asked for.
public struct EventToolCall: Sendable, Hashable {
    public let id: String
    public let name: String
    /// The call's `arguments` JSON text, as the model wrote it.
    public let arguments: String
    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// One message of the loop's conversation (OpenAI-compatible chat shape).
public struct EventChatMessage: Sendable, Hashable {
    public enum Role: String, Sendable, Hashable { case system, user, assistant, tool }
    public let role: Role
    public var content: String
    public let toolCalls: [EventToolCall]
    public let toolCallID: String?
    public init(role: Role, content: String, toolCalls: [EventToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

public struct EventChatReply: Sendable, Hashable {
    public let content: String
    public let toolCalls: [EventToolCall]
    /// The response `usage.total_tokens`, when given.
    public let tokens: Int?
    public init(content: String, toolCalls: [EventToolCall] = [], tokens: Int? = nil) {
        self.content = content
        self.toolCalls = toolCalls
        self.tokens = tokens
    }
}

/// The loop model (`QwenRoute.eventsLoop`). `tools` false: the final ask, no tools declared. `timeout` is what is
/// left of the loop's time.
public protocol EventChatModel: Sendable {
    func turn(_ messages: [EventChatMessage], tools: Bool, timeout: NovaDuration) async throws -> EventChatReply
}

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

/// Item 3: `search(query)`, the app's search route returning links, not the answer text.
public protocol EventSearcher: Sendable {
    func search(_ query: String) async throws -> [EventSearchHit]
}

/// Item 3: `open_page(url)`: the page's HTML (20 s, 2 MB, desktop browser user agent, `zh-CN`).
public protocol EventPageFetcher: Sendable {
    func open(_ url: String) async throws -> String
}

