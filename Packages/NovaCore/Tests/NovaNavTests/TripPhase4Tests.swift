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

    @Test("F-15b row 84: abroad=true with 3 names: every lookup on Apple, none on 高德; trip search vendor=apple")
    func row84() async {
        let apple = FakeApple(tokyo)
        let (rig, _) = await timesRig(here: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02), abroad: apple)
        let r = await rig.run(trip("make_trip_list", ["places": names(["浅草寺", "东京塔", "皇居"]), "abroad": true]))
        #expect(r.ok && r.data["count"] == .int(3))
        #expect(rig.search.asked.withLock { $0 }.isEmpty)
        #expect(apple.asked.withLock { $0 }.sorted() == ["浅草寺", "东京塔", "皇居"].sorted())
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=apple abroad=yes switched=no names=3 found=3 country_dropped=0 ms=") })
        #expect(await rig.planner.currentPlan.abroad)
    }

    @Test("F-15b row 84a (2026-11-18): abroad with a city centre: no city → invalidFields, no lookup; with city every name searched around the centre")
    func row84a() async {
        let apple = FakeApple(tokyo)
        let centre = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02)
        let asked = Mutex<[String]>([])
        let (rig, _) = await timesRig(here: GeoCoordinate(latitude: 22.27, longitude: 113.58, datum: .gcj02), abroad: apple,
                                      center: { city in asked.withLock { $0.append(city) }; return centre })
        let bad = await rig.run(trip("make_trip_list", ["places": names(["浅草寺", "东京塔"]), "abroad": true]))
        #expect(bad.code == .invalidFields)
        #expect(apple.asked.withLock { $0 }.isEmpty)
        let r = await rig.run(trip("make_trip_list", ["places": names(["浅草寺", "东京塔"]), "abroad": true, "city": "Tokyo, Japan"]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(asked.withLock { $0 } == ["Tokyo, Japan"])
        #expect(apple.centers.withLock { $0 }.count == 2 && apple.centers.withLock { $0 }.allSatisfy { $0 == centre })
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=apple abroad=yes") && $0.hasSuffix("center=yes") })
    }

    @Test("F-15b row 85: abroad=true, a CN and a JP result for one name: the CN one dropped, the JP one kept")
    func row85() async {
        var table = tokyo
        table["迪士尼"] = [jp("上海迪士尼", lat: 31.14, lng: 121.66, country: "CN"), jp("东京迪士尼", lat: 35.63)]
        table["只在中国"] = [jp("某地", lat: 31.2, lng: 121.4, country: "CN")]
        let (rig, _) = await timesRig(here: GeoCoordinate(latitude: 35.7, longitude: 139.8, datum: .gcj02), abroad: FakeApple(table))
        let r = await rig.run(trip("make_trip_list", ["places": names(["迪士尼", "浅草寺", "只在中国"]), "abroad": true]))
        #expect(r.ok && r.data["not_found"] == names(["只在中国"]))
        #expect(await rig.planner.current.stops.contains { $0.place.name == "东京迪士尼" })
        #expect(await !rig.planner.current.stops.contains { $0.place.name == "上海迪士尼" })
        #expect(rig.lines.withLock { $0 }.contains("trip lookup index=3 ok=no reason=country"))
        #expect(rig.lines.withLock { $0 }.contains { $0.contains("country_dropped=2") })
    }

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
        let r = await rig.run(trip("make_trip_list", ["days": days([Array(eleven.prefix(6)), Array(eleven.dropFirst(6))])]))
        #expect(r.ok)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=apple abroad=yes switched=yes names=11 found=10") })
        #expect(await rig.planner.currentPlan.abroad)
        // The 高德 places in China are gone: every stop is Apple's.
        let all = await rig.planner.currentPlan.allStops
        let codes = all.filter { $0.stop.role == .sight }.map { $0.stop.place.countryCode }
        #expect(!codes.isEmpty && codes.allSatisfy { $0 == "JP" })
    }

    @Test("F-15b row 87: abroad=false 珠海 → 澳门 names, 高德 finds them all: no Apple search")
    func row87() async {
        var amap = tianjin
        amap["大三巴"] = [spot("大三巴牌坊", lat: 22.197, lng: 113.541)]
        amap["渔女"] = [spot("珠海渔女", lat: 22.26, lng: 113.59)]
        let apple = FakeApple(tokyo)
        let (rig, _) = await timesRig(search: TripSearch(amap), here: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02), abroad: apple)
        let r = await rig.run(trip("make_trip_list", ["places": names(["渔女", "大三巴"])]))
        #expect(r.ok && r.data["count"] == .int(2))
        #expect(apple.asked.withLock { $0 }.isEmpty)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=amap abroad=no switched=no names=2 found=2") })
    }

    // MARK: §37 start, hotels and end

    @Test("F-15b row 88: start=end=成田, hotels=[A], 5 days of 10 sights: 成田 → A, A → A ×3, A → 成田, every sight once")
    func row88() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        let groups = stride(from: 0, to: 10, by: 2).map { Array(tokyoSights[$0..<($0 + 2)]) }
        let r = await rig.run(trip("make_trip_list", ["days": days(groups), "abroad": true, "start": "成田机场",
                                                      "end": "成田机场", "hotels": names(["酒店A"])]))
        #expect(r.ok)
        let plan = await rig.planner.currentPlan
        #expect(plan.dayCount == 5)
        let d = plan.days.map { $0.stops }
        #expect(d[0].first?.place.name == "成田机场" && d[0].first?.role == .start && d[0].last?.place.name == "酒店A")
        for k in 1...3 { #expect(d[k].first?.place.name == "酒店A" && d[k].last?.place.name == "酒店A") }
        #expect(d[4].first?.place.name == "酒店A" && d[4].last?.place.name == "成田机场" && d[4].last?.role == .end)
        let sights = plan.allStops.filter { $0.stop.role == .sight }.map(\.stop.place.name)
        #expect(sights.sorted() == tokyoSights.sorted())
        #expect(rig.lines.withLock { $0 }.contains("trip frame start=named end=named hotels=named nights=4 picked=0"))
        // No position near Tokyo was needed: the start is 成田.
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip order ok=yes") && $0.contains("start=named") })
    }

    @Test("F-15b row 89: 3 days, hotels=[A,B]: night 1 = A (day 1 last, day 2 first), night 2 = B")
    func row89() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        let r = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"], ["皇居"]]), "abroad": true,
                                                      "start": "成田机场", "hotels": names(["酒店A", "酒店B"])]))
        #expect(r.ok)
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[0].last?.place.name == "酒店A" && d[1].first?.place.name == "酒店A")
        #expect(d[1].last?.place.name == "酒店B" && d[2].first?.place.name == "酒店B")
        #expect(d[2].last?.role == .sight)
    }

    @Test("F-15b row 90: hotels with 3 names on a 3-day trip is invalidFields")
    func row90() async {
        let call = trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"], ["皇居"]]), "hotels": names(["酒店A", "酒店B", "酒店C"])])
        #expect(ToolCatalog.validate(call) == .invalidFields)
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        #expect(await rig.run(call).code == .invalidFields)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"], ["皇居"]]),
                                                             "hotels": names(["酒店A", "酒店B"])])) == nil)
    }

    @Test("F-15b row 91: 3 days, no hotels, a hotel within 3 km: two picked, picked: true, days fixed between them")
    func row91() async {
        let (rig, _) = await timesRig(search: TripSearch(tianjin), abroad: FakeApple(tokyo, hotels: true))
        let r = await rig.run(trip("make_trip_list", ["days": days([["浅草寺", "上野公园"], ["东京塔", "皇居"], ["涩谷", "银座"]]),
                                                      "abroad": true, "start": "成田机场"]))
        #expect(r.ok)
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d.count == 3)
        #expect(d[0].last?.role == .hotel && d[0].last?.picked == true && d[1].first?.place.id == d[0].last?.place.id)
        #expect(d[1].last?.role == .hotel && d[2].first?.place.id == d[1].last?.place.id)
        #expect(rig.lines.withLock { $0 }.contains("trip frame start=named end=none hotels=picked nights=2 picked=2"))
        guard case .array(let stops)? = r.data["stops"] else { Issue.record("stops"); return }
        #expect(stops.contains { $0["picked"] == .bool(true) } || d[0].last?.picked == true)
    }

    @Test("F-15b row 91 at home: a multi-day trip with no hotel near the night says so in next")
    func row91NoHotel() async {
        let (rig, _) = await timesRig()
        let r = await settle(rig, await rig.run(trip("make_trip_list", ["days": days([["古文化街"], ["五大道"]])])))
        #expect(r.ok && (r.data["next"]?.stringValue ?? "").contains("第1晚附近没找到酒店"))
        #expect(rig.lines.withLock { $0 }.contains("trip frame start=here end=none hotels=none nights=1 picked=0"))
    }

    @Test("F-15b row 92: no start, phone 2,500 km from every sight: NO_START, plan unordered, no /v3/distance request")
    func row92() async {
        let (rig, service) = await timesRig(here: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02), abroad: FakeApple(tokyo))
        let r = await rig.run(trip("make_trip_list", ["places": names(["东京塔", "浅草寺", "皇居"]), "abroad": true]))
        #expect(r.ok && r.data["order"] == "NO_START")
        #expect((r.data["next"]?.stringValue ?? "").contains("从哪里出发？机场还是酒店？"))
        #expect(service.requests.withLock { $0 } == 0)
        #expect(await rig.order() == ["东京塔", "浅草寺", "皇居"])
    }

    @Test("F-15b row 93: no start, phone 20 km from a sight: ordered from here as phase 3")
    func row93() async {
        let (rig, service) = await timesRig(here: GeoCoordinate(latitude: 35.80, longitude: 139.8, datum: .gcj02), abroad: FakeApple(tokyo))
        let r = await rig.run(trip("make_trip_list", ["places": names(["东京塔", "浅草寺", "皇居"]), "abroad": true]))
        #expect(r.ok && r.data["order"] == nil)
        #expect(service.requests.withLock { $0 } > 0)
        #expect(await rig.order() == ["浅草寺", "皇居", "东京塔"])
    }

    @Test("F-15b row 94: NO_START, then reorganize start=成田机场 (not in the plan): one search, role start, ordered from it")
    func row94() async {
        let apple = FakeApple(tokyo)
        let (rig, _) = await timesRig(here: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02), abroad: apple)
        _ = await rig.run(trip("make_trip_list", ["places": names(["东京塔", "浅草寺", "皇居"]), "abroad": true]))
        let before = apple.asked.withLock { $0.count }
        let r = await rig.run(trip("edit_trip_list", ["action": "reorganize", "start": "成田机场"]))
        #expect(r.ok)
        #expect(apple.asked.withLock { $0.count } == before + 1)
        let stops = await rig.planner.current.stops
        #expect(stops.first?.place.name == "成田机场" && stops.first?.role == .start)
        #expect(stops.dropFirst().map(\.place.name) == ["浅草寺", "皇居", "东京塔"])
    }

    @Test("F-15b §37 item 7: arriving at a night's hotel ends the day; the next morning's hotel is reached too")
    func hotelEndsDay() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let d = await rig.planner.currentPlan.days
        let hotel = d[0].stops.last!.place.id
        for stop in d[0].stops { await rig.planner.arrived(stop.place.id) }
        let after = await rig.planner.currentPlan.days
        #expect(after[0].stops.allSatisfy { $0.mark == .visited })
        #expect(after[1].stops.first?.place.id == hotel && after[1].stops.first?.mark == .visited)
        #expect(await rig.run(trip("trip_next", ["day": 1])).code == .dayDone)
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
        _ = await rig.run(trip("make_trip_list", ["places": names(["浅草寺"]), "abroad": true]))
        let r = await rig.run(trip("trip_next"))
        #expect(r.ok && r.data["status"] == "apple_maps")
        #expect(opened.withLock { $0 } == ["浅草寺"])
        #expect(rig.lines.withLock { $0 }.contains("trip handoff vendor=apple_maps reason=route_failed"))
    }

    @Test("F-15b §37 item 8: hotel cards say 住, airport cards 机场; §39 catalog texts")
    func cardsAndCatalog() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        guard case .cards(let cards) = TripScreen.of(await rig.planner.current, moving: false) else { Issue.record("cards"); return }
        #expect(cards.first?.tag == "机场" && cards.last?.tag == "住")
        func text(_ n: String) -> String { ToolCatalog.spec(n)!.declaration.description }
        #expect(text("make_trip_list").contains("行程在中国以外（不含港澳台）时填 abroad=true，并且 city 一定要填英文城市名加国家，比如 \"Tokyo, Japan\"；地名（包括 start、end、hotels）都写成「中文名 (英文名)」，比如「浅草寺 (Senso-ji)」「成田机场 (Narita International Airport)」。司机说了从哪里出发、在哪里结束就填 start、end（比如机场）；说了住哪里就填 hotels（一个=每晚都住这家，或每晚一个）；没说酒店就不填，会自动挑。没说起点就不填。NO_START=问司机从哪里出发。"))
        #expect(text("edit_trip_list").hasSuffix("司机回答从哪里出发→reorganize 填 start。"))
        #expect(text("trip_next").hasSuffix("已在苹果地图打开=告诉司机，到了说「已经到了」。"))
    }

    @Test("F-15b §37: the frame survives the plan file (role, picked, country, abroad)")
    func fileKeepsFrame() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let plan = await rig.planner.currentPlan
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.abroad == true)
        #expect(back?.days.map { $0.stops.map(\.role) } == plan.days.map { $0.stops.map(\.role) })
        #expect(back?.days[0].stops.first?.place.countryCode == "JP")
    }

    // MARK: review fixes

    @Test("F-15b §37 item 4: replace a night's hotel: role kept, not picked, both copies of the night changed")
    func replaceHotel() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo, hotels: true))
        _ = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"]]), "abroad": true, "start": "成田机场"]))
        let n = await rig.planner.current.count
        #expect(await rig.planner.current.stops.last?.picked == true)
        let r = await rig.run(trip("edit_trip_list", ["action": "replace", "index": .int(Int64(n)), "name": "酒店B", "day": 1]))
        #expect(r.ok)
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[0].last?.place.name == "酒店B" && d[0].last?.role == .hotel && d[0].last?.picked == false)
        #expect(d[1].first?.place.name == "酒店B" && d[1].first?.role == .hotel)
    }

    @Test("F-15b §37 item 7: 「已经到了」 at the hotel by voice ends the day and marks the next morning too")
    func visitedHotelByVoice() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        _ = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"]]), "abroad": true,
                                                  "start": "成田机场", "hotels": names(["酒店A"])]))
        let n = await rig.planner.current.count
        for i in 1...n { _ = await rig.run(trip("edit_trip_list", ["action": "visited", "index": .int(Int64(i)), "day": 1])) }
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[1].first?.place.name == "酒店A" && d[1].first?.mark == .visited)
        let next = await rig.run(trip("trip_next", ["day": 2]))
        #expect(next.data["name"] == "东京塔")
    }

    @Test("F-15b §37 item 1: hotels=[A,B] with B not found: night 2 has no hotel (A is not used every night)")
    func partlyFoundHotels() async {
        let (rig, _) = await timesRig(abroad: FakeApple(tokyo))
        let r = await rig.run(trip("make_trip_list", ["days": days([["浅草寺"], ["东京塔"], ["皇居"]]), "abroad": true,
                                                      "start": "成田机场", "hotels": names(["酒店A", "没有这家"])]))
        #expect(r.ok && r.data["not_found"] == names(["没有这家"]))
        let d: [[TripStop]] = await rig.planner.currentPlan.days.map { $0.stops }
        #expect(d[0].last?.place.name == "酒店A" && d[1].first?.place.name == "酒店A")
        #expect(d[1].last?.role == .sight && d[2].first?.role == .sight)
    }
}
