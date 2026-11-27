import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

private let center = GeoCoordinate(latitude: 43.06, longitude: 141.35, datum: .gcj02)
private let area = TripArea(center: center, countryCode: "JP")

/// §52 item 11 stand-in for Photon with `bbox`: a name in `slow` throws `AmapWebError.slow` (out of tries) after a
/// short real delay; a name in `stalled` never answers until cancelled; a name in `late` answers after `lateSeconds`
/// on the trip clock; any other name answers at once. Lookups running at once are counted.
private final class LimitSearch: AreaPlaceSearch, @unchecked Sendable {
    let slow: Set<String>
    let stalled: Set<String>
    let late: Set<String>
    let clock: ManualClock
    let lateSeconds: Int
    let state = Mutex<(running: Int, most: Int, asked: [String], lateWaiting: Int)>((0, 0, [], 0))
    init(slow: Set<String> = [], stalled: Set<String> = [], late: Set<String> = [], clock: ManualClock, lateSeconds: Int = 5) {
        self.slow = slow
        self.stalled = stalled
        self.late = late
        self.clock = clock
        self.lateSeconds = lateSeconds
    }
    var running: Int { state.withLock { $0.running } }
    var most: Int { state.withLock { $0.most } }
    var lateWaiting: Int { state.withLock { $0.lateWaiting } }

    func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place] {
        state.withLock { s in s.running += 1; s.most = max(s.most, s.running); s.asked.append(keywords) }
        defer { state.withLock { $0.running -= 1 } }
        if slow.contains(keywords) {
            try? await Task.sleep(for: .milliseconds(30))
            throw AmapWebError.slow
        }
        if stalled.contains(keywords) {
            try await Task.sleep(for: .seconds(3600))
        }
        if late.contains(keywords) {
            state.withLock { $0.lateWaiting += 1 }
            try await clock.sleep(until: clock.now + .seconds(Int64(lateSeconds)))
        }
        let i = Double(abs(keywords.hashValue % 100)) / 10_000
        return [Place(id: "osm_" + keywords, name: keywords, address: nil,
                      coordinate: GeoCoordinate(latitude: center.latitude + i, longitude: center.longitude + i, datum: .gcj02),
                      distanceMeters: nil, countryCode: "JP")]
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { [] }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        keywords == "酒店" ? [hotelAt(center, country: "JP")] : []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

private struct LimitRig {
    let planner: TripPlanner
    let lines = TripLines()

    init(search: LimitSearch, clock: ManualClock) async {
        let lines = self.lines
        let nav = NavigationController(search: TripSearch([:]), engine: ScriptedNaviEngine(routes: [route(1, meters: 1_000, seconds: 60)]),
                                       location: NoLocation(), clock: clock)
        await nav.start()
        planner = TripPlanner(search: TripSearch([:]), navigation: nav, origin: { center }, clock: clock,
                              onLine: { lines.append($0) }, abroadSearch: search,
                              abroadCenter: { _ in center },
                              abroadTimes: TripTimes(service: FakeOsrm(fail: false), clock: ManualClock()),
                              abroadArea: { @Sendable _ in area })
    }

    /// A trip abroad (Sapporo) with one placed stop, so set_trip_plan's new names are searched abroad.
    func start() async -> String? {
        let args: [String: JSONValue] = ["places": [["name": "Base", "minutes": 60, "importance": 3]], "abroad": true,
                                         "city": "Sapporo, Japan"]
        _ = await planner.execute(planCall(args))
        return await planner.currentPlan.allStops.first?.stop.id
    }
}

private func names(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}

private func plan(_ base: String?, _ new: [String]) -> ToolCall {
    var day: [JSONValue] = base.map { [.object(["id": .string($0)])] } ?? []
    day += new.map { .object(["name": .string($0)]) }
    return trip("set_trip_plan", ["days": .array([.array(day)])])
}

private func wait(_ cond: @Sendable () -> Bool) async {
    for _ in 0..<5000 where !cond() { try? await Task.sleep(for: .milliseconds(1)) }
    try? await Task.sleep(for: .milliseconds(20))
}

@Suite("T-040zd F-15b §52 items 4 and 11 on the trip path")
struct TripPhotonLimitsTests {
    @Test("T-040zd F-15b row 204: a Photon lookup out of tries is search_slow and not_placed, tried once, never NOT_FOUND or not-found wording")
    func row204() async {
        let clock = ManualClock()
        let search = LimitSearch(slow: ["Slow Place"], clock: clock)
        let rig = await LimitRig(search: search, clock: clock)
        let base = await rig.start()
        #expect(base != nil)
        let r = await rig.planner.execute(plan(base, ["Slow Place", "Fast Place"]))
        #expect(r.ok && r.code != .notFound, "\(r)")
        let facts = r.data["facts"]
        #expect(names(facts?["search_slow"]) == ["Slow Place"])
        #expect(names(facts?["not_placed"]) == ["Slow Place"])
        #expect(names(facts?["not_found"]).isEmpty && names(r.data["not_found"]).isEmpty)
        // `slow` is not retried by the planner (each retry would rerun Photon's 12 s).
        #expect(search.state.withLock { $0.asked }.filter { $0 == "Slow Place" }.count == 1)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasSuffix("ok=no reason=slow") })
        // The reply text (advice, next) never says the place does not exist.
        let text = "\(r.data["next"] ?? "") \(r.advice ?? "")"
        #expect(!text.contains("找不到") && !text.contains("不存在") && !text.lowercased().contains("not found"))
        let stop = await rig.planner.currentPlan.allStops.first { $0.stop.asked == "Slow Place" }?.stop
        #expect(stop?.placed == false)
    }

    @Test("T-040zd F-15b row 203 (trip): 10 names, 4 stalled: each name has its own 12 s, 4 at once, no batch-wide cut; a name starting after 12 s still answers")
    func row203() async {
        let clock = ManualClock()
        let stalled = ["S1", "S2", "S3", "S4"]
        let search = LimitSearch(stalled: Set(stalled), late: ["Late"], clock: clock)
        let rig = await LimitRig(search: search, clock: clock)
        let base = await rig.start()
        let all = stalled + ["Late", "F1", "F2", "F3", "F4", "F5"]
        let made = Task { await rig.planner.execute(plan(base, all)) }
        // The 4 stalled names hold all 4 slots.
        await wait { search.running == 4 && clock.pendingSleepers >= 4 }
        #expect(search.most == 4)
        clock.advance(by: .seconds(13))
        // Their own limits pass; Late starts only now (after 12 s) and waits 5 s on the clock.
        await wait { search.lateWaiting == 1 && clock.pendingSleepers >= 2 }
        clock.advance(by: .seconds(6))
        let r = await made.value
        #expect(r.ok, "\(r)")
        #expect(search.most == 4)
        let facts = r.data["facts"]
        #expect(Set(names(facts?["not_placed"])) == Set(stalled))
        #expect(Set(names(facts?["search_slow"])) == Set(stalled))
        let placed = await rig.planner.currentPlan.allStops.map(\.stop).filter(\.placed).map(\.asked)
        // Late answered 19 s after the batch began: no 15 s budget for the whole batch.
        #expect(Set(placed).isSuperset(of: ["Late", "F1", "F2", "F3", "F4", "F5"]), "\(placed)")
    }
}

@Suite("T-040zd F-15b §52 item 11 Photon warm-up trigger")
struct PhotonWarmRuleTests {
    @Test("T-040zd §52 item 11: warm only with a trip abroad on screen (a stop, cards shown); never at home or with cards hidden")
    func rule() {
        var plan = TripPlan()
        plan.abroad = true
        #expect(!TripPlan.warmsPhoton(plan, cardsHidden: false))  // no stop yet
        var list = TripList()
        list.arrange([TripStop(index: 0, asked: "Base", place: Place(id: "osm_1", name: "Base", address: nil, coordinate: center,
                                                                      distanceMeters: nil, countryCode: "JP"),
                               distanceMeters: nil)])
        plan.write(days: [list])
        #expect(TripPlan.warmsPhoton(plan, cardsHidden: false))
        #expect(!TripPlan.warmsPhoton(plan, cardsHidden: true))
        plan.abroad = false
        #expect(!TripPlan.warmsPhoton(plan, cardsHidden: false))
    }
}
