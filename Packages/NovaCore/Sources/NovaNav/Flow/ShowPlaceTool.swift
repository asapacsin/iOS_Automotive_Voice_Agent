import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-09b §16 item 8 (T-031za), §18 (T-031zc): `show_place(name, city)`. She finds the place (which name, which city);
/// code only looks up exactly that: 1 find the place, 2 get the content, 3 show the card, 4 return the result. A place
/// on screen is used as before; else 高德 text search limited to her city (the car's city when `city` is empty), no
/// nationwide fallback, no first-result pick. Exactly one result with that name in that city opens the card; anything
/// else goes back to her as `PLACE_UNSURE` with what 高德 found. Done only when the App says the card holds that place
/// (I-1). The log gets codes and counts only (I-8):
/// `show place ok=<yes|no> via=<screen|city|near> sure=<yes|no> found=<n> ms=`.
public struct ShowPlaceTool: ToolExecutor {
    public static let tool = "show_place"
    /// §18 item 4: at most this many 高德 results go back to her in `found`.
    public static let maxFound = 5
    /// §18 item 4: the `next` of `PLACE_UNSURE` (and item 5: of a failed search).
    public static let unsureNext = "卡片没有打开。看 found：有司机要的那个就用它的名字和城市再调用 show_place；没有就先用 web_search 查这个地方在哪个城市、正式名字是什么，再调用。不要道歉了事，不要说功能异常。"

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

    public enum Via: String, Sendable { case screen, city, near }

    private let finder: PlaceFinder
    private let present: @Sendable (TripCard) async -> Shown
    private let clock: any NovaClock
    private let onLine: @Sendable (String) -> Void

    /// `onScreen`: the places on screen (candidate list, chosen or guided destination, trip stops). `cityCode`: the
    /// car's city adcode, nil when unknown (used only when `city` is empty). `present`: opens the card and answers
    /// after the intro arrived or failed.
    public init(onScreen: @escaping @Sendable () async -> [Place], search: any PlaceSearch,
                cityCode: @escaping @Sendable () async -> String? = { nil },
                present: @escaping @Sendable (TripCard) async -> Shown, clock: any NovaClock,
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        finder = PlaceFinder(onScreen: onScreen, search: search, cityCode: cityCode)
        self.present = present
        self.clock = clock
        self.onLine = onLine
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let started = clock.now
        let name = (call.arguments["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let city = (call.arguments["city"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let searchVia: Via = city.isEmpty ? .near : .city
        guard !name.isEmpty else {
            log(ok: false, via: searchVia, sure: false, found: 0, since: started)
            return ToolReply.failure(.invalidFieldValue, facts: ["shown": false], may: [.askPlace],
                                     mustNot: [.claimDone, .invent]).result
        }
        // Step 1: find the place (F-09b §19 item 2: the one lookup `show_on_map` shares).
        let place: Place
        let via: Via
        let foundCount: Int
        switch await finder.find(name: name, city: city, next: Self.unsureNext) {
        case .notSure(let result, let v, let found):
            log(ok: false, via: v, sure: false, found: found, since: started)
            return result
        case .sure(let p, let v, let found):
            (place, via, foundCount) = (p, v, found)
        }
        // Steps 2 and 3: the App fills and opens the card.
        let shown = await present(Self.card(for: place))
        log(ok: shown.shown, via: via, sure: true, found: foundCount, since: started)
        // §18 item 6: the result names the card's place and city.
        let cardCity: JSONValue = (place.city ?? (city.isEmpty ? nil : city)).map { .string($0) } ?? .null
        // Step 4: return the result.
        guard shown.shown else {
            return ToolReply.notDone(.placeNotShown, facts: ["shown": false, "name": .string(place.name),
                                                             "city": cardCity],
                                     may: [.tryLater], mustNot: [.invent]).result
        }
        var facts: [String: JSONValue] = ["shown": true, "name": .string(place.name), "city": cardCity,
                                          "intro": shown.intro.map { .string($0) } ?? .null]
        if let address = shown.address ?? place.address { facts["address"] = .string(address) }
        return ToolReply.success(facts: facts, mustNot: [.invent]).result
    }

    /// Every outcome writes one line, codes and counts only (I-8).
    private func log(ok: Bool, via: Via, sure: Bool, found: Int, since started: NovaInstant) {
        let ms = max(0, Int((clock.now - started).milliseconds))
        onLine("show place ok=\(ok ? "yes" : "no") via=\(via.rawValue) sure=\(sure ? "yes" : "no") found=\(found) ms=\(ms)")
    }

    /// §18 item 3: the one result whose name equals `name` (spaces, case, a trailing bracket branch ignored) and
    /// whose city is `city` (nil: the car's city search, any city). Nil when none or several.
    static func sureMatch(_ results: [Place], name: String, city: String?) -> Place? {
        let asked = sameName(name)
        guard !asked.isEmpty else { return nil }
        // A name with its branch (she calls again with a name from `found`) is compared whole: 「星巴克(大元路店)」
        // matches only that branch, never 「星巴克(万达店)」.
        let whole = wholeName(name)
        let branched = whole != asked
        let hits = results.filter { place in
            guard branched ? wholeName(place.name) == whole : sameName(place.name) == asked else { return false }
            guard let city else { return true }
            return place.city.map { sameCity($0) == sameCity(city) } ?? false
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Name compared whole: lowercased, no spaces, full-width brackets as ASCII.
    static func wholeName(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace }.map { $0 == "（" ? "(" : $0 == "）" ? ")" : $0 })
    }

    /// Name compared: lowercased, no spaces, a trailing 「(…)」 or 「（…）」 branch removed.
    static func sameName(_ s: String) -> String {
        var t = s.lowercased().filter { !$0.isWhitespace }
        if t.hasSuffix(")") || t.hasSuffix("）"),
           let open = t.lastIndex(where: { $0 == "(" || $0 == "（" }), open != t.startIndex {
            t = String(t[..<open])
        }
        return t
    }

    /// City compared: no spaces, a trailing 「市」 removed (高德 `cityname` 清远市 is her 清远).
    static func sameCity(_ s: String) -> String {
        var t = s.filter { !$0.isWhitespace }
        if t.hasSuffix("市"), t.count > 1 { t.removeLast() }
        return t
    }

    /// §18 item 4: no card; `asked`, up to five `found` and the fixed `next`.
    static func unsure(name: String, city: String, found: [Place], next: String = unsureNext) -> ToolResult {
        let list: [JSONValue] = found.prefix(maxFound).map { p in
            .object(["name": .string(p.name), "city": p.city.map { .string($0) } ?? .null,
                     "district": p.district.map { .string($0) } ?? .null,
                     "address": p.address.map { .string($0) } ?? .null])
        }
        let facts: [String: JSONValue] = ["shown": false,
                                          "asked": .object(["name": .string(name), "city": .string(city)]),
                                          "found": .array(list)]
        return withNext(ToolReply.failure(.placeUnsure, facts: facts, mustNot: [.claimDone]).result, next)
    }

    /// §18 items 4–5: the `next` she reads is the fixed sentence (call again, or check with web_search first).
    static func withNext(_ result: ToolResult, _ next: String = unsureNext) -> ToolResult {
        var data = result.data
        data["next"] = .string(next)
        return ToolResult(ok: result.ok, code: result.code, data: data, advice: result.advice)
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

/// F-09b §18 items 2–5, §19 item 2 (T-031zd): the one lookup `show_place` and `show_on_map` share. A place on screen
/// with that name; else 高德 text search limited to `city` (the car's city when empty), no nationwide fallback, no
/// first-result pick; exactly one exact name+city match is sure. Anything else is the `notSure` result she gets back
/// (`PLACE_UNSURE` with `asked` and `found`, or the failed search's cause), with the tool's own `next`.
public struct PlaceFinder: Sendable {
    public enum Outcome: Sendable {
        case sure(Place, ShowPlaceTool.Via, found: Int)
        case notSure(ToolResult, ShowPlaceTool.Via, found: Int)
    }

    private let onScreen: @Sendable () async -> [Place]
    private let search: any PlaceSearch
    private let cityCode: @Sendable () async -> String?

    public init(onScreen: @escaping @Sendable () async -> [Place], search: any PlaceSearch,
                cityCode: @escaping @Sendable () async -> String?) {
        self.onScreen = onScreen
        self.search = search
        self.cityCode = cityCode
    }

    public func find(name: String, city: String, next: String) async -> Outcome {
        if let match = await onScreen().first(where: { ShowPlaceTool.matches($0.name, name) }) {
            return .sure(match, .screen, found: 0)
        }
        let via: ShowPlaceTool.Via = city.isEmpty ? .near : .city
        var searchCity = city
        if city.isEmpty {
            guard let car = await cityCode(), !car.isEmpty else {
                return .notSure(ShowPlaceTool.withNext(LookupReply.failed(.noLocation, what: "place", cause: .noLocation,
                                                                          facts: ["shown": false], mustNot: [.claimDone]), next),
                                via, found: 0)
            }
            searchCity = car
        }
        let results: [Place]
        do {
            results = try await search.text(name, city: searchCity, cityLimit: true)
        } catch let error as AmapWebError {
            let cause = LookupReply.cause(of: error)
            return .notSure(ShowPlaceTool.withNext(LookupReply.failed(LookupReply.code(for: cause), what: "place", cause: cause,
                                                                      facts: ["shown": false], mustNot: [.claimDone]), next),
                            via, found: 0)
        } catch {
            return .notSure(ShowPlaceTool.withNext(LookupReply.failed(.liveInfoUnavailable, what: "place", cause: .network,
                                                                      facts: ["shown": false], mustNot: [.claimDone]), next),
                            via, found: 0)
        }
        guard let sure = ShowPlaceTool.sureMatch(results, name: name, city: city.isEmpty ? nil : city) else {
            return .notSure(ShowPlaceTool.unsure(name: name, city: city, found: results, next: next), via, found: results.count)
        }
        return .sure(sure, via, found: results.count)
    }
}
