import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §62 item 10 (T-040zo): the trip planner model's HTTP client. `QwenRoute.plannerModel` on DashScope international's
/// compatible-mode chat endpoint, `response_format: json_object`, `enable_thinking: false`, the saved search key, not
/// streamed. The loop, the plan shape and the prompt texts are in NovaCore (`TripPlanner.planTrip`,
/// `TripPlannerShape`); this only sends one round and returns the model's text. F-18 §36 (T-046y): a 429 or a quota 403
/// moves the round to the next model of `QwenRoute.planner.chain` (`QwenFallback`; the same planner job, never another
/// kind of planner, §62 item 7). Any other HTTP error, or every model used up, throws `TripPlannerModelError.http`;
/// the 30 s limit is the caller's (`TripTuning.plannerTimeout`).
public struct QwenTripPlannerClient: TripPlannerModel {
    public typealias Send = QwenWebSearchClient.Send

    public var model: String { route.model }
    public let route: QwenRoute
    private let key: @Sendable () -> String?
    private let send: Send
    private let fallback: QwenFallback

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                route: QwenRoute = .planner, fallback: QwenFallback = .shared) {
        self.key = key
        self.send = send
        self.route = route
        self.fallback = fallback
    }

    /// The request: the system text, then the conversation so far.
    public func request(system: String, messages: [TripPlannerMessage], key: String, route: QwenRoute? = nil) -> URLRequest {
        let route = route ?? self.route
        var request = URLRequest(url: URL(string: QwenRoute.plannerEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The URLSession limit backs up the caller's 30 s (TripTuning.plannerTimeout).
        request.timeoutInterval = 35
        let body: JSONValue = [
            "model": .string(route.model),
            "messages": .array([["role": "system", "content": .string(system)]]
                + messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }),
            "response_format": ["type": "json_object"],
            "enable_thinking": .bool(route.thinking),
            "stream": false,
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func complete(system: String, messages: [TripPlannerMessage]) async throws -> String {
        guard let key = key(), !key.isEmpty else { throw TripPlannerModelError.notConfigured }
        let status: Int, body: Data
        do {
            let text = ([system] + messages.map(\.content)).joined(separator: "\n")
            (status, body) = try await fallback.run(route, request: text) { route, timeout in
                var req = request(system: system, messages: messages, key: key, route: route)
                req.limit(timeout)
                return try await send(req)
            }
        } catch let refused as BudgetRefused {
            // §36 row 34: every planner model used up (or the budget refused): fails at once, nothing sent.
            throw TripPlannerModelError.http(refused.reason == .quota ? 403 : 429)
        }
        guard status == 200 else { throw TripPlannerModelError.http(status) }
        return Self.content(body) ?? ""
    }

    /// `choices[0].message.content` of a chat completion; nil when the body has none.
    public static func content(_ body: Data) -> String? {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: body),
              case .array(let choices)? = value["choices"], let first = choices.first else { return nil }
        return first["message"]?["content"]?.stringValue
    }
}
