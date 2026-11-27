import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-09b §19 item 3 (T-031zd): the one pin on the main map and its small card (name, 「<district>，距离 N 公里」, ×).
public struct MapPin: Sendable, Hashable {
    public let name: String
    /// 高德's coordinate, GCJ-02 like the routes.
    public let coordinate: GeoCoordinate
    public let district: String?
    /// Straight-line distance from the car, rounded to whole km; nil when the car position is unknown.
    public let distanceKm: Int?

    public init(name: String, coordinate: GeoCoordinate, district: String?, distanceKm: Int?) {
        self.name = name
        self.coordinate = coordinate
        self.district = district
        self.distanceKm = distanceKm
    }

    /// Item 3: the card's second line: 「<district>，距离 N 公里」, either part left out when unknown.
    public var detail: String {
        [district, distanceKm.map { "距离 \($0) 公里" }].compactMap { $0 }.joined(separator: "，")
    }

    /// Item 5: opening the pin closes these sheets over the map, so the map is seen.
    public static let sheetsClosedOnShow: [ScreenPanel] = [.tripDetail, .tripPlans]

    /// Item 5: the pin kept through a navigation-flow change; a `navigate_to` that opens the destination list takes
    /// it away (a route being picked or guidance does not).
    public static func kept(_ pin: MapPin?, after flow: NavigationFlowState) -> MapPin? {
        MapPresentation(flow).list == .places ? nil : pin
    }

    /// Item 3: straight-line distance rounded to whole km.
    public static func km(from car: GeoCoordinate?, to point: GeoCoordinate) -> Int? {
        car.map { Int((SelfPosition.distanceMeters($0, point) / 1000).rounded()) }
    }
}

/// F-09b §19 (T-031zd): `show_on_map(name, city)` puts one place on the map for the driver to see. Looking is not
/// going: it never plans, offers or starts a route (no route port is reached from here). The place is found by the
/// §18 lookup shared with `show_place` (`PlaceFinder`); nothing is pinned while unsure. Done only when the App says
/// the pin is drawn (I-1). Record: `show map ok=<yes|no> via=<screen|city|near> sure=<yes|no> found=<n> km=<n|none> ms=`.
public struct ShowOnMapTool: ToolExecutor {
    public static let tool = "show_on_map"
    /// §19 item 2: §18 item 4's `next` with 「卡片」 read as 「地图」.
    public static let unsureNext = "地图上没有标出来。看 found：有司机要的那个就用它的名字和城市再调用 show_on_map；没有就先用 web_search 查这个地方在哪个城市、正式名字是什么，再调用。不要道歉了事，不要说功能异常。"
    /// §19 item 6: the `next` of a sure result.
    public static let shownNext = "地图上已经标出这个地方，没有开始导航。用一两句话说它在哪、离这里多远；司机说要去，再用 navigate_to。"

    private let finder: PlaceFinder
    private let car: @Sendable () async -> GeoCoordinate?
    private let pin: @Sendable (MapPin) async -> Bool
    private let clock: any NovaClock
    private let onLine: @Sendable (String) -> Void

    /// `car`: the car's position (nil when unknown). `pin`: draws the pin (replacing any earlier one) and answers true
    /// once the pin's view reports `mapPin` on.
    public init(onScreen: @escaping @Sendable () async -> [Place], search: any PlaceSearch,
                cityCode: @escaping @Sendable () async -> String? = { nil },
                car: @escaping @Sendable () async -> GeoCoordinate? = { nil },
                pin: @escaping @Sendable (MapPin) async -> Bool, clock: any NovaClock,
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        finder = PlaceFinder(onScreen: onScreen, search: search, cityCode: cityCode)
        self.car = car
        self.pin = pin
        self.clock = clock
        self.onLine = onLine
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let started = clock.now
        let name = (call.arguments["name"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let city = (call.arguments["city"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            log(ok: false, via: city.isEmpty ? .near : .city, sure: false, found: 0, km: nil, since: started)
            return ToolReply.failure(.invalidFieldValue, facts: ["shown": false], may: [.askPlace],
                                     mustNot: [.claimDone, .invent]).result
        }
        let place: Place, via: ShowPlaceTool.Via, found: Int
        switch await finder.find(name: name, city: city, next: Self.unsureNext) {
        case .notSure(let result, let v, let n):
            log(ok: false, via: v, sure: false, found: n, km: nil, since: started)
            return result
        case .sure(let p, let v, let n):
            (place, via, found) = (p, v, n)
        }
        let km = MapPin.km(from: await car(), to: place.coordinate)
        let shown = await pin(MapPin(name: place.name, coordinate: place.coordinate, district: place.district, distanceKm: km))
        log(ok: shown, via: via, sure: true, found: found, km: km, since: started)
        let placeCity: JSONValue = (place.city ?? (city.isEmpty ? nil : city)).map { .string($0) } ?? .null
        guard shown else {
            return ToolReply.notDone(.placeNotShown, facts: ["shown": false, "name": .string(place.name), "city": placeCity],
                                     may: [.tryLater], mustNot: [.invent, .claimStarted]).result
        }
        // §19 item 6.
        var facts: [String: JSONValue] = ["shown": true, "name": .string(place.name), "city": placeCity,
                                          "district": place.district.map { .string($0) } ?? .null,
                                          "address": place.address.map { .string($0) } ?? .null]
        if let km { facts["distance_km"] = .int(Int64(km)) }
        let ok = ToolReply.success(facts: facts, mustNot: [.claimStarted]).result
        var data = ok.data
        data["next"] = .string(Self.shownNext)
        return ToolResult(ok: ok.ok, code: ok.code, data: data, advice: ok.advice)
    }

    private func log(ok: Bool, via: ShowPlaceTool.Via, sure: Bool, found: Int, km: Int?, since started: NovaInstant) {
        let ms = max(0, Int((clock.now - started).milliseconds))
        onLine("show map ok=\(ok ? "yes" : "no") via=\(via.rawValue) sure=\(sure ? "yes" : "no") found=\(found) km=\(km.map(String.init) ?? "none") ms=\(ms)")
    }
}
