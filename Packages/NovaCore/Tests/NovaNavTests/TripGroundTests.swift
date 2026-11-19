import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// §50 item 1 stand-in for Qwen `ground`: a fixed answer, an error, or never answering.
final class FakeGrounder: TripGrounder, @unchecked Sendable {
    let answer: TripGroundAnswer?
    let error: TripGroundError?
    let hang: Bool
    let calls = Mutex<[TripGroundRequest]>([])
    init(_ answer: TripGroundAnswer? = nil, error: TripGroundError? = nil, hang: Bool = false) {
        self.answer = answer
        self.error = error
        self.hang = hang
    }
    func ground(_ request: TripGroundRequest) async throws -> TripGroundAnswer {
        calls.withLock { $0.append(request) }
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if let error { throw error }
        return answer!
    }
}

/// §50 item 3 stand-in for Photon with `bbox`: each asked name answers the table entry whose key it contains (longest
/// key first); 「酒店」 around a point answers `hotels`. Boxes and limits asked are recorded.
final class FakeAreaSearch: AreaPlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let hotels: @Sendable (GeoCoordinate) -> [Place]
    let boxes = Mutex<[(GeoBox, Int)]>([])
    init(_ table: [String: [Place]], hotels: @escaping @Sendable (GeoCoordinate) -> [Place] = { [hotelAt($0, country: "JP")] }) {
        self.table = table
        self.hotels = hotels
    }
    private func find(_ keywords: String) -> [Place] {
        table.keys.sorted { $0.count > $1.count }.first { keywords.contains($0) }.flatMap { table[$0] } ?? []
    }
    func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place] {
        boxes.withLock { $0.append((box, limit)) }
        return Array(find(keywords).prefix(limit))
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { find(keywords) }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        keywords == "酒店" ? hotels(center) : find(keywords)
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

private let tokyoCenter = GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02)
private let tokyoArea = TripArea(center: tokyoCenter, countryCode: "JP")
private let shinjuku = GeoCoordinate(latitude: 35.6896, longitude: 139.7006, datum: .gcj02)

private func place(_ name: String, lat: Double, lng: Double, country: String = "JP", kind: PlaceKind? = nil) -> Place {
    Place(id: "osm_" + name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: lng, datum: .gcj02),
          distanceMeters: nil, countryCode: country, kind: kind)
}

private let areaTable: [String: [Place]] = [
    "Senso-ji": [place("浅草寺", lat: 35.7148, lng: 139.7967, kind: .temple)],
    "浅草寺": [place("浅草寺", lat: 35.7148, lng: 139.7967, kind: .temple)],
    "Tokyo Tower": [place("东京塔", lat: 35.6586, lng: 139.7454)],
    "东京塔": [place("东京塔", lat: 35.6586, lng: 139.7454)],
    "Meiji Jingu": [place("明治神宫", lat: 35.6764, lng: 139.6993)],
    "上野公园": [place("上野公园", lat: 35.7156, lng: 139.7745)],
    "Shinjuku Station": [place("新宿駅", lat: shinjuku.latitude, lng: shinjuku.longitude, kind: .other)],
    "新宿附近車站": [place("新宿附近車站", lat: 35.69, lng: 139.70, kind: .other)],
    // Row 144: India, Taiwan, and Japan 60 km from the centre.
    "车站": [place("車站", lat: 20.0, lng: 78.0, country: "IN"), place("車站", lat: 25.05, lng: 121.5, country: "TW"),
            place("車站", lat: 35.68 + 0.54, lng: 139.76)],
    // Row 145: two Japanese results inside the box.
    "银座": [place("銀座", lat: 35.671, lng: 139.765), place("銀座一丁目", lat: 35.674, lng: 139.767)],
]

private func item(_ name: String, _ minutes: Int, _ importance: Int = 3) -> JSONValue {
    ["name": .string(name), "minutes": .int(Int64(minutes)), "importance": .int(Int64(importance))]
}
private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}

private struct GroundRig {
    let planner: TripPlanner
    let lines = TripLines()
    let clock = ManualClock()

    init(search: any PlaceSearch = FakeAreaSearch(areaTable), grounder: (any TripGrounder)? = nil, picker: (any PlacePicker)? = nil,
         area: Bool = true, osrmFails: Bool = false) async {
        let lines = self.lines
        let nav = NavigationController(search: TripSearch([:]), engine: ScriptedNaviEngine(routes: [route(1, meters: 1_000, seconds: 60)]),
                                       location: NoLocation(), clock: clock)
        await nav.start()
        planner = TripPlanner(search: TripSearch([:]), navigation: nav, origin: { tokyoCenter }, clock: clock, picker: picker,
                              onLine: { lines.append($0) }, abroadSearch: search,
                              abroadCenter: { _ in tokyoCenter },
                              abroadTimes: TripTimes(service: FakeOsrm(fail: osrmFails), clock: ManualClock()),
                              grounder: grounder, abroadArea: area ? { @Sendable _ in tokyoArea } : nil)
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func line(_ prefix: String) -> String? { lines.withLock { $0 }.first { $0.hasPrefix(prefix) } }
}

private let groundAnswer = TripGroundAnswer(places: [
    TripGroundPlace(name: "浅草寺", english: "Senso-ji", minutes: 60, importance: 3),
    TripGroundPlace(name: "东京塔", english: "Tokyo Tower", minutes: 60, importance: 2),
    TripGroundPlace(name: "明治神宫", english: "Meiji Jingu", minutes: 60, importance: 2),
], hotels: [TripGroundHotel(night: 1, name: "新宿华盛顿酒店", english: "Shinjuku Washington Hotel")], area: "Tokyo")

private let tokyoArgs: [String: JSONValue] = ["places": [item("浅草寺", 60), item("东京塔", 60, 2)], "abroad": true,
                                              "city": "Tokyo, Japan"]

@Suite("T-040v F-15b §50 real places from search, kept inside the trip area")
struct TripGroundTests {
    @Test("T-040v F-15b row 140: Qwen fixture: places with english, 浅草寺 kept at importance 3; trip ground ok=yes")
    func row140() async {
        let grounder = FakeGrounder(groundAnswer)
        let rig = await GroundRig(grounder: grounder)
        var args = tokyoArgs
        args["wishes"] = "酒店靠近新宿站"
        let r = await rig.run(trip("make_trip_list", args))
        #expect(r.ok)
        let request = grounder.calls.withLock { $0 }.first
        #expect(request?.city == "Tokyo, Japan" && request?.places.map(\.name) == ["浅草寺", "东京塔"] && request?.wishes == "酒店靠近新宿站")
        let stops = await rig.planner.currentPlan.days.flatMap(\.stops)
        #expect(stops.map(\.place.name).sorted() == ["东京塔", "明治神宫", "浅草寺"])
        let senso = stops.first { $0.place.name == "浅草寺" }
        #expect(senso?.importance == 3 && senso?.asked.contains("Senso-ji") == true)
        #expect(rig.line("trip ground vendor=qwen places=3 hotels=1 kept3=1 added=0 ok=yes ms=") != nil)
    }

    @Test("T-040v F-15b row 141: a fixture without 浅草寺 adds it back; a timeout uses the model's places, ok=fallback")
    func row141() async {
        let without = TripGroundAnswer(places: Array(groundAnswer.places.dropFirst()), hotels: [], area: "Tokyo")
        let kept = TripGround.keepMustSee(model: [TripGroundPlace(name: "浅草寺", minutes: 60, importance: 3)], answer: without.places)
        #expect(kept.added == 1 && kept.places.map(\.name) == ["东京塔", "明治神宫", "浅草寺"])
        let rig = await GroundRig(grounder: FakeGrounder(without))
        _ = await rig.run(trip("make_trip_list", tokyoArgs))
        #expect(await rig.planner.currentPlan.days.flatMap(\.stops).contains { $0.place.name == "浅草寺" })
        #expect(rig.line("trip ground vendor=qwen places=3 hotels=0 kept3=1 added=1 ok=yes ms=") != nil)

        let hanging = FakeGrounder(hang: true)
        let slow = await GroundRig(grounder: hanging)
        let made = Task { await slow.run(trip("make_trip_list", tokyoArgs)) }
        while hanging.calls.withLock({ $0.isEmpty }) || slow.clock.pendingSleepers == 0 { await Task.yield() }
        slow.clock.advance(by: .seconds(30))
        let r = await made.value
        #expect(r.ok)
        #expect(await slow.planner.currentPlan.days.flatMap(\.stops).map(\.place.name).sorted() == ["东京塔", "浅草寺"])
        #expect(slow.line("trip ground vendor=qwen places=2 hotels=0 kept3=1 added=0 ok=fallback reason=timeout ms=") != nil)
    }

    @Test("T-040v F-15b row 142: hotel_near=新宿站; hotels at 0.3, 0.8, 2.5 km: the two within 1 km in the hotel issue")
    func row142() async {
        let search = FakeAreaSearch(areaTable) { center in
            [0.3, 0.8, 2.5].map { km in
                place("H\(Int(km * 10))", lat: center.latitude + km / 111.2, lng: center.longitude, kind: .hotel)
            }
        }
        let rig = await GroundRig(search: search)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [item("A", 60)], "hotel_near": "新宿站 (Shinjuku Station)"])) == nil)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [item("A", 60)], "hotel_near": "  "])) == .invalidFields)
        var args = tokyoArgs
        args["places"] = [item("浅草寺", 240), item("东京塔", 240), item("上野公园", 240)]
        args["day_count"] = 2
        args["hotel_near"] = "新宿站 (Shinjuku Station)"
        let r = await rig.run(trip("make_trip_list", args))
        #expect(r.data["status"] == "trip_needs_fix")
        let hotelIssue = strings(r.data["issues"]).first { $0.hasPrefix("第1晚从这几个里挑一个") }
        #expect(hotelIssue == "第1晚从这几个里挑一个：H3（0.3公里）、H8（0.8公里）")
        let nightHotel = await rig.planner.currentPlan.days[0].stops.last
        #expect(nightHotel?.role == .hotel && nightHotel?.place.name == "H3")
    }

    @Test("T-040v F-15b row 143: a hotel 「新宿附近車站」 whose kind is a station is not used; 「新宿附近車站不是酒店」; §37 hotel")
    func row143() async {
        let rig = await GroundRig()
        var args = tokyoArgs
        args["places"] = [item("浅草寺", 240), item("东京塔", 240), item("上野公园", 240)]
        args["day_count"] = 2
        args["hotels"] = ["新宿附近車站"]
        let r = await rig.run(trip("make_trip_list", args))
        #expect(strings(r.data["issues"]).contains("新宿附近車站不是酒店"))
        let hotels = await rig.planner.currentPlan.days.flatMap(\.stops).filter { $0.role == .hotel }
        #expect(!hotels.isEmpty && hotels.allSatisfy { $0.place.name != "新宿附近車站" && $0.picked })
    }

    @Test("T-040v F-15b row 144: results in IN, TW and JP 60 km away are all dropped; area_dropped=3; not_found")
    func row144() async {
        let rig = await GroundRig()
        var args = tokyoArgs
        args["places"] = [item("浅草寺", 60), item("车站", 60)]
        let r = await rig.run(trip("make_trip_list", args))
        #expect(strings(r.data["not_found"]) == ["车站"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip search vendor=apple abroad=yes") && $0.contains(" area_dropped=3 picker=0") })
        #expect(rig.line("trip lookup index=2 ok=no reason=area") != nil)
        let (kept, dropped) = TripGround.inArea(areaTable["车站"]!, area: tokyoArea, km: 50)
        #expect(kept.isEmpty && dropped == 3)
    }

    @Test("T-040v F-15b row 145: a trip lookup asks the box around the centre with limit 5; two JP results go to the picker")
    func row145() async {
        let search = FakeAreaSearch(areaTable)
        let picker = FakePicker()
        let rig = await GroundRig(search: search, picker: picker)
        var args = tokyoArgs
        args["places"] = [item("浅草寺", 60), item("银座", 60)]
        _ = await rig.run(trip("make_trip_list", args))
        let asked = search.boxes.withLock { $0 }
        #expect(!asked.isEmpty && asked.allSatisfy { $0.1 == 5 && $0.0 == GeoBox.around(tokyoCenter) })
        #expect(abs(GeoBox.around(tokyoCenter).maxLatitude - 36.13) < 1e-9 && abs(GeoBox.around(tokyoCenter).minLongitude - 139.21) < 1e-9)
        #expect(picker.calls.withLock { $0 } == [["银座"]])
        #expect(rig.lines.withLock { $0 }.contains { $0.contains(" area_dropped=0 picker=1") })
    }

    @Test("T-040v F-15b row 147: a hotel with no OSRM route and a 60 h estimate fails far; days 2–3 not empty; dropped and named")
    func row147() async {
        var table = areaTable
        table["远方酒店"] = [place("远方酒店", lat: 20.0, lng: 78.0, country: "IN", kind: .hotel)]
        // Without an area (§36's China-only check) the hotel in India is found; OSRM fails, so times are estimated.
        let rig = await GroundRig(search: FakeAreaSearch(table), area: false, osrmFails: true)
        var args = tokyoArgs
        args["places"] = [item("浅草寺", 300), item("东京塔", 300), item("上野公园", 300), item("明治神宫", 300)]
        args["day_count"] = 3
        args["hotels"] = ["远方酒店"]
        var r = await rig.run(trip("make_trip_list", args))
        #expect(r.data["status"] == "trip_needs_fix")
        #expect(strings(r.data["issues"]).contains("远方酒店开车到不了或者太远，换一个Tokyo附近的"))
        let plan = await rig.planner.currentPlan
        #expect(plan.days.count == 3)
        #expect(plan.days.dropFirst().allSatisfy { day in day.stops.contains { $0.role == .sight } })
        #expect(plan.days.flatMap(\.stops).allSatisfy { $0.place.name != "远方酒店" })
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip check round=0 ") && $0.contains(" far=1 ") })
        var n = 0
        while r.data["status"] == "trip_needs_fix", n < 3 {
            r = await rig.run(trip("revise_trip_list", ["pace": "normal"]))
            n += 1
        }
        #expect(r.data["status"] == "trip_list")
        #expect(factsText(r).contains("去掉了远方酒店"))
    }

    @Test("T-040v F-15b row 143: a places item role=hotel, the night's last stop 「新宿附近車站」 (railway:station): not used; §37 hotel")
    func row143Places() async {
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [["name": "A", "role": "hotel"]]])) == nil)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": [["name": "A", "role": "sight"]]])) == .invalidFields)
        #expect(TripPlanner.items([["name": "A", "role": "hotel"], "B"]).map(\.hotel) == [true, false])
        let rig = await GroundRig()
        let args: [String: JSONValue] = ["days": [[item("浅草寺", 240), item("东京塔", 240),
                                                   ["name": "新宿附近車站", "role": "hotel"]], [item("上野公园", 240)]],
                                         "abroad": true, "city": "Tokyo, Japan"]
        let r = await rig.run(trip("make_trip_list", args))
        #expect(r.ok)
        let stops = await rig.planner.currentPlan.days.flatMap(\.stops)
        #expect(stops.allSatisfy { $0.place.name != "新宿附近車站" })
        #expect(stops.contains { $0.role == .hotel && $0.picked })
        let issues = strings(r.data["issues"])
        #expect(r.data["status"] == "trip_needs_fix" && issues.contains("新宿附近車站不是酒店"))
    }

    @Test("T-040z F-15b §51 item 8: navigate_to near=place keeps to the named place's own area (country, 50 km)")
    func navigateInArea() async {
        let search = FakeAreaSearch(areaTable)
        let lines = TripLines()
        let n = NavigationController(search: TripSearch([:]), engine: ScriptedNaviEngine(routes: [route(1, meters: 1_000, seconds: 60)]),
                                     location: NoLocation(), clock: ManualClock(), onTripLine: { lines.append($0) })
        await n.start()
        await n.setAbroad(search: search, center: { _ in tokyoCenter }, area: { _ in tokyoArea })
        let call = ToolCall(id: CallID("n1")!, name: "navigate_to",
                            arguments: ["destination": "车站", "near": "place", "near_name": "Tokyo, Japan", "near_country": "JP"])
        let r = await n.execute(call)
        #expect(r.code == .noCandidates)
        // F-09b §13 row 3 (T-031l): the abroad NO_CANDIDATES carries facts, searched in the named place's area.
        #expect(r.advice == nil && r.data["facts"]?["what"] == "车站" && r.data["facts"]?["around"] == "city")
        #expect(r.data["facts"]?["city"] == "Tokyo, Japan" && r.data["facts"]?["found"] == .int(0))
        #expect(r.data["facts"]?["searched_around"] == "Tokyo, Japan" && r.data["facts"]?["vendor"] == "photon")
        #expect(r.data["facts"]?["radius_km"] != nil && r.data["must_not"] == ["ask_rephrase", "invent"])
        #expect(search.boxes.withLock { $0 }.first?.0 == GeoBox.around(tokyoCenter))
        #expect(lines.withLock { $0 }.contains { $0.hasPrefix("nav search vendor=photon abroad=yes found=0 ") && $0.hasSuffix(" area_dropped=3") })
    }

    @Test("T-040v F-15b row 148: make_trip_list and revise_trip_list say item 5's one line first")
    func row148() {
        let line = "先只说一句：好，我规划一下，大概半分钟。然后不要说话，等结果。"
        #expect(TripGround.workingLine == line)
        #expect(ToolCatalog.makeTripListDescription.contains(line))
        #expect(ToolCatalog.reviseTripListDescription.contains(line))
        #expect(ToolCatalog.makeTripListDescription.contains("hotel_near"))
    }
}
