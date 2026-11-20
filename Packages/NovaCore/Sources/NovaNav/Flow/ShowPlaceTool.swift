import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-09b §16 item 8 (T-031za): `show_place` opens the place card (photo, address, hours, 「介绍」) for a place on screen
/// or a named one, and hands her the introduction. Done only when the App says the card holds that place (I-1).
/// The log gets codes only (I-8): `show place ok=<yes|no> via=<index|name|search> intro=<yes|no> ms=`.
public struct ShowPlaceTool: ToolExecutor {
    public static let tool = "show_place"

    /// What the App reports after opening the card.
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

    private let onScreen: @Sendable () async -> [Place]
    private let search: any PlaceSearch
    private let present: @Sendable (TripCard) async -> Shown
    private let clock: any NovaClock
    private let onLine: @Sendable (String) -> Void

    /// `onScreen`: the places on screen in their shown numbers (§16 item 8). `present`: opens the card and answers
    /// after the introduction arrived or failed.
    public init(onScreen: @escaping @Sendable () async -> [Place], search: any PlaceSearch,
                present: @escaping @Sendable (TripCard) async -> Shown, clock: any NovaClock,
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.onScreen = onScreen
        self.search = search
        self.present = present
        self.clock = clock
        self.onLine = onLine
    }

    enum Via: String { case index, name, search }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let started = clock.now
        let places = await onScreen()
        let place: Place
        let via: Via
        if let raw = call.arguments["index"]?.intValue {
            let index = Int(raw)
            guard index >= 1, index <= places.count else {
                return ToolReply.failure(.outOfRange, facts: ["shown": false, "on_screen": .int(Int64(places.count))],
                                         may: places.isEmpty ? [.askPlace] : [.askPick],
                                         mustNot: [.claimDone, .invent]).result
            }
            place = places[index - 1]
            via = .index
        } else {
            let name = (call.arguments["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                return ToolReply.failure(.invalidFieldValue, facts: ["shown": false], may: [.askPlace],
                                         mustNot: [.claimDone, .invent]).result
            }
            let matches = places.filter { Self.matches($0.name, name) }
            if matches.count == 1 {
                place = matches[0]
                via = .name
            } else if matches.count > 1 {
                return ToolReply.failure(.ambiguous, facts: ["shown": false, "names": .array(matches.map { .string($0.name) })],
                                         may: [.askPick], mustNot: [.claimDone, .invent]).result
            } else {
                let found: [Place]
                do {
                    found = try await search.text(name, city: nil)
                } catch let error as AmapWebError {
                    let cause = LookupReply.cause(of: error)
                    return LookupReply.failed(LookupReply.code(for: cause), what: "place", cause: cause,
                                              facts: ["shown": false], mustNot: [.claimDone])
                } catch {
                    return LookupReply.failed(.liveInfoUnavailable, what: "place", cause: .network,
                                              facts: ["shown": false], mustNot: [.claimDone])
                }
                guard let first = found.first else {
                    return LookupReply.notFound(.noCandidates, what: name, facts: ["shown": false], may: [.askPlace],
                                                mustNot: [.claimDone])
                }
                place = first
                via = .search
            }
        }
        let shown = await present(Self.card(for: place))
        let ms = max(0, Int((clock.now - started).milliseconds))
        onLine("show place ok=\(shown.shown ? "yes" : "no") via=\(via.rawValue) intro=\(shown.intro == nil ? "no" : "yes") ms=\(ms)")
        guard shown.shown else {
            return ToolReply.notDone(.placeNotShown, facts: ["shown": false, "name": .string(place.name)],
                                     may: [.tryLater], mustNot: [.invent]).result
        }
        var facts: [String: JSONValue] = ["shown": true, "name": .string(place.name),
                                          "intro": shown.intro.map { .string($0) } ?? .null]
        if let address = shown.address ?? place.address { facts["address"] = .string(address) }
        return ToolReply.success(facts: facts, mustNot: [.invent]).result
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
