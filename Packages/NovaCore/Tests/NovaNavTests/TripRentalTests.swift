import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Photon stand-in for §45 (T-040q): names from `tokyo`; 「租车」 around a point answers the rentals listed for the
/// nearest key point (within 0.05°), nearest first; every 「租车」 search is counted.
final class FakeRentals: PlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let rentals: [(GeoCoordinate, [Place])]
    let asked = Mutex<[String]>([])
    init(_ table: [String: [Place]], rentals: [(GeoCoordinate, [Place])]) {
        self.table = table
        self.rentals = rentals
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        return table[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        asked.withLock { $0.append(keywords) }
        guard keywords == "租车" else { return table[keywords] ?? [] }
        return rentals.first { abs($0.0.latitude - center.latitude) < 0.05 && abs($0.0.longitude - center.longitude) < 0.05 }?.1 ?? []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
    var rentalSearches: Int { asked.withLock { $0 }.filter { $0 == "租车" }.count }
}

private let narita = GeoCoordinate(latitude: 35.77, longitude: 139.8, datum: .gcj02)
private let haneda = GeoCoordinate(latitude: 35.55, longitude: 139.78, datum: .gcj02)
/// 日産レンタカー 1.7 km from 成田 (device check 2026-11-18), then Toyota further on.
private let nissan = jp("日産レンタカー 成田空港店", lat: 35.785)
private let toyotaNarita = jp("Toyota Rent a Car Narita", lat: 35.79)
private var rentalTable: [String: [Place]] {
    var t = tokyo
    t["羽田机场"] = [jp("羽田机场", lat: 35.55, lng: 139.78)]
    t["Times租车成田"] = [jp("Times租车成田", lat: 35.78)]
    return t
}
private let threeDays = days([["浅草寺", "上野公园"], ["东京塔"], ["皇居", "银座"]])

private func stops(_ rig: TripRig) async -> [[TripStop]] {
    await rig.planner.currentPlan.days.map { $0.stops }
}

@Suite("T-040q F-15b §45 car rental in a trip")
struct TripRentalTests {
    @Test("F-15b row 99: start=end=成田, rental=true, 3 days: one 租车 search; 成田 → rental → sights … rental → 成田; trip frame rental=both")
    func row99() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan, toyotaNarita])])
        let (rig, _) = await timesRig(abroad: photon)
        let r = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                      "end": "成田机场", "rental": true]))
        #expect(r.ok)
        #expect(photon.rentalSearches == 1)
        let d = await stops(rig)
        #expect(d.count == 3)
        #expect(d[0].prefix(2).map(\.role) == [.start, .rentalPickup])
        #expect(d[0][0].place.name == "成田机场" && d[0][1].place.name == nissan.name && d[0][1].picked)
        #expect(d[0].dropFirst(2).allSatisfy { $0.role == .sight || $0.role == .hotel })
        #expect(d[2].suffix(2).map(\.role) == [.rentalReturn, .end])
        // start = end: the pickup place is the return.
        #expect(d[2].suffix(2).map(\.place.name) == [nissan.name, "成田机场"])
        let sights = d.flatMap { $0 }.filter { $0.role == .sight }.map(\.place.name)
        #expect(sights.sorted() == ["浅草寺", "上野公园", "东京塔", "皇居", "银座"].sorted())
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip frame ") && $0.hasSuffix(" rental=both") })
        #expect(r.data["next"]?.stringValue?.contains("租车需要提前在网上预订") == true)
        // The plan the model reads says which stop is the pickup.
        #expect(r.data["plan"] == .array(d.map { .array($0.map { .string($0.place.name + TripPlanner.roleNote($0.role)) }) }))
        #expect(TripPlanner.roleNote(.rentalPickup) == "（取车）" && TripPlanner.roleNote(.rentalReturn) == "（还车）")
    }

    @Test("F-15b §45 / §37 item 3: add on a last day left with only [hotel, rental return, end] goes before the closing rental return and end")
    func addOnEmptiedLastDay() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan, toyotaNarita])])
        let (rig, _) = await timesRig(abroad: photon)
        _ = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                  "end": "成田机场", "rental": true]))
        while let i = await stops(rig)[2].firstIndex(where: { $0.role == .sight }) {
            _ = await rig.run(trip("edit_trip_list", ["action": "remove", "index": .int(Int64(i + 1)), "day": 3]))
        }
        let before = await stops(rig)[2].map(\.role)
        _ = await rig.run(trip("edit_trip_list", ["action": "add", "name": "银座", "day": 3]))
        let after = await stops(rig)[2].map(\.role)
        #expect(after.count == before.count + 1)
        #expect(after.suffix(3) == [.sight, .rentalReturn, .end])
    }

    @Test("F-15b row 100: two rentals near the end, the farther one shares the pickup's brand: it is the return")
    func row100() async {
        let nippon = jp("Nippon Rent-A-Car Haneda", lat: 35.552, lng: 139.78)
        let toyota = jp("Toyota Rent a Car Haneda", lat: 35.56, lng: 139.78)
        let photon = FakeRentals(rentalTable, rentals: [(narita, [toyotaNarita, nissan]), (haneda, [nippon, toyota])])
        let (rig, _) = await timesRig(abroad: photon)
        let r = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                      "end": "羽田机场", "rental": true]))
        #expect(r.ok)
        #expect(photon.rentalSearches == 2)
        let d = await stops(rig)
        #expect(d[0][1].place.name == toyotaNarita.name && d[0][1].role == .rentalPickup)
        #expect(d[2].suffix(2).map(\.place.name) == [toyota.name, "羽田机场"])
        #expect(d[2].suffix(2).map(\.role) == [.rentalReturn, .end])
        #expect(TripPlanner.rentalBrand("日産レンタカー 成田空港店") == "日産")
        #expect(TripPlanner.rentalBrand("Toyota Rent a Car Haneda") == "Toyota")
        #expect(TripPlanner.rentalBrand("Times租车 成田") == "Times")
    }

    @Test("F-15b row 101: rental=true, no rental within 10 km of the start: pickup left out, said in next; plan built")
    func row101() async {
        let photon = FakeRentals(rentalTable, rentals: [])
        let (rig, _) = await timesRig(abroad: photon)
        let r = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                      "end": "成田机场", "rental": true]))
        #expect(r.ok)
        let next = r.data["next"]?.stringValue ?? ""
        #expect(next.contains("成田机场附近没找到租车点"))
        // Said once although start = end.
        #expect(next.components(separatedBy: "附近没找到租车点").count == 2)
        let all = await stops(rig).flatMap { $0 }
        #expect(all.contains { $0.role == .rentalPickup || $0.role == .rentalReturn } == false)
        #expect(all.filter { $0.role == .sight }.count == 5)
        // 3 km, then 10 km.
        #expect(photon.rentalSearches == 2)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip frame ") && $0.hasSuffix(" rental=missing") })
    }

    @Test("F-15b row 102: rental=false (default): no rental search; outputs as before")
    func row102() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan])])
        let (rig, _) = await timesRig(abroad: photon)
        let r = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场", "end": "成田机场"]))
        #expect(r.ok)
        #expect(photon.rentalSearches == 0)
        #expect(await stops(rig).flatMap { $0 }.contains { $0.role == .rentalPickup || $0.role == .rentalReturn } == false)
        #expect((r.data["next"]?.stringValue ?? "").contains("租车") == false)
        #expect(rig.lines.withLock { $0 }.contains { $0.contains("rental=") } == false)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip frame start=named end=named") })
    }

    @Test("F-15b row 103: saved plan with rental stops reopened keeps the roles; replace the pickup keeps rental_pickup")
    func row103() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan])])
        let (rig, _) = await timesRig(abroad: photon)
        _ = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                  "end": "成田机场", "rental": true]))
        let plan = await rig.planner.currentPlan
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.days.map { $0.stops.map(\.role) } == plan.days.map { $0.stops.map(\.role) })
        #expect(back?.days[0].stops[1].role == .rentalPickup && back?.days[0].stops[1].picked == true)
        let r = await rig.run(trip("edit_trip_list", ["action": "replace", "index": .int(2), "name": "Times租车成田", "day": 1]))
        #expect(r.ok)
        let d = await stops(rig)
        #expect(d[0][1].place.name == "Times租车成田" && d[0][1].role == .rentalPickup && d[0][1].picked == false)
        // The return on the last day is untouched.
        #expect(d[2].suffix(2).map(\.role) == [.rentalReturn, .end])
    }

    @Test("F-15b §45 items 9–10: rental cards say 租; catalog field and text; rental must be a bool")
    func cardsAndCatalog() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan])])
        let (rig, _) = await timesRig(abroad: photon)
        _ = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                  "end": "成田机场", "rental": true]))
        guard case .cards(let cards) = TripScreen.of(await rig.planner.current, moving: false) else { Issue.record("cards"); return }
        #expect(cards.prefix(2).map(\.tag) == ["机场", "租"])
        #expect(ToolCatalog.makeTripListDescription.contains("司机要租车就填 rental=true，会自动在起点附近找取车点、在终点附近找还车点。"))
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": names(["浅草寺"]), "rental": true])) == nil)
        #expect(ToolCatalog.validate(trip("make_trip_list", ["places": names(["浅草寺"]), "rental": "yes"])) == .invalidFields)
    }

    @Test("F-15b §45 item 4: reorganize keeps the pickup after the start and the return before the end")
    func reorganizeKeepsRental() async {
        let photon = FakeRentals(rentalTable, rentals: [(narita, [nissan])])
        let (rig, _) = await timesRig(abroad: photon)
        _ = await rig.run(trip("make_trip_list", ["days": threeDays, "abroad": true, "start": "成田机场",
                                                  "end": "成田机场", "rental": true]))
        let r = await rig.run(trip("edit_trip_list", ["action": "reorganize"]))
        #expect(r.ok)
        let d = await stops(rig)
        #expect(d[0].prefix(2).map(\.role) == [.start, .rentalPickup])
        #expect(d[d.count - 1].suffix(2).map(\.role) == [.rentalReturn, .end])
        #expect(photon.rentalSearches == 1)
    }
}
