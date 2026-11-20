import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §50 items 1 and 9 (T-040v): the trip request turned into real places by Qwen with web search, on the
/// `ground` route of `QwenRoute` (model, search and thinking options from there). Streamed and read to the end; the
/// answer is used only when the search ran (`search_info` has results) and the JSON has every field.
/// The same Keychain key as F-18 §16, in the `Authorization` header only; the key is never logged.
public struct QwenTripGrounder: TripGrounder {
    public typealias Send = QwenWebSearchClient.Send

    public static let route = QwenRoute.ground

    /// §50 item 9: `response_format: {"type": "json_object"}` is sent only once row 160 (PC check, NOT RUN) shows it is
    /// accepted together with search. Until then the JSON-only prompt alone is used.
    public static let sendsJSONMode = false

    private let key: @Sendable () -> String?
    private let send: Send
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private let fallback: QwenFallback

    public init(key: @escaping @Sendable () -> String?, send: @escaping Send = QwenWebSearchClient.urlSession,
                now: @escaping @Sendable () -> Date = { Date() }, zone: @escaping @Sendable () -> TimeZone = { .current },
                fallback: QwenFallback = .shared) {
        self.key = key
        self.fallback = fallback
        self.send = send
        self.now = now
        self.zone = zone
    }

    // MARK: Prompt (owner rule 2026-11-05: copied, never our own wording)

    /// Copied from Alibaba Cloud Model Studio's published web-search example (system message of the Chat Completions
    /// and DashScope samples), https://www.alibabacloud.com/help/en/model-studio/web-search (checked 2026-11-19).
    public static let searchSystem = "You are a helpful assistant."

    /// Copied from Alibaba Cloud Model Studio's published structured-output (JSON mode) curl example, whose system
    /// message is "You need to extract the name (string), age (string), and email (string). Output the result as a
    /// JSON string." (https://www.alibabacloud.com/help/en/model-studio/json-mode, checked 2026-11-19). Only the field
    /// list is ours (§50 item 1 output); the sentence frame is the example's. The page requires the word "JSON" in
    /// the prompt for JSON mode, which this sentence carries.
    public static let jsonSystem = "You need to extract the places (array of objects: name (string), english (string), "
        + "minutes (integer), importance (integer)), hotels (array of objects: night (integer), name (string), "
        + "english (string)), and area (string). Output the result as a JSON string."

    /// §50 item 1 input, as values only: the field names and the driver's values, no instruction text.
    public static func input(_ r: TripGroundRequest) -> String {
        var o: [String: JSONValue] = [
            "city": .string(r.city),
            "days": .int(Int64(r.days)),
            "places": .array(r.places.map { p in
                var v: [String: JSONValue] = ["name": .string(p.name), "importance": .int(Int64(p.importance))]
                if let m = p.minutes { v["minutes"] = .int(Int64(m)) }
                return .object(v)
            }),
        ]
        if let w = r.wishes { o["wishes"] = .string(w) }
        if let s = r.start { o["start"] = .string(s) }
        if let e = r.end { o["end"] = .string(e) }
        if let h = r.hotelNear { o["hotel_near"] = .string(h) }
        let data = (try? JSONValue.canonicalEncoder().encode(JSONValue.object(o))) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    public func request(_ r: TripGroundRequest, key: String, route: QwenRoute = Self.route) -> URLRequest {
        var request = URLRequest(url: URL(string: QwenRoute.endpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if route.stream { request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE") }
        let date = now(), zone = zone()
        var extra: [String: JSONValue] = [:]
        if Self.sendsJSONMode { extra["response_format"] = ["type": "json_object"] }
        let body: JSONValue = [
            "model": .string(route.model),
            "input": ["messages": [
                ["role": "system", "content": [["text": .string(Self.searchSystem + " " + Self.jsonSystem)]]],
                // F-18 §24: the date turn, so opening hours and seasonal places fit the trip dates.
                ["role": "user", "content": [["text": .string(QwenWebSearchClient.dateQuestion)]]],
                ["role": "assistant", "content": [["text": .string(QwenWebSearchClient.dateAnswer(now: date, zone: zone))]]],
                ["role": "user", "content": [["text": .string(Self.input(r))]]],
            ]],
            "parameters": route.parameters(extra),
        ]
        request.httpBody = try? JSONValue.canonicalEncoder().encode(body)
        return request
    }

    public func ground(_ r: TripGroundRequest) async throws -> TripGroundAnswer {
        guard let key = key(), !key.isEmpty else { throw TripGroundError.notConfigured }
        let status: Int, body: Data
        do {
            // §50 item 10 (T-040x): a 429 or a quota 403 switches once to `route.backupModel` with `turbo`.
            (status, body) = try await fallback.run(Self.route, request: Self.input(r)) { route, timeout in
                var req = request(r, key: key, route: route)
                req.limit(timeout)
                return try await send(req)
            }
        } catch {
            if (error as? URLError)?.code == .timedOut || error is CancellationError { throw TripGroundError.timeout }
            throw TripGroundError.failed
        }
        guard status == 200 else { throw TripGroundError.failed }
        return try Self.answer(body)
    }

    /// The streamed body checked: an error chunk is `failed`, no search result `nosearch`, wrong fields `json`.
    public static func answer(_ body: Data) throws -> TripGroundAnswer {
        let parsed = QwenWebSearchClient.parse(body)
        if parsed.code != nil { throw TripGroundError.failed }
        guard !parsed.reply.sources.isEmpty else { throw TripGroundError.noSearch }
        return try fields(parsed.reply.answer)
    }

    /// §50 item 1 output: `places` `[{name, english, minutes, importance}]` (at least one), `hotels`
    /// `[{night, name, english}]`, `area`. A ```json fence around the object is allowed.
    public static func fields(_ text: String) throws -> TripGroundAnswer {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("```") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().joined(separator: "\n")
            if let end = t.range(of: "```", options: .backwards) { t = String(t[..<end.lowerBound]) }
        }
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(t.utf8)),
              case .array(let rawPlaces)? = v["places"], !rawPlaces.isEmpty,
              case .array(let rawHotels)? = v["hotels"],
              let area = v["area"]?.stringValue else { throw TripGroundError.json }
        let places = try rawPlaces.map { p -> TripGroundPlace in
            guard let name = p["name"]?.stringValue, !name.isEmpty, let english = p["english"]?.stringValue,
                  let minutes = p["minutes"]?.intValue, let importance = p["importance"]?.intValue,
                  (1...3).contains(importance) else { throw TripGroundError.json }
            return TripGroundPlace(name: name, english: english, minutes: Int(minutes), importance: Int(importance))
        }
        let hotels = try rawHotels.map { h -> TripGroundHotel in
            guard let night = h["night"]?.intValue, let name = h["name"]?.stringValue, !name.isEmpty else { throw TripGroundError.json }
            return TripGroundHotel(night: Int(night), name: name, english: h["english"]?.stringValue)
        }
        return TripGroundAnswer(places: places, hotels: hotels, area: area)
    }
}
