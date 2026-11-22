import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Apple's place search stand-in (F-15b §41): a table by name, every result with its country code; text and around
/// both answer from the table, and 「酒店」 around a point returns a hotel there when `hotels` is on.
final class FakeApple: PlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let hotels: Bool
    let asked = Mutex<[String]>([])
    let centers = Mutex<[GeoCoordinate]>([])
    init(_ table: [String: [Place]], hotels: Bool = false) {
        self.table = table
        self.hotels = hotels
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        return table[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        centers.withLock { $0.append(center) }
        if keywords == "酒店" {
            guard hotels else { return [] }
            return [hotelAt(center, country: "JP")]
        }
        return table[keywords] ?? []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

/// 高德 stand-in that also answers 「酒店」 around a point (at home).
final class HotelSearch: PlaceSearch, @unchecked Sendable {
    let base: TripSearch
    init(_ base: TripSearch) { self.base = base }
    func text(_ keywords: String, city: String?) async throws -> [Place] { try await base.text(keywords, city: city) }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        keywords == "酒店" ? [hotelAt(center, country: nil)] : []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

func hotelAt(_ c: GeoCoordinate, country: String?) -> Place {
    let id = "hotel@\((c.latitude * 1000).rounded() / 1000),\((c.longitude * 1000).rounded() / 1000)"
    return Place(id: id, name: "酒店\(id.suffix(7))", address: nil, coordinate: c, distanceMeters: nil, countryCode: country)
}

func jp(_ name: String, lat: Double, lng: Double = 139.8, country: String = "JP") -> Place {
    Place(id: "apple_" + name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, countryCode: country)
}

/// Tokyo-ish places on a line (seconds by latitude in `byLine`), 成田 to the east.
let tokyo: [String: [Place]] = [
    "成田机场": [jp("成田机场", lat: 35.77)],
    "浅草寺": [jp("浅草寺", lat: 35.71)], "东京晴空塔": [jp("东京晴空塔", lat: 35.70)],
    "上野公园": [jp("上野公园", lat: 35.715)], "秋叶原": [jp("秋叶原", lat: 35.698)],
    "东京塔": [jp("东京塔", lat: 35.658)], "皇居": [jp("皇居", lat: 35.685)],
    "新宿御苑": [jp("新宿御苑", lat: 35.685, lng: 139.71)], "明治神宫": [jp("明治神宫", lat: 35.676)],
    "涩谷": [jp("涩谷", lat: 35.659)], "银座": [jp("银座", lat: 35.671)],
    "台场": [jp("台场", lat: 35.62)],
    "酒店A": [jp("酒店A", lat: 35.69)], "酒店B": [jp("酒店B", lat: 35.66)],
]
let tokyoSights = ["浅草寺", "东京晴空塔", "上野公园", "秋叶原", "东京塔", "皇居", "新宿御苑", "明治神宫", "涩谷", "银座"]

func roles(_ rig: TripRig) async -> [[String]] {
    await rig.planner.currentPlan.days.map { $0.stops.map { "\($0.place.name):\($0.role.rawValue)" } }
}

func days(_ list: [[String]]) -> JSONValue { .array(list.map(names)) }

@Suite("T-040o F-15b phase 4 trips abroad, airport and hotels")
struct TripPhase4Tests {
    // MARK: §36 China or abroad

    @Test("F-15b row 86: abroad=false, 高德 finds 2 of 11, Apple 10 of 11 in JP: switched to abroad, all on Apple")
    func row86() async {
        let eleven = tokyoSights + ["台场"]
        var amap = tianjin
        amap["浅草寺"] = [spot("浅草寺", id: "amap_qian", lat: 30.1, lng: 120.1)]
        amap["东京塔"] = [spot("东京塔", id: "amap_tower", lat: 30.2, lng: 120.2)]
        var table = tokyo
        table["台场"] = nil
        let apple = FakeApple(table)
        let (rig, _) = await timesRig(search: TripSearch(amap), here: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02), abroad: apple)
        let r = await rig.run(planCall(["days": days([Array(eleven.prefix(6)), Array(eleven.dropFirst(6))])]))
        #expect(r.ok)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=apple abroad=yes switched=yes names=11 found=10") })
        #expect(await rig.planner.currentPlan.abroad)
        // The 高德 places in China are gone: every stop is Apple's.
        let all = await rig.planner.currentPlan.allStops
        // §55 item 4 (T-040zh): 台场, not found, is kept unplaced (no country).
        let codes = all.filter { $0.stop.role == .sight && $0.stop.placed }.map { $0.stop.place.countryCode }
        #expect(!codes.isEmpty && codes.allSatisfy { $0 == "JP" })
    }

    @Test("F-15b row 87: abroad=false 珠海 → 澳门 names, 高德 finds them all: no Apple search")
    func row87() async {
        var amap = tianjin
        amap["大三巴"] = [spot("大三巴牌坊", lat: 22.197, lng: 113.541)]
        amap["渔女"] = [spot("珠海渔女", lat: 22.26, lng: 113.59)]
        let apple = FakeApple(tokyo)
        let (rig, _) = await timesRig(search: TripSearch(amap), here: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02), abroad: apple)
        let r = await rig.run(planCall(["places": names(["渔女", "大三巴"])]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(apple.asked.withLock { $0 }.isEmpty)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=amap abroad=no switched=no names=2 found=2") })
    }

    // MARK: §37 start, hotels and end

    @Test("F-15b row 89: 3 days, hotels=[A,B]: night 1 = A (day 1 last, day 2 first), night 2 = B")
    func row89() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        let r = await rig.run(planCall(["days": days([["浅草寺"], ["东京塔"], ["皇居"]]), "abroad": true,
                                                      "start": "成田机场", "hotels": names(["酒店A", "酒店B"])]))
        #expect(r.ok)
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[0].last?.place.name == "酒店A" && d[1].first?.place.name == "酒店A")
        #expect(d[1].last?.place.name == "酒店B" && d[2].first?.place.name == "酒店B")
        #expect(d[2].last?.role == .sight)
    }

    @Test("F-15b §37 item 7: arriving at a night's hotel ends the day; the next morning's hotel is reached too")
    func hotelEndsDay() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(planCall(["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let d = await rig.planner.currentPlan.days
        let hotel = d[0].stops.last!.place.id
        for stop in d[0].stops { await rig.planner.arrived(stop.place.id) }
        let after = await rig.planner.currentPlan.days
        #expect(after[0].stops.allSatisfy { $0.mark == .visited })
        #expect(after[1].stops.first?.place.id == hotel && after[1].stops.first?.mark == .visited)
        let done = await rig.run(trip("trip_next", ["day": 1]))
        #expect(done.code == .dayDone)
        // F-09b §13 row 7 (T-031o): day 1 of 2 is done; the next day may be offered.
        #expect(done.advice == nil && done.data["facts"] == .object(["day": .int(1), "day_count": .int(2)]))
        #expect(done.data["may"] == .array([.string("ask_next_day")]))
    }

    @Test("F-15b §38 item 2: abroad, 高德's route fails: Apple Maps opens, trip handoff line")
    func handoff() async {
        let opened = Mutex<[String]>([])
        let apple = FakeApple(tokyo)
        let engine = ScriptedNaviEngine(routes: [])
        let service = FakeDrivingTimes(byLine)
        let rig = await TripRig(engine: engine, times: TripTimes(service: service, clock: ManualClock(), retryDelay: .milliseconds(1)),
                                here: GeoCoordinate(latitude: 35.80, longitude: 139.8, datum: .gcj02), abroad: apple,
                                handoff: { place in opened.withLock { $0.append(place.name) }; return true })
        _ = await rig.run(planCall(["places": names(["浅草寺"]), "abroad": true]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["status"] == "apple_maps")
        #expect(opened.withLock { $0 } == ["浅草寺"])
        #expect(rig.lines.withLock { $0 }.contains("trip handoff vendor=apple_maps reason=route_failed"))
    }

    @Test("F-15b §37 item 8: hotel cards say 住, airport cards 机场; §39 catalog texts")
    func cardsAndCatalog() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(planCall(["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        guard case .cards(let cards) = TripScreen.of(await rig.planner.current, moving: false) else { Issue.record("cards"); return }
        #expect(cards.first?.tag == "机场" && cards.last?.tag == "住")
        func text(_ n: String) -> String { ToolCatalog.spec(n)!.declaration.description }
        #expect(text("trip_next").hasSuffix("已在苹果地图打开=告诉司机，到了说「已经到了」。"))
    }

    @Test("F-15b §37: the frame survives the plan file (role, picked, country, abroad)")
    func fileKeepsFrame() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(planCall(["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let plan = await rig.planner.currentPlan
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.abroad == true)
        #expect(back?.days.map { $0.stops.map(\.role) } == plan.days.map { $0.stops.map(\.role) })
        #expect(back?.days[0].stops.first?.place.countryCode == "JP")
    }

    // MARK: review fixes

    @Test("F-15b §37 item 7: 「已经到了」 at the hotel by voice ends the day and marks the next morning too")
    func visitedHotelByVoice() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(planCall(["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let n = await rig.planner.current.count
        for i in 1...n { await rig.planner.markForTests(index: i, .visited, day: 1) }
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[1].first?.place.name == "酒店A" && d[1].first?.mark == .visited)
        let next = await rig.run(trip("trip_next", ["day": 2]))
        #expect(next.data["name"] == "东京塔")
    }

}
