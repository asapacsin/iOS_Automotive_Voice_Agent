import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §4 item 6 (owner 2026-11-17): Qwen picks which 高德 result each asked trip name means. The same model, endpoint
/// and Keychain key as `QwenWebSearchClient`, search off, not streamed. The question is EntGPT's multiple-choice form
/// (arXiv 2402.06738): the mention, numbered candidates and "None of the above", under its instruction "Select the
/// entity which best describes the mention"; only the answer format is ours.
public struct QwenPlacePicker: PlacePicker {
    public typealias Send = QwenWebSearchClient.Send

    public enum PickError: Error, Equatable {
        case http(Int)
        case unreadable
    }

    private let key: @Sendable () -> String?
    private let send: Send
    private let fallback: QwenFallback

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                fallback: QwenFallback = .shared) {
        self.key = key
        self.fallback = fallback
        self.send = send
    }

    public static let instruction = "Select the entity which best describes the mention."

    /// One question per name: EntGPT's mention line and lettered options become numbered options; 0 is "None of the
    /// above". The answer format closes the message.
    public static func question(_ choices: [PlaceChoice]) -> String {
        var parts: [String] = []
        for (n, choice) in choices.enumerated() {
            var lines = ["Mention \(n + 1): \(choice.asked)" + (choice.city.map { " (city: \($0))" } ?? "")]
            for (i, place) in choice.candidates.enumerated() {
                let detail = [place.address, place.district].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
                lines.append("(\(i + 1)) \(place.name)" + (detail.isEmpty ? "" : " — \(detail)"))
            }
            lines.append("(0) None of the above")
            parts.append(lines.joined(separator: "\n"))
        }
        parts.append("Answer with one line per mention: `<mention number>: <option number>`.")
        return parts.joined(separator: "\n\n")
    }

    public func request(_ choices: [PlaceChoice], key: String, route: QwenRoute = .picker) -> URLRequest {
        var request = URLRequest(url: URL(string: QwenRoute.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: JSONValue = [
            "model": .string(route.model),
            "input": ["messages": [
                ["role": "system", "content": [["text": .string(Self.instruction)]]],
                ["role": "user", "content": [["text": .string(Self.question(choices))]]],
            ]],
            "parameters": route.parameters(),
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func pick(_ choices: [PlaceChoice]) async throws -> [Int?] {
        guard let key = key(), !key.isEmpty else { throw PlacePickerNotConfigured() }
        // §50 item 10 (T-040x): a 429 or a quota 403 switches once to the backup, within what is left of 2.5 s.
        let (status, body) = try await fallback.run(.picker, request: Self.question(choices)) { route, timeout in
            var req = request(choices, key: key, route: route)
            req.limit(timeout)
            return try await send(req)
        }
        guard status == 200 else { throw PickError.http(status) }
        return try Self.answers(QwenWebSearchClient.parse(body).reply.answer, choices: choices)
    }

    /// `<mention>: <option>` lines (also `：`); option 0 is none, 1… a candidate (returned 0-based). Every mention needs
    /// one answer within range, or the whole answer is unreadable.
    public static func answers(_ text: String, choices: [PlaceChoice]) throws -> [Int?] {
        var found: [Int: Int] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let digits = raw.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            guard digits.count >= 2 else { continue }
            found[digits[0]] = digits[1]
        }
        return try choices.enumerated().map { n, choice in
            guard let option = found[n + 1], (0...choice.candidates.count).contains(option) else { throw PickError.unreadable }
            return option == 0 ? nil : option - 1
        }
    }
}
