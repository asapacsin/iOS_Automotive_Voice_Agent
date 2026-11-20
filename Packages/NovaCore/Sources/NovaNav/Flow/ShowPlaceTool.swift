import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-09b §16 item 8 (T-031za): `show_place(name)`. She only names the place; code fills and shows the card the same
/// way every time: 1 find the place, 2 get the content, 3 show the card, 4 return the result. Done only when the App
/// says the card holds that place (I-1). The log gets codes only (I-8):
/// `show place ok=<yes|no> via=<screen|city|country> intro=<yes|no> ms=`.
public struct ShowPlaceTool: ToolExecutor {
    public static let tool = "show_place"

    /// What the App reports after opening the card (steps 2 and 3).
    public struct Shown: Sendable, Hashable {
        public let shown: Bool
        public let intro: String?
        public let address: String?
        public init(shown: Bool, intro: String?, address: String?) {
            self.shown = shown
            self.intro = intro
            self.address = address
        }
    }

    enum Via: String { case screen, city, country }

    private let onScreen: @Sendable () async -> [Place]
    private let search: any PlaceSearch
    private let cityCode: @Sendable () async -> String?
    private let present: @Sendable (TripCard) async -> Shown
    private let clock: any NovaClock
    private let onLine: @Sendable (String) -> Void

    /// `onScreen`: the places on screen (candidate list, chosen or guided destination, trip stops). `cityCode`: the
    /// car's city adcode, nil when unknown. `present`: opens the card and answers after the intro arrived or failed.
    public init(onScreen: @escaping @Sendable () async -> [Place], search: any PlaceSearch,
                cityCode: @escaping @Sendable () async -> String? = { nil },
                present: @escaping @Sendable (TripCard) async -> Shown, clock: any NovaClock,
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onScreen = onScreen
        self.search = search
        self.cityCode = cityCode
        self.present = present
        self.clock = clock
        self.onLine = onLine
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let started = clock.now
        let name = (call.arguments["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return ToolReply.failure(.invalidFieldValue, facts: ["shown": false], may: [.askPlace],
                                     mustNot: [.claimDone, .invent]).result
        }
        // Step 1: find the place.
        let place: Place
        let via: Via
        if let match = await onScreen().first(where: { Self.matches($0.name, name) }) {
            place = match
            via = .screen
        } else {
            let found: (Place, Via)?
            do {
                found = try await searchNear(name)
            } catch let error as AmapWebError {
                let cause = LookupReply.cause(of: error)
                return LookupReply.failed(LookupReply.code(for: cause), what: "place", cause: cause,
                                          facts: ["shown": false], mustNot: [.claimDone])
            } catch {
                return LookupReply.failed(.liveInfoUnavailable, what: "place", cause: .network,
                                          facts: ["shown": false], mustNot: [.claimDone])
            }
            guard let found else {
                return LookupReply.notFound(.noCandidates, what: name, facts: ["shown": false], may: [.askPlace],
                                            mustNot: [.claimDone])
            }
            (place, via) = found
        }
        // Steps 2 and 3: the App fills and opens the card.
        let shown = await present(Self.card(for: place))
        let ms = max(0, Int((clock.now - started).milliseconds))
        onLine("show place ok=\(shown.shown ? "yes" : "no") via=\(via.rawValue) intro=\(shown.intro == nil ? "no" : "yes") ms=\(ms)")
        // Step 4: return the result.
        guard shown.shown else {
            return ToolReply.notDone(.placeNotShown, facts: ["shown": false, "name": .string(place.name)],
                                     may: [.tryLater], mustNot: [.invent]).result
        }
        var facts: [String: JSONValue] = ["shown": true, "name": .string(place.name),
                                          "intro": shown.intro.map { .string($0) } ?? .null]
        if let address = shown.address ?? place.address { facts["address"] = .string(address) }
        return ToolReply.success(facts: facts, mustNot: [.invent]).result
    }

    /// The car's city first (`citylimit=true`); nationwide when that finds nothing or the city is unknown.
    private func searchNear(_ name: String) async throws -> (Place, Via)? {
        if let city = await cityCode(), !city.isEmpty,
           let local = try await search.text(name, city: city, cityLimit: true).first {
            return (local, .city)
        }
        return try await search.text(name, city: nil).first.map { ($0, .country) }
    }

    /// One name contains the other, ignoring spaces and case.
    static func matches(_ shown: String, _ asked: String) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let a = norm(shown), b = norm(asked)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    /// The card the trip details sheet shows (F-15b §11 item 6), built from any place.
    public static func card(for place: Place) -> TripCard {
        TripCard(index: 1, placeID: place.id, name: place.name, district: place.district,
                 km: place.distanceMeters.map { (Double($0) / 100).rounded() / 10 }, photoURL: place.photoURL,
                 initial: String(place.name.prefix(1)), passed: false, city: place.city, kind: place.kind ?? .other)
    }
}
