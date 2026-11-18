import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// The §46 photo source stand-in: answers by the name asked (a URL, nil = no page fits), or fails.
final class FakeAbroadPhotos: PlacePhotoSource, @unchecked Sendable {
    let answers: [String: URL?]
    let asked = Mutex<[String]>([])
    init(_ answers: [String: URL?]) { self.answers = answers }
    func photo(asked name: String, near: GeoCoordinate) async throws -> URL? {
        asked.withLock { $0.append(name) }
        guard let answer = answers[name] else { throw AmapWebError.timeout }
        return answer
    }
}

/// The names as the planner keeps them (normalized), brackets and English part included.
let sensoAsked = TranscriptText.normalize("浅草寺 (Senso-ji)")
let towerAsked = TranscriptText.normalize("东京塔 (Tokyo Tower)")

struct AbroadPhotoRig {
    let planner: TripPlanner
    let amap = PhotoSearch()
    let photos: FakeAbroadPhotos
    let files: MemoryTripFiles
    let lines = TripLines()

    init(_ photos: FakeAbroadPhotos, files: MemoryTripFiles = MemoryTripFiles()) async {
        self.photos = photos
        self.files = files
        let lines = self.lines
        let nav = NavigationController(search: amap, engine: ScriptedNaviEngine(routes: [route(1, meters: 5_000, seconds: 600)]),
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        let apple = FakeApple([
            sensoAsked: [jp("浅草寺", lat: 35.7148, lng: 139.7967)],
            towerAsked: [jp("东京塔", lat: 35.6586, lng: 139.7454)],
        ])
        planner = TripPlanner(search: amap, navigation: nav, origin: { GeoCoordinate(latitude: 35.68, longitude: 139.76, datum: .gcj02) },
                              clock: ManualClock(), files: files, onLine: { lines.append($0) }, abroadSearch: apple,
                              abroadPhotos: photos)
    }

    func make() async {
        _ = await planner.execute(trip("make_trip_list", ["places": names(["浅草寺 (Senso-ji)", "东京塔 (Tokyo Tower)"]),
                                                          "abroad": true]))
        await planner.photosSettled()
    }
}

@Suite("T-040r F-15b §46 photos abroad and the kind placeholder")
struct TripPhotosAbroadTests {
    @Test("F-15b row 105: an abroad stop asks the photo source with the name as written; photoURL set; vendor=wikipedia line; no 高德 detail")
    func row105() async {
        let thumb = URL(string: "https://upload.wikimedia.org/a/330px-Senso-ji.jpg")!
        let rig = await AbroadPhotoRig(FakeAbroadPhotos([sensoAsked: thumb, towerAsked: URL?.none]))
        await rig.make()
        let list = await rig.planner.current
        #expect(list.stops.first { $0.place.name == "浅草寺" }?.place.photoURL == thumb)
        #expect(list.stops.first { $0.place.name == "东京塔" }?.place.photoURL == nil)
        #expect(rig.photos.asked.withLock { $0 }.sorted() == [sensoAsked, towerAsked].sorted())
        #expect(rig.amap.details.withLock { $0 }.isEmpty)
        #expect(sensoAsked.contains("Senso-ji"))
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip photo vendor=wikipedia ok=1 none=1 failed=0 ms=") })
    }

    @Test("F-15b row 107: a failed lookup leaves the placeholder and the list unchanged; tried again at most once per launch")
    func row107() async {
        let rig = await AbroadPhotoRig(FakeAbroadPhotos([:]))
        await rig.make()
        let list = await rig.planner.current
        #expect(list.count == 2 && list.stops.allSatisfy { $0.place.photoURL == nil })
        #expect(list.generation == 1)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip photo vendor=wikipedia ok=0 none=0 failed=2 ms=") })
        for _ in 0..<2 {
            _ = await rig.planner.execute(trip("edit_trip_list", ["action": "move", "index": 2, "to_index": 1]))
            await rig.planner.photosSettled()
        }
        #expect(rig.photos.asked.withLock { $0 }.filter { $0 == sensoAsked }.count == 2)
    }

    @Test("F-15b row 108: a saved abroad plan with photoURL, reopened: no photo request")
    func row108() async {
        let thumb = URL(string: "https://upload.wikimedia.org/a/330px-Senso-ji.jpg")!
        let tower = URL(string: "https://upload.wikimedia.org/a/330px-Tokyo-Tower.jpg")!
        let files = MemoryTripFiles()
        let first = await AbroadPhotoRig(FakeAbroadPhotos([sensoAsked: thumb, towerAsked: tower]), files: files)
        await first.make()
        let photos = FakeAbroadPhotos([:])
        let second = await AbroadPhotoRig(photos, files: files)
        await second.planner.restore()
        await second.planner.photosSettled()
        let plan = await second.planner.currentPlan
        #expect(plan.abroad && Set(plan.days.flatMap(\.stops).compactMap(\.place.photoURL)) == [thumb, tower])
        #expect(photos.asked.withLock { $0 }.isEmpty)
    }

    @Test("F-15b row 109: the kind is saved with the plan and read back; an unknown saved kind reads as nil; the card shows .other")
    func row109() {
        let kinds: [PlaceKind?] = [.temple, .hotel, .airport, .rental, .other, nil]
        var list = TripList()
        list.arrange(kinds.enumerated().map { i, kind in
            TripStop(index: 0, asked: "p\(i)",
                     place: Place(id: "p\(i)", name: "p\(i)", address: nil, coordinate: GeoCoordinate(latitude: 35, longitude: 139, datum: .gcj02),
                                  distanceMeters: nil, countryCode: "JP", kind: kind),
                     distanceMeters: nil)
        })
        let plan = TripPlan(name: nil, days: [list], currentDay: 1)
        let back = TripPlanFile.current(from: TripPlanFile.current(plan))
        #expect(back?.days.first?.stops.map(\.place.kind) == kinds)
        // A kind this build does not know does not break the file.
        let text = String(decoding: TripPlanFile.current(plan), as: UTF8.self).replacingOccurrences(of: "\"rental\"", with: "\"spaceport\"")
        #expect(TripPlanFile.current(from: Data(text.utf8))?.days.first?.stops[3].place.kind == nil)
        guard case .cards(let cards) = TripScreen.of(list, moving: false) else { Issue.record("cards"); return }
        #expect(cards.map(\.kind) == [.temple, .hotel, .airport, .rental, .other, .other])
        #expect(PlaceKind.temple.symbol == "building.columns" && PlaceKind.other.symbol == "mappin.and.ellipse")
        // A photo keeps the kind.
        #expect(list.stops[0].place.with(photoURL: URL(string: "https://a.jp/x.jpg")).kind == .temple)
    }
}
