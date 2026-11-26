import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// §55 item 4 stand-in for 高德: `text` with `citylimit=true` answers only places inside the asked city; without it,
/// any place of that name (the nationwide guess §55 forbids). Every request is recorded as `name|city=…&citylimit=…`.
/// 「酒店」 around a point answers `hotels(center)`; any other name around a point answers by name.
final class CityLimitSearch: PlaceSearch, @unchecked Sendable {
    let inCity: [String: [String: [Place]]]
    let nationwide: [String: [Place]]
    let hotels: @Sendable (GeoCoordinate) -> [Place]
    let requests = Mutex<[String]>([])
    init(inCity: [String: [String: [Place]]], nationwide: [String: [Place]] = [:],
         hotels: @escaping @Sendable (GeoCoordinate) -> [Place] = { _ in [] }) {
        self.inCity = inCity
        self.nationwide = nationwide
        self.hotels = hotels
    }
    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        requests.withLock { $0.append("\(keywords)|city=\(city ?? "")&citylimit=\(cityLimit)") }
        if cityLimit { return city.flatMap { inCity[$0]?[keywords] } ?? [] }
        return city.flatMap { inCity[$0]?[keywords] } ?? nationwide[keywords] ?? []
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { try await text(keywords, city: city, cityLimit: false) }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        requests.withLock { $0.append("\(keywords)|around") }
        if keywords == "酒店" { return hotels(center) }
        return inCity.values.compactMap { $0[keywords] }.first ?? []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

private func sh(_ name: String, _ k: Int) -> Place {
    Place(id: "sh_\(name)", name: name, address: nil, coordinate: GeoCoordinate(latitude: 31.20 + Double(k) * 0.002, longitude: 121.47, datum: .gcj02),
          distanceMeters: nil, city: "上海", countryCode: "CN")
}

private let shanghaiSights = ["外滩", "豫园", "南京路", "东方明珠", "上海博物馆", "田子坊", "新天地", "武康路",
                              "静安寺", "城隍庙", "陆家嘴", "上海中心", "朱家角", "徐家汇"]
private let shTable: [String: [Place]] = {
    var t: [String: [Place]] = [:]
    for (k, n) in shanghaiSights.enumerated() { t[n] = [sh(n == "新天地" ? "上海新天地" : n, k)] }
    t["上海大酒店"] = [Place(id: "sh_hotel", name: "上海大酒店", address: nil,
                        coordinate: GeoCoordinate(latitude: 31.21, longitude: 121.47, datum: .gcj02), distanceMeters: nil,
                        countryCode: "CN", kind: .hotel)]
    return t
}()
private let beijingXintiandi = Place(id: "bj_xtd", name: "北京新天地", address: nil,
                                     coordinate: GeoCoordinate(latitude: 39.9, longitude: 116.4, datum: .gcj02), distanceMeters: nil,
                                     city: "北京", countryCode: "CN")

private func sapporoPlace(_ name: String, _ k: Int) -> Place {
    Place(id: "sp_\(name)", name: name, address: nil, coordinate: GeoCoordinate(latitude: 43.0 + Double(k) * 0.01, longitude: 141.35, datum: .gcj02),
          distanceMeters: nil, countryCode: "JP")
}

private let tokyoCentre = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02)
private let shinjukuStation = GeoCoordinate(latitude: 35.6896, longitude: 139.7006, datum: .gcj02)
private func jpPlace(_ name: String, lat: Double, lng: Double, kind: PlaceKind? = nil) -> Place {
    Place(id: "jp_\(name)", name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, countryCode: "JP", kind: kind)
}

/// A planner on `search` (at home) with an optional abroad search and area, and a driver-turn count.
private struct ModelPlanRig {
    let planner: TripPlanner
    let lines = TripLines()
    let clock = ManualClock()
    init(search: any PlaceSearch, abroad: (any PlaceSearch)? = nil, area: (@Sendable (String) async -> TripArea?)? = nil,
         turns: (@Sendable () async -> Int)? = nil, grounder: (any TripGrounder)? = nil, abroadTimes: TripTimes? = nil) async {
        let lines = self.lines
        let clock = self.clock
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { GeoCoordinate(latitude: 31.2, longitude: 121.4, datum: .gcj02) },
                              clock: clock, onLine: { lines.append($0) }, abroadSearch: abroad, abroadTimes: abroadTimes, grounder: grounder, abroadArea: area, driverTurns: turns)
        await planner.connectCards()
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

private func named(_ n: String) -> JSONValue { ["name": .string(n)] }
private func plan(_ days: [[JSONValue]], city: String? = "上海", _ extra: [String: JSONValue] = [:]) -> ToolCall {
    var a: [String: JSONValue] = ["days": .array(days.map { .array($0) })]
    if let city { a["city"] = .string(city) }
    return trip("set_trip_plan", a.merging(extra) { $1 })
}
private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}
private func issues(_ r: ToolResult) -> [String] { strings(r.data["issues"]) }

/// 14 Shanghai sights all on day 1, days 2–5 empty, no start (the phone-test call of 2026-11-22, as a written plan).
private let crammed = plan([shanghaiSights.map(named), [], [], [], []])

@Suite("T-040zh F-15b §55 the model writes every plan; code places and checks, never splits")
struct TripModelPlanTests {
    @Test("T-040zh F-15b row 229: a new plan (no ids) for 上海 while a Sapporo plan is saved replaces it; no PLAN_CHECK new_trip, no CONFIRM_CLEAR")
    func row229() async {
        var sapporo: [String: [Place]] = [:]
        for (k, n) in ["新千岁机场", "大通公园", "狸小路", "桥本酒店"].enumerated() { sapporo[n] = [sapporoPlace(n, k)] }
        let rig = await ModelPlanRig(search: CityLimitSearch(inCity: ["上海": shTable, "札幌": sapporo]))
        _ = await rig.run(plan([[named("大通公园"), named("狸小路")]], city: "札幌"))
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.asked) == ["大通公园", "狸小路"])
        let r = await rig.run(plan([[named("外滩"), named("豫园"), named("南京路")]]))
        #expect(r.ok && r.code != .planCheck && r.code != .confirmClear, "\(r)")
        #expect(r.data["facts"]?["new_trip"] == nil && r.data["facts"]?["new_plan"] == .bool(true))
        let p = await rig.planner.currentPlan
        #expect(p.allStops.map(\.stop.asked) == ["外滩", "豫园", "南京路"] && p.city == "上海")
        #expect(!rig.lines.withLock { $0 }.contains { $0.contains("check=new_trip") || $0.hasPrefix("trip clear") })
    }

    @Test("T-040zh F-15b row 230: city 上海, 新天地: 高德 asked with city=上海&citylimit=true, placed as 上海新天地; no in-city answer: placed=false and a not_found issue, never 北京新天地")
    func row230() async {
        let search = CityLimitSearch(inCity: ["上海": shTable, "杭州": [:]], nationwide: ["新天地": [beijingXintiandi]])
        let rig = await ModelPlanRig(search: search)
        let r = await rig.run(plan([[named("新天地")]]))
        #expect(r.ok, "\(r)")
        #expect(search.requests.withLock { $0 } == ["新天地|city=上海&citylimit=true"])
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.name) == ["上海新天地"])
        // Not in the city: kept unplaced, named in not_placed with the range searched (§61: no issue lines), no nationwide request.
        let other = CityLimitSearch(inCity: ["杭州": [:]], nationwide: ["新天地": [beijingXintiandi]])
        let rig2 = await ModelPlanRig(search: other)
        let r2 = await rig2.run(plan([[named("新天地"), named("西湖")]], city: "杭州"))
        let stops = await rig2.planner.currentPlan.allStops.map(\.stop)
        #expect(stops.map(\.place.name) == ["新天地", "西湖"] && stops.allSatisfy { !$0.placed })
        #expect(issues(r2).isEmpty && r2.data["facts"]?["not_placed_range"] == "杭州", "\(r2)")
        #expect(strings(r2.data["facts"]?["not_placed"]) == ["新天地", "西湖"])
        // F-15b §71 item 3 (T-040zx): a miss is tried once with no city; 北京新天地 is not in the trip's city, so not kept.
        #expect(other.requests.withLock { $0 }.filter { !$0.hasSuffix("|city=杭州&citylimit=true") }.allSatisfy { $0.hasSuffix("|city=&citylimit=false") })
        #expect(!"\(r2.data)".contains("北京新天地"))
    }

    @Test("T-040zh F-15b row 231: a new plan without city is refused (city missing; §56 row 241: INVALID_FIELDS); nothing saved")
    func row231() async {
        let rig = await ModelPlanRig(search: CityLimitSearch(inCity: ["上海": shTable]))
        _ = await rig.run(plan([[named("外滩")]]))
        let before = await rig.planner.currentPlan
        let r = await rig.run(plan([[named("豫园"), named("南京路")]], city: nil))
        #expect(!r.ok && r.code == .invalidFields && strings(r.data["problems"]).contains(TripPlanner.cityMissing), "\(r)")
        #expect(TripPlanner.cityMissing == "新行程要写 city（城市，跨城市就写省或地区）")
        let after = await rig.planner.currentPlan
        #expect(after.revision == before.revision && after.allStops.map(\.stop.asked) == ["外滩"])
        // The schema takes city; a kept plan needs none (its city is kept).
        #expect(TripPlanner.validateWrite(plan([[named("豫园")]], city: "")) == .invalidFields)
    }

    @Test("T-040zh F-15b row 232: {role: hotel, near: 新宿站} on nights 1–2: one hotel near 新宿站 picked by the app for both nights; a night with no hotel gets a hotel issue")
    func row232() async {
        let table: [String: [Place]] = [
            "新宿站": [jpPlace("新宿站", lat: shinjukuStation.latitude, lng: shinjukuStation.longitude)],
            "浅草寺": [jpPlace("浅草寺", lat: 35.7148, lng: 139.7967)],
            "东京塔": [jpPlace("东京塔", lat: 35.6586, lng: 139.7454)],
            "明治神宫": [jpPlace("明治神宫", lat: 35.6764, lng: 139.6993)],
        ]
        let photon = CityLimitSearch(inCity: ["Tokyo": table], hotels: { c in
            [jpPlace("新宿王子酒店", lat: c.latitude + 0.002, lng: c.longitude, kind: .hotel),
             jpPlace("远一点的酒店", lat: c.latitude + 0.005, lng: c.longitude, kind: .hotel)]
        })
        let rig = await ModelPlanRig(search: CityLimitSearch(inCity: [:]), abroad: photon,
                                     area: { _ in TripArea(center: tokyoCentre, countryCode: "JP") })
        let near: JSONValue = ["role": "hotel", "near": "新宿站"]
        let r = await rig.run(plan([[named("浅草寺"), near], [near, named("东京塔"), near],
                                    [near, named("明治神宫")]], city: "Tokyo, Japan"))
        #expect(r.ok, "\(r)")
        let p = await rig.planner.currentPlan
        #expect(p.abroad, "\(rig.lines.withLock { $0 })")
        let hotels = p.allStops.map(\.stop).filter { $0.role == .hotel }
        #expect(hotels.count == 4 && Set(hotels.map(\.id)).count == 1 && hotels.allSatisfy { $0.pickedBy == .app && $0.place.name == "新宿王子酒店" }, "\(rig.lines.withLock { $0 }) \(photon.requests.withLock { $0 })")
        #expect(issues(r).isEmpty, "\(issues(r))")
        #expect(stopsOfPlan(r).joined().contains { $0["picked_by"] == "app" && $0["role"] == "hotel" })
        // Night 2 without a hotel stop: saved as written (§61: no hotel issue; check_trip_plan shows it); the app does not fill it.
        let r2 = await rig.run(plan([[named("浅草寺"), near], [near, named("东京塔")],
                                     [named("明治神宫")]], city: "Tokyo, Japan"))
        #expect(r2.ok && issues(r2).isEmpty, "\(r2)")
        #expect(await rig.planner.currentPlan.days[1].stops.last?.role == .sight)
        // near is only for a hotel; §56 item 1 (T-040zi): beside a name, name wins and near is ignored.
        #expect(TripPlanner.validateWrite(plan([[["near": "新宿站"]]])) == .invalidFields)
        #expect(TripPlanner.validateWrite(plan([[["name": "X", "role": "hotel", "near": "新宿站"]]])) == nil)
        #expect(TripPlanner.validateWrite(plan([[named("A"), near], [near, named("B")]])) == nil)
    }

}

private func stopsOfPlan(_ r: ToolResult) -> [[JSONValue]] {
    guard case .array(let days)? = r.data["plan"]?["days"] else { return [] }
    return days.map { if case .array(let s) = $0 { s } else { [] } }
}

private let groundTable: [String: [Place]] = [
    "Senso-ji": [jpPlace("浅草寺", lat: 35.7148, lng: 139.7967, kind: .temple)],
    "Tokyo Tower": [jpPlace("东京塔", lat: 35.6586, lng: 139.7454)],
    "新宿站": [jpPlace("新宿駅", lat: shinjukuStation.latitude, lng: shinjukuStation.longitude)],
    "Shinjuku Washington Hotel": [jpPlace("新宿华盛顿酒店", lat: shinjukuStation.latitude + 0.003, lng: shinjukuStation.longitude, kind: .hotel)],
]
private let groundAnswer = TripGroundAnswer(places: [
    TripGroundPlace(name: "浅草寺", english: "Senso-ji", minutes: 60, importance: 3),
    TripGroundPlace(name: "东京塔", english: "Tokyo Tower", minutes: 60, importance: 2),
    TripGroundPlace(name: "明治神宫", english: "Meiji Jingu", minutes: 60, importance: 2),
], hotels: [TripGroundHotel(night: 1, name: "新宿华盛顿酒店", english: "Shinjuku Washington Hotel")], area: "Tokyo")

private func groundRig(_ grounder: FakeGrounder) async -> ModelPlanRig {
    let photon = FakeAreaSearch(groundTable) { c in [jpPlace("车站旁的酒店", lat: c.latitude + 0.006, lng: c.longitude, kind: .hotel)] }
    return await ModelPlanRig(search: CityLimitSearch(inCity: [:]), abroad: photon,
                              area: { _ in TripArea(center: tokyoCentre, countryCode: "JP") }, grounder: grounder)
}
private let tokyoTwoDays = plan([[named("浅草寺"), ["role": "hotel", "near": "新宿站"]], [["role": "hotel", "near": "新宿站"], named("东京塔")]],
                                city: "Tokyo, Japan")

@Suite("T-040zh F-15b §55 item 4 with §50: grounding, timing and the country guard on a written plan abroad")
struct TripModelPlanAbroadTests {
    @Test("T-040zh F-15b §55 item 4 (old row 140): abroad new plan: Qwen grounds the written names (searched with english), its hotel is tried first for near; places it adds are not put in the plan")
    func grounded() async {
        let grounder = FakeGrounder(groundAnswer)
        let rig = await groundRig(grounder)
        let r = await rig.run(tokyoTwoDays)
        #expect(r.ok, "\(r)")
        let request = grounder.calls.withLock { $0 }.first
        #expect(request?.city == "Tokyo, Japan" && request?.days == 2 && request?.places.map(\.name) == ["浅草寺", "东京塔"]
                && request?.hotelNear == "新宿站")
        let p = await rig.planner.currentPlan
        #expect(p.days.map { $0.stops.filter { $0.role == .sight }.map(\.place.name) } == [["浅草寺"], ["东京塔"]])
        // Only the english names are in this map: both sights placed means Qwen's english was searched.
        #expect(p.allStops.filter { $0.stop.role == .sight }.allSatisfy { $0.stop.placed })
        #expect(p.days[0].stops.last?.place.name == "新宿华盛顿酒店" && p.days[0].stops.last?.pickedBy == .app)
        #expect(rig.line("trip ground vendor=qwen places=3 hotels=1 kept3=1 added=0 ok=yes ms=").count == 1, "\(rig.lines.withLock { $0 })")
    }

    @Test("T-040zh F-15b §55 item 4 (old row 141): Qwen never answers: after the ground timeout the written names are searched as they are; ok=fallback")
    func groundTimeout() async {
        let hanging = FakeGrounder(hang: true)
        let rig = await groundRig(hanging)
        let made = Task { await rig.run(tokyoTwoDays) }
        while hanging.calls.withLock({ $0.isEmpty }) || rig.clock.pendingSleepers == 0 { await Task.yield() }
        rig.clock.advance(by: .seconds(30))
        let r = await made.value
        #expect(r.ok)
        // The written names are searched as they are (this map knows only the english ones): kept unplaced.
        let sights = await rig.planner.currentPlan.allStops.map(\.stop).filter { $0.role == .sight }
        #expect(sights.map(\.asked) == ["浅草寺", "东京塔"] && sights.allSatisfy { !$0.placed })
        #expect(rig.line("trip ground vendor=qwen places=2 hotels=0 kept3=2 added=0 ok=fallback reason=timeout ms=").count == 1,
                "\(rig.lines.withLock { $0 })")
        // At home Qwen is not asked.
        let home = FakeGrounder(groundAnswer)
        let homeRig = await ModelPlanRig(search: CityLimitSearch(inCity: ["上海": shTable]), grounder: home)
        _ = await homeRig.run(plan([[named("外滩")]]))
        #expect(home.calls.withLock { $0 }.isEmpty)
    }

    @Test("T-040zh F-15b §36 item 3 (old row 85): a written plan abroad: a CN result for a name is never used; a name with only CN results is kept unplaced with not_found")
    func countryGuard() async {
        var table = tokyo
        table["迪士尼"] = [jp("上海迪士尼", lat: 31.14, lng: 121.66, country: "CN"), jp("东京迪士尼", lat: 35.63)]
        table["只在中国"] = [jp("某地", lat: 31.2, lng: 121.4, country: "CN")]
        let (rig, _) = await timesRig(here: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02), abroad: FakeApple(table),
                                      area: { _ in TripArea(center: GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02), countryCode: "JP") })
        let r = await rig.run(planCall(["places": names(["迪士尼", "浅草寺", "只在中国"]), "abroad": true]))
        let stops = await rig.planner.current.stops
        #expect(stops.contains { $0.place.name == "东京迪士尼" } && !stops.contains { $0.place.name == "上海迪士尼" || $0.place.name == "某地" })
        #expect(stops.first { $0.asked == "只在中国" }?.placed == false)
        #expect(r.data["issues"] == nil && strings(r.data["facts"]?["not_placed"]).contains("只在中国"), "\(r)")
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip lookup index=3 ok=no reason=") && ($0.hasSuffix("country") || $0.hasSuffix("area")) })
    }

    @Test("T-040zh F-15b §55 item 2 (review): a city whose country is known (上海, CN) never switches the trip abroad: no worldwide probe even when 高德 finds little")
    func knownCountryNoProbe() async {
        let photon = CityLimitSearch(inCity: ["any": ["外滩": [jpPlace("Gaitan", lat: 35.7, lng: 139.7)], "豫园": [jpPlace("Yoen", lat: 35.7, lng: 139.7)]]])
        let rig = await ModelPlanRig(search: CityLimitSearch(inCity: ["上海": [:]]), abroad: photon,
                                     area: { _ in TripArea(center: GeoCoordinate(latitude: 31.23, longitude: 121.47, datum: .gcj02), countryCode: "CN") })
        _ = await rig.run(plan([[named("外滩"), named("豫园")]]))
        #expect(photon.requests.withLock { $0 }.isEmpty)
        #expect(await !rig.planner.currentPlan.abroad)
        #expect(rig.line("trip search vendor=amap abroad=no switched=no ").count == 1)
    }
}

/// F-15b §60 (T-040zm): a search that runs `probe` before each name lookup (to look at the work panel mid-call).
private final class ProbeSearch: PlaceSearch, @unchecked Sendable {
    let base: CityLimitSearch
    let probe: @Sendable () -> Void
    init(_ base: CityLimitSearch, probe: @escaping @Sendable () -> Void) {
        self.base = base
        self.probe = probe
    }
    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        probe()
        return try await base.text(keywords, city: city, cityLimit: cityLimit)
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { try await text(keywords, city: city, cityLimit: false) }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await base.around(keywords, center: center, radiusMeters: radiusMeters, sort: sort)
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

@Suite("T-040zm F-15b §60 the trip work panel is on only while a set_trip_plan call runs")
struct TripWorkPanelTests {
    @Test("T-040zm F-15b row 265: the trip screen going off turns a showing trip panel off at once; a search panel stays")
    func row265() {
        let clock = ManualClock()
        let board = WorkProgressBoard(clock: clock)
        board.start(.trip, step: WorkProgress.tripEdit)
        clock.advance(by: .milliseconds(1_500))
        #expect(board.panel != nil)
        board.tripScreen(on: true)
        #expect(board.panel != nil)
        board.tripScreen(on: false)
        #expect(board.panel == nil)
        board.start(.search, step: WorkProgress.searchTitle(tool: "web_search", kind: nil))
        clock.advance(by: .milliseconds(1_500))
        board.tripScreen(on: false)
        #expect(board.panel?.kind == .search)
    }

    @Test("T-040zm F-15b row 266 (§60 items 2, 5; §61 item 5 words): 行程已更新 3 s, 没保存 5 s, then off; a long trip write is never hidden by the 120 s limit")
    func row266() {
        let clock = ManualClock()
        let board = WorkProgressBoard(clock: clock)
        board.start(.trip, step: WorkProgress.tripEdit)
        board.finish(WorkProgress.tripUpdated, failed: false)
        clock.advance(by: .milliseconds(2_900))
        #expect(board.panel?.steps.last?.title == "行程已更新")
        clock.advance(by: .milliseconds(200))
        #expect(board.panel == nil)
        board.start(.trip, step: WorkProgress.tripEdit)
        board.finish(WorkProgress.tripNotSaved("x"), failed: true)
        clock.advance(by: .milliseconds(4_900))
        #expect(board.panel?.steps.last?.title == "没保存：x")
        clock.advance(by: .milliseconds(200))
        #expect(board.panel == nil)
        board.start(.trip, step: WorkProgress.tripEdit)
        clock.advance(by: .seconds(130))
        #expect(board.panel != nil)
        board.start(.search, step: "正在搜索…")
        clock.advance(by: .seconds(130))
        #expect(board.panel == nil)
    }
}
