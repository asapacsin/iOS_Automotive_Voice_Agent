import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Answers each name from a table; a name in `slow` waits until `release()`.
final class TripSearch: PlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let slow: Set<String>
    let error: AmapWebError?
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])
    let asked = Mutex<[String]>([])
    let returned = Mutex(0)

    /// The first `failFirst` text searches throw `quota` (高德's per-second limit), then it answers.
    private let failing: Mutex<Int>

    /// F-15b §49 (T-040u): what 「酒店」 around a point answers; nil = nothing.
    let hotels: (@Sendable (GeoCoordinate) -> [Place])?

    /// F-15b §54 (T-040zg): a name here answers nothing until it has been asked this many times before.
    let lateAnswer: [String: Int]

    init(_ table: [String: [Place]], slow: Set<String> = [], error: AmapWebError? = nil, failFirst: Int = 0,
         hotels: (@Sendable (GeoCoordinate) -> [Place])? = nil, lateAnswer: [String: Int] = [:]) {
        self.lateAnswer = lateAnswer
        self.hotels = hotels
        self.table = table
        self.slow = slow
        self.error = error
        self.failing = Mutex(failFirst)
    }

    var waiting: Int { held.withLock { $0.count } }
    func release() { for c in held.withLock({ c in defer { c = [] }; return c }) { c.resume() } }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        if slow.contains(keywords) { await withCheckedContinuation { c in held.withLock { $0.append(c) } } }
        if let error { throw error }
        if failing.withLock({ n in defer { n = max(n - 1, 0) }; return n > 0 }) { throw AmapWebError.quota }
        defer { returned.withLock { $0 += 1 } }
        if let n = lateAnswer[keywords], asked.withLock({ $0.filter { $0 == keywords }.count }) <= n { return [] }
        return table[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        keywords == "酒店" ? (hotels?(center) ?? []) : []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

func spot(_ name: String, id: String? = nil, lat: Double, lng: Double) -> Place {
    Place(id: id ?? name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, district: "和平区")
}

func trip(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    // F-15b §61 item 3 (T-040zn): a new plan needs `asked`; tests of earlier sections that write a new plan (with
    // `city`) get a neutral one. Tests of `asked` itself build their call with `rawTrip`.
    var a = args
    if name == "set_trip_plan", a["city"] != nil, a["asked"] == nil { a["asked"] = ["text": "测试行程"] }
    return rawTrip(name, a)
}

/// The call exactly as given (no `asked` added).
func rawTrip(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(id: CallID("t1")!, name: name, arguments: .object(args))
}

func names(_ list: [String]) -> JSONValue { .array(list.map { .string($0) }) }

/// The plan of a result (§52 item 2's JSON) as the old names-per-day form, with role and mark notes.
func planNames(_ v: JSONValue?) -> JSONValue {
    guard case .array(let days)? = v?["days"] else { return .null }
    return .array(days.map { day in
        guard case .array(let stops) = day else { return .array([]) }
        return .array(stops.map { s in
            let role = TripRole(rawValue: s["role"]?.stringValue ?? "") ?? .sight
            let mark = s["mark"]?.stringValue
            return .string((s["name"]?.stringValue ?? "") + TripPlanner.roleNote(role)
                           + (mark == "visited" ? "（已去过）" : mark == "skipped" ? "（跳过）" : ""))
        })
    })
}

/// F-15b §52 (T-040zb): a `set_trip_plan` call writing `days` by name: a name already in the plan is sent as its id,
/// any other as a new name; `roles` gives a role per name.
func planCall(_ rig: TripRig, _ days: [[String]], roles: [String: String] = [:], extra: [String: JSONValue] = [:]) async -> ToolCall {
    let plan = await rig.planner.currentPlan
    var byName: [String: String] = [:]
    for s in plan.allStops where byName[s.stop.place.name] == nil { byName[s.stop.place.name] = s.stop.id }
    let d: [JSONValue] = days.map { day in
        .array(day.map { n in
            var o: [String: JSONValue] = byName[n].map { ["id": .string($0)] } ?? ["name": .string(n)]
            if let r = roles[n] { o["role"] = .string(r) }
            return .object(o)
        })
    }
    return trip("set_trip_plan", ["days": .array(d)].merging(extra) { $1 })
}

/// Tianjin-ish stops on a line north of the origin, so nearest-next is predictable.
let origin = GeoCoordinate(latitude: 39.00, longitude: 117.20, datum: .gcj02)
let tianjin: [String: [Place]] = [
    "古文化街": [spot("古文化街", lat: 39.10, lng: 117.20)],
    "五大道": [spot("五大道", lat: 39.04, lng: 117.20)],
    "天津之眼": [spot("天津之眼", lat: 39.16, lng: 117.20)],
    "瓷房子": [spot("瓷房子", lat: 39.02, lng: 117.20)],
    "意式风情区": [spot("意式风情区", lat: 39.13, lng: 117.20)],
    "海河": [spot("海河观光", lat: 39.07, lng: 117.20)],
    "水上公园": [spot("天津水上公园", lat: 39.20, lng: 117.20)],
    "南开大学": [spot("南开大学", lat: 39.25, lng: 117.20)],
    "西开教堂": [spot("五大道", lat: 39.05, lng: 117.20)],
    "盘山": [],
    "盘山风景区": [spot("蓟州农家饭店", lat: 39.30, lng: 117.20)],
    "古文化街旅游区": [spot("古文化街", lat: 39.10, lng: 117.20)],
]

final class TripLines: Sendable {
    let all = Mutex<[String]>([])
    func withLock(_ body: (inout [String]) -> [String]) -> [String] { all.withLock { body(&$0) } }
    func append(_ line: String) { all.withLock { $0.append(line) } }
}

/// Routes at once; a start waits until `release()` (B3: the list changes while the trip starts).
final class HeldStartEngine: NaviEngine, @unchecked Sendable {
    let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation
    private let held = Mutex<(Generation, Bool)?>(nil)
    let calls = Mutex<[String]>([])
    init() { (events, continuation) = AsyncStream.makeStream() }
    var starting: Bool { held.withLock { $0 != nil } }
    func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        calls.withLock { $0.append("calculate") }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .routesReady([route(1, meters: 9_000, seconds: 900)])))
    }
    func selectRoute(_ id: RouteID, generation: Generation) async {}
    func start(_ mode: NaviMode, generation: Generation) async {
        calls.withLock { $0.append("start") }
        held.withLock { $0 = (generation, true) }
    }
    func release() {
        guard let (g, _) = held.withLock({ h in defer { h = nil }; return h }) else { return }
        continuation.yield(NaviEngineEnvelope(generation: g, event: .naviStarted))
    }
    func stop(generation: Generation) async {
        calls.withLock { $0.append("stop") }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStopped))
    }
}

/// §4 item 6: answers from a table of asked name → 0-based pick (nil = none); a name not in it gets 0. `hang` never
/// answers; `fail` throws.
final class FakePicker: PlacePicker, @unchecked Sendable {
    let answers: [String: Int?]
    let hang: Bool
    let fail: Bool
    let calls = Mutex<[[String]]>([])
    var model: String { "qwen3.8-max-0902" }
    init(_ answers: [String: Int?] = [:], hang: Bool = false, fail: Bool = false) {
        self.answers = answers
        self.hang = hang
        self.fail = fail
    }
    func pick(_ choices: [PlaceChoice]) async throws -> [Int?] {
        calls.withLock { $0.append(choices.map(\.asked)) }
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if fail { throw AmapWebError.timeout }
        return choices.map { answers[$0.asked] ?? 0 }
    }
}

struct TripRig {
    let search: TripSearch
    let engine: ScriptedNaviEngine
    let nav: NavigationController
    let planner: TripPlanner
    let lines = TripLines()

    init(search: TripSearch = TripSearch(tianjin), engine: ScriptedNaviEngine? = nil, tuning: NovaNav.NavigationTuning = NovaNav.NavigationTuning(),
         clock: any NovaClock = ManualClock(), nameLimit: NovaDuration = .seconds(12), other: (any NaviEngine)? = nil,
         picker: (any PlacePicker)? = nil, times: TripTimes? = nil, noOrigin: Bool = false,
         notes: TripLines? = nil, here: GeoCoordinate? = nil, abroad: (any PlaceSearch)? = nil,
         handoff: (@Sendable (Place) async -> Bool)? = nil,
         center: (@Sendable (String) async -> GeoCoordinate?)? = nil, abroadTimes: TripTimes? = nil,
         area: (@Sendable (String) async -> TripArea?)? = nil) async {
        self.search = search
        let engine = engine ?? ScriptedNaviEngine(routes: [route(1, meters: 156_000, seconds: 14_640, toll: 20)])
        self.engine = engine
        let lines = self.lines
        nav = NavigationController(search: search, engine: other ?? engine, location: NoLocation(), clock: clock, tuning: tuning,
                                   onTripLine: { line in lines.append(line) })
        await nav.start()
        var t = TripTuning()
        t.nameLimit = nameLimit
        let start = here ?? origin
        planner = TripPlanner(search: search, navigation: nav, origin: { noOrigin ? nil : start }, clock: clock, tuning: t,
                              picker: picker, onLine: { line in lines.append(line) }, times: times,
                              onNote: { note in notes?.append(note) }, abroadSearch: abroad, onHandoff: handoff, abroadCenter: center,
                              abroadTimes: abroadTimes, abroadArea: area)
        await planner.connectCards()
    }

    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func order() async -> [String] { await planner.current.stops.map(\.place.name) }
}

@Suite("T-040i F-15b phase 1 trip list")
struct TripPlannerTests {
    @Test("F-15b row 3 (with §55): a day of 25 stops (over 16 + 4) or a blank name is invalidFields; the list is unchanged")
    func row3() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        let many = await rig.run(planCall(["places": names((1...25).map { "地点\($0)" })]))
        #expect(many.code == .invalidFields)
        #expect(TripPlanner.validateWrite(planCall(["places": names(["古文化街", "  "])])) == .invalidFields)
        let blank = await rig.run(planCall(["places": names(["古文化街", "  "])]))
        #expect(blank.code == .invalidFields)
        #expect(await rig.order() == ["古文化街", "五大道"])
    }

    @Test("F-15b row 4 (with §52, T-040zb): a stop left out of set_trip_plan is removed, the written order kept")
    func row4() async {
        let rig = await TripRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区"])]))
        let removed = await rig.run(await planCall(rig, [["古文化街", "天津之眼", "瓷房子", "意式风情区"]]))
        #expect(removed.data["facts"]?["removed"] == names(["五大道"]), "\(removed)")
        #expect(await rig.order() == ["古文化街", "天津之眼", "瓷房子", "意式风情区"])
        #expect(await rig.run(await planCall(rig, [["意式风情区", "天津之眼", "瓷房子"]])).ok)
        #expect(await rig.order() == ["意式风情区", "天津之眼", "瓷房子"])
        #expect(await rig.planner.current.stops.map(\.index) == [1, 2, 3])
    }

    @Test("F-15b §4 (barge-in): a cancelled new plan (set_trip_plan) changes nothing")
    func cancelledMake() async {
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]))
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        let made = Task { await rig.run(planCall(["places": names(["天津之眼", "南开大学"])])) }
        for _ in 0..<2000 where rig.search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        made.cancel()
        rig.search.release()
        #expect(await made.value.code == .optionsStale)
        #expect(await rig.order() == ["古文化街", "五大道"])
    }

    @Test("F-15b §4 items 4-5 (with §52 item 11): a lookup still running at the limit is a timeout, said as search_slow; a missing key is AMAP_WEB_KEY_MISSING")
    func limits() async {
        let clock = ManualClock()
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]), clock: clock)
        let made = Task { await rig.run(planCall(["places": names(["古文化街", "南开大学"])])) }
        // The fast lookup has returned and the slow one is held; then the 15 s limit passes.
        for _ in 0..<5000 where rig.search.waiting == 0 || rig.search.returned.withLock({ $0 }) == 0 {
            try? await Task.sleep(for: .milliseconds(1))
        }
        try? await Task.sleep(for: .milliseconds(20))
        clock.advance(by: .seconds(16))
        let r = await made.value
        // §52 item 11 (T-040zd, review 2026-11-21): a lookup at its limit is search_slow, never not found.
        // §55 item 4 (T-040zh): the slow name is kept with placed=false, never in not_found.
        #expect(r.data["count"] == .int(2) && (r.data["not_found"] == nil || r.data["not_found"] == .array([])), "\(r)")
        #expect(r.data["facts"]?["search_slow"] == names(["南开大学"]) || r.data["search_slow"] == names(["南开大学"]), "\(r)")
        #expect(rig.lines.withLock { $0 }.contains("trip lookup index=2 ok=no reason=timeout"))
        rig.search.release()
        let noKey = await TripRig(search: TripSearch(tianjin, error: .keyMissing))
        #expect(await noKey.run(planCall(["places": names(["古文化街"])])).code == .amapWebKeyMissing)
    }

    @Test("F-15b §3: TripList renumbers after every change and raises its generation")
    func pure() {
        var list = TripList()
        let a = spot("A", lat: 39.1, lng: 117.2), b = spot("B", lat: 39.2, lng: 117.2), c = spot("C", lat: 39.05, lng: 117.2)
        list.replace([("A", a, nil), ("B", b, nil), ("C", c, nil)])
        #expect(list.generation == 1)
        list.arrange([list.stops[2], list.stops[0], list.stops[1]])
        #expect(list.stops.map(\.place.name) == ["C", "A", "B"] && list.stops.map(\.index) == [1, 2, 3] && list.generation == 2)
    }
}

@Suite("F-15b §4 item 6 device 2026-11-17 lookups")
struct TripLookupTests {
    static let beijing: [String: [Place]] = [
        "北京故宫": [spot("北京故宫博物院北院区(建设中)", lat: 40.05, lng: 116.2), spot("故宫博物院", lat: 39.92, lng: 116.4)],
        "陈家祠": [spot("陈家祠(地铁站)", lat: 23.13, lng: 113.24), spot("陈家祠堂", lat: 23.13, lng: 113.25)],
        "路环那家葡挞": [spot("不是葡挞", lat: 22.12, lng: 113.55), spot("路环岛", lat: 22.12, lng: 113.56)],
        "天坛": [spot("天坛公园", lat: 39.88, lng: 116.41)],
    ]

    @Test("F-15b row 40 (owner 2026-11-17): Qwen picks among 高德's results in one call; 0 is not found; no check field")
    func row40() async {
        let picker = FakePicker(["北京故宫": 1, "陈家祠": 1, "路环那家葡挞": nil])
        let rig = await TripRig(search: TripSearch(Self.beijing), picker: picker)
        let r = await rig.run(planCall(["places": names(["北京故宫", "陈家祠", "路环那家葡挞", "天坛"])]))
        // §55 item 4 (T-040zh): the name the picker found nothing for is kept with placed=false and not_found.
        #expect(r.ok && r.data["count"] == .int(4) && r.data["facts"]?["not_placed"] == names(["路环那家葡挞"]), "\(r)")
        #expect(await rig.order() == ["故宫博物院", "陈家祠堂", "路环那家葡挞", "天坛公园"])
        #expect(r.data["check"] == nil)
        #expect(picker.calls.withLock { $0 } == [["北京故宫", "陈家祠", "路环那家葡挞"]])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip pick names=3 none=1 ok=yes") })
    }

    @Test("F-15b row 45: picker fails, has no key, or never answers within 2.5 s: 高德's first result")
    func row45() async {
        for (picker, reason) in [(FakePicker(fail: true), "failed"), (nil, "nokey")] as [(FakePicker?, String)] {
            let rig = await TripRig(search: TripSearch(Self.beijing), picker: picker)
            let r = await rig.run(planCall(["places": names(["北京故宫", "陈家祠"])]))
            #expect(r.ok && r.data["count"] == .int(2))
            #expect(await rig.order() == ["北京故宫博物院北院区(建设中)", "陈家祠(地铁站)"])
            #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip pick names=2 none=0 ok=no reason=\(reason)") })
        }
        let clock = ManualClock()
        let picker = FakePicker(hang: true)
        let rig = await TripRig(search: TripSearch(Self.beijing), clock: clock, picker: picker)
        let made = Task { await rig.run(planCall(["places": names(["北京故宫", "天坛"])])) }
        while picker.calls.withLock({ $0.isEmpty }) || clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: .milliseconds(2500))
        let r = await made.value
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(await rig.order() == ["北京故宫博物院北院区(建设中)", "天坛公园"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip pick names=1 none=0 ok=no reason=timeout") })
    }

    @Test("T-040zl F-15b row 260: the picker fails (429 with no backup): every open name takes 高德's first result; the pick line says ok=no reason=failed model=qwen3.8-max-0902")
    func row260() async {
        let picker = FakePicker(fail: true)
        let rig = await TripRig(search: TripSearch(Self.beijing), picker: picker)
        let r = await rig.run(planCall(["places": names(["北京故宫", "陈家祠"])]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(await rig.order() == ["北京故宫博物院北院区(建设中)", "陈家祠(地铁站)"])
        #expect(picker.calls.withLock { $0.count } == 1)
        #expect(rig.lines.withLock { $0 }.contains { $0 == "trip pick names=2 none=0 ok=no reason=failed ms=0 model=qwen3.8-max-0902" }, "\(rig.lines.withLock { $0 })")
        let ok = await TripRig(search: TripSearch(Self.beijing), picker: FakePicker(["北京故宫": 1, "陈家祠": 1]))
        _ = await ok.run(planCall(["places": names(["北京故宫", "陈家祠"])]))
        #expect(ok.lines.withLock { $0 }.contains { $0.hasPrefix("trip pick names=2 none=0 ok=yes") && $0.hasSuffix(" model=qwen3.8-max-0902") })
    }

    @Test("F-15b row 46: a name with one result and a cached name never go to the picker")
    func row46() async {
        let picker = FakePicker()
        let rig = await TripRig(search: TripSearch(Self.beijing), picker: picker)
        _ = await rig.run(planCall(["places": names(["天坛"])]))
        #expect(picker.calls.withLock { $0 }.isEmpty)
        _ = await rig.run(planCall(["places": names(["北京故宫"])]))
        _ = await rig.run(planCall(["places": names(["北京故宫", "天坛"])]))
        #expect(picker.calls.withLock { $0 } == [["北京故宫"]])
    }

    @Test("F-15b row 49: trip_next called while a new plan (set_trip_plan) waits on 高德 runs after it, on the new list")
    func row49() async {
        let search = TripSearch(tianjin, slow: ["瓷房子"])
        let rig = await TripRig(search: search)
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        let made = Task { await rig.run(planCall(["places": names(["天津之眼", "瓷房子", "海河"])])) }
        while search.waiting == 0 { await Task.yield() }
        let routed = Task { await rig.run(trip("trip_next")) }
        while await rig.planner.waiting == 0 { await Task.yield() }
        search.release()
        let r = await made.value
        let route = await routed.value
        #expect(r.ok && r.data["count"] == .int(3))
        let firstStop = await rig.order()[0]
        #expect(route.ok && route.data["name"] == .string(firstStop) && route.data["index"] == .int(1))
    }

    @Test("F-15b row 52: a first result taken because the picker failed is not cached; the next list asks again")
    func row52() async {
        let picker = FakePicker(fail: true)
        let rig = await TripRig(search: TripSearch(Self.beijing), picker: picker)
        _ = await rig.run(planCall(["places": names(["北京故宫"])]))
        _ = await rig.run(planCall(["places": names(["北京故宫"])]))
        #expect(picker.calls.withLock { $0 }.count == 2)
    }

    @Test("F-15b row 41: two lookups refused as busy (高德 per-second limit) are tried once more and found; 2 at once")
    func busyRetried() async {
        let search = TripSearch(tianjin, failFirst: 2)
        var t = TripTuning()
        t.retryDelay = .milliseconds(10)
        #expect(TripTuning().parallelLookups == 2)
        let rig = await TripRig(search: search)
        let planner = TripPlanner(search: search, navigation: rig.nav, origin: { origin }, clock: ManualClock(), tuning: t,
                                  onLine: { line in rig.lines.append(line) })
        let r = await planner.execute(planCall(["places": names(["古文化街", "五大道", "天津之眼"])]))
        #expect(r.ok && r.data["count"] == .int(3) && r.data["not_found"] == names([]))
        // F-15b row 43: the same names again cost no lookup (cache), even with 高德 refusing everything now.
        let asked = search.asked.withLock { $0.count }
        let again = await planner.execute(planCall(["places": names(["五大道", "古文化街"])]))
        #expect(again.ok && again.data["count"] == .int(2))
        #expect(search.asked.withLock { $0.count } == asked)
    }

}

@Suite("T-040i F-15b owner 2026-11-16 no trip route during guidance")
struct TripDuringGuidanceTests {
}
