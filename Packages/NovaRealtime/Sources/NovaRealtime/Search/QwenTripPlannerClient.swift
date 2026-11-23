import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §62 item 10 (T-040zo): the trip planner model's HTTP client. `QwenRoute.plannerModel` on DashScope international's
/// compatible-mode chat endpoint, `response_format: json_object`, `enable_thinking: false`, the saved search key, not
/// streamed. The loop, the plan shape and the prompt texts are in NovaCore (`TripPlanner.planTrip`,
/// `TripPlannerShape`); this only sends one round and returns the model's text. No backup model (§62 item 7): an HTTP
/// error throws `TripPlannerModelError.http`; the 30 s limit is the caller's (`TripTuning.plannerTimeout`).
public struct QwenTripPlannerClient: TripPlannerModel {
    public typealias Send = QwenWebSearchClient.Send

    public var model: String { QwenRoute.plannerModel }
    private let key: @Sendable () -> String?
    private let send: Send

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession) {
        self.key = key
        self.send = send
    }

    /// The request: the system text, then the conversation so far.
    public func request(system: String, messages: [TripPlannerMessage], key: String) -> URLRequest {
        var request = URLRequest(url: URL(string: QwenRoute.plannerEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The URLSession limit backs up the caller's 30 s (TripTuning.plannerTimeout).
        request.timeoutInterval = 35
        let body: JSONValue = [
            "model": .string(model),
            "messages": .array([["role": "system", "content": .string(system)]]
                + messages.map { ["role": .string($0.role.rawValue), "content": .string($0.content)] }),
            "response_format": ["type": "json_object"],
            "enable_thinking": false,
            "stream": false,
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func complete(system: String, messages: [TripPlannerMessage]) async throws -> String {
        guard let key = key(), !key.isEmpty else { throw TripPlannerModelError.notConfigured }
        let (status, body) = try await send(request(system: system, messages: messages, key: key))
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
