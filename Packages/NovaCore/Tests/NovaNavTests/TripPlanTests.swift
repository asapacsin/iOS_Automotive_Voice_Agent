import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// `Application Support/trip/` in memory.
final class MemoryTripFiles: TripFiles, @unchecked Sendable {
    let files = Mutex<[String: Data]>([:])
    let writes = Mutex(0)
    func read(_ name: String) -> Data? { files.withLock { $0[name] } }
    func write(_ name: String, _ data: Data) {
        files.withLock { $0[name] = data }
        writes.withLock { $0 += 1 }
    }
    func moveAside(_ name: String) {
        files.withLock { f in
            f[name.replacingOccurrences(of: ".json", with: ".bad.json")] = f[name]
            f[name] = nil
        }
    }
}

struct PlanRig {
    let search: TripSearch
    let engine: ScriptedNaviEngine
    let nav: NavigationController
    let planner: TripPlanner
    let files: MemoryTripFiles
    let lines = TripLines()

    init(files: MemoryTripFiles = MemoryTripFiles(), clock: ManualClock = ManualClock()) async {
        search = TripSearch(tianjin)
        engine = ScriptedNaviEngine(routes: [route(1, meters: 30_000, seconds: 3_600)])
        self.files = files
        let lines = self.lines
        nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: clock,
                                   onTripLine: { lines.append($0) })
        await nav.start()
        let start = Date(timeIntervalSince1970: 1_000_000)
        let tick = Mutex(0.0)
        planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: clock, files: files,
                              now: { tick.withLock { $0 += 60; return start.addingTimeInterval($0) } },
                              onLine: { lines.append($0) })
    }

    func run(_ name: String, _ args: [String: JSONValue]) async -> ToolResult { await planner.execute(trip(name, args)) }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
}

@Suite("T-040l F-15b phase 2b saved plans and days")
struct TripPlanTests {
    @Test("F-15b row 26: a changed plan comes back from the file in a new controller: same days and stops, no lookups, no trip stop driven")
    func row26() async {
        let files = MemoryTripFiles()
        let first = await PlanRig(files: files)
        _ = await first.run(planCall(["days": [names(["古文化街", "五大道"]), names(["天津之眼", "瓷房子", "海河"])]]))
        _ = await first.planner.tap(.day(2), moving: false)
        _ = await first.planner.tap(.remove(index: 3), moving: false)

        let second = await PlanRig(files: files)
        await second.planner.restore()
        let plan = await second.planner.currentPlan
        #expect(plan.dayCount == 2 && plan.currentDay == 2)
        #expect(plan.days.map { $0.stops.map(\.place.name) } == [["古文化街", "五大道"], ["天津之眼", "瓷房子"]])
        #expect(second.search.asked.withLock { $0 }.isEmpty)
        let flow = await second.nav.current
        #expect(flow.tripStopID == nil)
        #expect(second.lines.withLock { $0 }.contains("trip load ok=yes days=2 stops=4 hidden=yes"))
    }

    @Test("F-15b row 27: an unreadable current.json starts empty, logs trip load ok=no and is moved to current.bad.json")
    func row27() async {
        let files = MemoryTripFiles()
        files.write("current.json", Data("{not json".utf8))
        let rig = await PlanRig(files: files)
        await rig.planner.restore()
        #expect(await rig.planner.currentPlan.isEmpty)
        #expect(rig.lines.withLock { $0 }.contains("trip load ok=no days=1 stops=0 hidden=no"))
        #expect(files.read("current.json") == nil && files.read("current.bad.json") == Data("{not json".utf8))
        // An unknown version is not read either.
        let v2 = MemoryTripFiles()
        v2.write("current.json", Data(#"{"version":2,"plan":{"currentDay":1,"days":[]}}"#.utf8))
        let other = await PlanRig(files: v2)
        await other.planner.restore()
        #expect(other.lines.withLock { $0 }.contains { $0.hasPrefix("trip load ok=no") })
    }

    @Test("F-15b row 28: no place names in the trip lines or the files' log lines")
    func row28() async {
        let rig = await PlanRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道", "盘山"])]))
        _ = await rig.run("trip_next", [:])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        _ = await rig.planner.tap(.remove(index: 1), moving: false)
        let lines = rig.lines.withLock { $0 }
        #expect(!lines.isEmpty)
        for name in ["古文化街", "五大道", "盘山", "天津", "瓷房子"] {
            #expect(lines.allSatisfy { !$0.contains(name) }, "\(name) in \(lines)")
        }
    }

    @Test("F-15b row 32: save, list, open by containment, rename, delete; the plan lines")
    func row32() async {
        let rig = await PlanRig()
        _ = await rig.run(planCall(["places": names(["古文化街", "五大道"])]))
        let saved = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        #expect(saved.ok && saved.data["replaced"] == false)
        #expect(await rig.run("trip_plans", ["action": "save", "name": "天津一日游"]).data["replaced"] == true)
        _ = await rig.run(planCall(["places": names(["天津之眼"])]))
        _ = await rig.run("trip_plans", ["action": "save", "name": "海河夜景"])
        let list = await rig.run("trip_plans", ["action": "list"])
        #expect(list.data["count"] == .int(2))
        guard case .array(let plans)? = list.data["plans"] else { Issue.record("plans"); return }
        #expect(plans.compactMap { $0["name"]?.stringValue } == ["海河夜景", "天津一日游"])
        let opened = await rig.run("trip_plans", ["action": "open", "name": "天津"])
        #expect(opened.ok && opened.data["name"] == "天津一日游" && opened.data["kept_previous"] == false)
        #expect(await rig.planner.current.stops.map(\.place.name) == ["古文化街", "五大道"])
        #expect(await rig.run("trip_plans", ["action": "rename", "name": "天津一日游", "new_name": "周末出游"]).ok)
        #expect(await rig.planner.currentPlan.name == "周末出游")
        #expect(await rig.run("trip_plans", ["action": "delete", "name": "周末出游"]).ok)
        #expect(await rig.run("trip_plans", ["action": "open", "name": "周末出游"]).code == .planNotFound)
        #expect(await rig.planner.current.count == 2)
        #expect(rig.lines.withLock { $0 }.contains("trip plan action=save ok=yes days=1 stops=2"))
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "save"])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "list", "name": "x"])) == .invalidFields)
        #expect(ToolCatalog.validate(trip("trip_plans", ["action": "save", "name": .string(String(repeating: "长", count: 21))])) == .invalidFields)
        // The saved plans survive a restart.
        let again = await PlanRig(files: rig.files)
        await again.planner.restore()
        #expect(await again.planner.savedPlans.entries.map(\.name) == ["海河夜景"])
    }

    @Test("F-15b row 33: an unnamed plan with stops is kept as 上一个清单 when another plan is opened, and can be opened again")
    func row33() async {
        let rig = await PlanRig()
        _ = await rig.run(planCall(["places": names(["古文化街"])]))
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津一日游"])
        _ = await rig.run(planCall(["places": names(["天津之眼", "瓷房子"])]))
        let opened = await rig.run("trip_plans", ["action": "open", "name": "天津一日游"])
        #expect(opened.data["kept_previous"] == true && opened.data["facts"]?["previous_kept_as"] == "上一个清单")
        #expect(await rig.run("trip_plans", ["action": "open", "name": "上一个清单"]).ok)
        #expect(await rig.planner.current.stops.map(\.place.name) == ["天津之眼", "瓷房子"])
    }

    @Test("F-15b row 34: a new name with 20 saved is PLANS_FULL (the same name still saves); two names containing it are AMBIGUOUS; save on an empty plan is NO_TRIP_LIST")
    func row34() async {
        let rig = await PlanRig()
        #expect(await rig.run("trip_plans", ["action": "save", "name": "空"]).code == .noTripList)
        _ = await rig.run(planCall(["places": names(["古文化街"])]))
        for i in 1...20 { _ = await rig.run("trip_plans", ["action": "save", "name": .string("行程\(i)")]) }
        let full = await rig.run("trip_plans", ["action": "save", "name": "第二十一个"])
        #expect(full.code == .plansFull)
        // F-09b §13 row 7 (T-031o): the limit is a fact.
        #expect(full.data["facts"] == .object(["max_plans": .int(20)]))
        #expect(full.data["must_not"] == .array([.string("claim_done"), .string("invent")]))
        #expect(await rig.run("trip_plans", ["action": "save", "name": "行程3"]).ok)
        #expect(await rig.run("trip_plans", ["action": "open", "name": "行程1"]).ok)
        _ = await rig.run("trip_plans", ["action": "delete", "name": "行程10"])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津东"])
        _ = await rig.run("trip_plans", ["action": "delete", "name": "行程11"])
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津西"])
        #expect(await rig.run("trip_plans", ["action": "open", "name": "天津"]).code == .ambiguous)
    }

    @Test("F-15b §11 item 5: a day tab shows that day; open from 我的行程 sends the open note; while moving both are refused")
    func taps() async {
        let rig = await PlanRig()
        _ = await rig.run(planCall(["places": names(["古文化街"]), "day": 1]))
        _ = await rig.run(planCall(["places": names(["五大道"]), "day": 2]))
        _ = await rig.run("trip_plans", ["action": "save", "name": "天津两日游"])
        let day = await rig.planner.tap(.day(1), moving: false)
        let current = await rig.planner.currentPlan.currentDay
        #expect(day.result.ok && day.note == nil && current == 1)
        #expect(await rig.planner.tap(.openPlan("天津两日游"), moving: true).result.code == .notWhileMoving)
        let open = await rig.planner.tap(.openPlan("天津两日游"), moving: false)
        #expect(open.note == "[系统] 司机在屏幕上打开了行程「天津两日游」，现在清单有1个地点。这句不用回答。")
        #expect(rig.lines.withLock { $0 }.contains("trip tap action=open ok=yes"))
        #expect(await rig.planner.tap(.deletePlan("天津两日游"), moving: false).result.ok)
        #expect(await rig.planner.savedPlans.entries.isEmpty)
    }
}

/// Detail calls held until `release()`, counted per place.
final class HeldPhotoSearch: PlaceSearch, @unchecked Sendable {
    let details = Mutex<[String]>([])
    private let held = Mutex<[CheckedContinuation<Void, Never>]>([])
    /// After `release()` no call is held (lookups run `parallelLookups` at a time, so some start after it).
    private let holding: Mutex<Bool>
    init(hold: Bool) { holding = Mutex(hold) }
    var waiting: Int { held.withLock { $0.count } }
    func release() {
        holding.withLock { $0 = false }
        for c in held.withLock({ h in defer { h = [] }; return h }) { c.resume() }
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { tianjin[keywords] ?? [] }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? {
        details.withLock { $0.append(id) }
        if holding.withLock({ $0 }) {
            await withCheckedContinuation { c in
                held.withLock { h in
                    if holding.withLock({ $0 }) { h.append(c) } else { c.resume() }
                }
            }
        }
        return spot(id, lat: 0, lng: 0).with(photoURL: URL(string: "https://a.cn/\(id.unicodeScalars.first!.value).jpg"))
    }
}

@Suite("T-040j T-040l F-15b review fixes")
struct TripReviewFixTests {
    func rig(_ search: HeldPhotoSearch) async -> (NavigationController, TripPlanner, ScriptedNaviEngine, TripLines) {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 20_000, seconds: 1_800)])
        let lines = TripLines()
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        let planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: ManualClock(),
                                  onLine: { lines.append($0) })
        return (nav, planner, engine, lines)
    }

    @Test("F-15b §12: a reorder of stops with known photos sends the list with the links; a change while lookups run asks nobody again")
    func photosOnScreen() async {
        let search = HeldPhotoSearch(hold: true)
        let seen = Mutex<[TripList]>([])
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 20_000, seconds: 1_800)])
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock())
        await nav.start()
        let planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: ManualClock(),
                                  onChange: { list in seen.withLock { $0.append(list) } })
        _ = await planner.execute(planCall(["places": names(["古文化街", "五大道", "瓷房子"])]))
        for _ in 0..<2000 where search.waiting < TripTuning().parallelLookups { try? await Task.sleep(for: .milliseconds(1)) }
        _ = await planner.tap(.move(from: 3, to: 1), moving: false)
        search.release()
        await planner.photosSettled()
        #expect(search.details.withLock { $0 }.count == 3)
        _ = await planner.execute(planCall(["places": names(["五大道", "古文化街"])]))
        let last = seen.withLock { $0.last }
        #expect(last?.stops.allSatisfy { $0.place.photoURL != nil } == true)
        #expect(search.details.withLock { $0 }.count == 3)
    }

    @Test("F-15b §14 item 4: an unreadable plans.json logs trip load ok=no")
    func badPlans() async {
        let files = MemoryTripFiles()
        files.write("plans.json", Data("[".utf8))
        let rig = await PlanRig(files: files)
        await rig.planner.restore()
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip load ok=no") })
        #expect(files.read("plans.bad.json") != nil)
    }

}

@Suite("T-040l F-15b review fixes 2")
struct TripReviewFix2Tests {
}
