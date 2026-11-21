import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Text search from the Tianjin table; `detail` answers from `photos` (a URL, nil = no photo) or fails.
final class PhotoSearch: PlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let photos: [String: URL?]
    let details = Mutex<[String]>([])
    let texts = Mutex(0)

    init(_ table: [String: [Place]] = tianjin, photos: [String: URL?] = [:]) {
        self.table = table
        self.photos = photos
    }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        texts.withLock { $0 += 1 }
        return table[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? {
        details.withLock { $0.append(id) }
        guard let photo = photos[id] else { throw AmapWebError.failed }
        return spot(id, lat: 0, lng: 0).with(photoURL: photo)
    }
}

struct PhotoRig {
    let search: PhotoSearch
    let nav: NavigationController
    let planner: TripPlanner
    let lines = TripLines()

    init(_ search: PhotoSearch = PhotoSearch()) async {
        self.search = search
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 20_000, seconds: 1_800)])
        let lines = self.lines
        nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock(),
                                   onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { origin }, clock: ManualClock(),
                              onLine: { lines.append($0) })
    }

    func make(_ places: [String]) async {
        _ = await planner.execute(trip("make_trip_list", ["places": names(places)]))
        await planner.photosSettled()
    }
}

@Suite("T-040j F-15b phase 2a cards, strip, screen edits, pins")
struct TripScreenTests {
    @Test("F-15b row 16: a list of 5, not moving: 5 cards in index order with number, name, district, km; empty list: no row")
    func row16() async {
        let rig = await PhotoRig()
        #expect(TripScreen.of(await rig.planner.current, moving: false) == .none)
        await rig.make(["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区"])
        guard case .cards(let cards) = TripScreen.of(await rig.planner.current, moving: false) else {
            Issue.record("no cards"); return
        }
        #expect(cards.map(\.index) == [1, 2, 3, 4, 5])
        #expect(cards.map(\.name) == ["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区"])
        #expect(cards.allSatisfy { $0.district == "和平区" })
        #expect(cards[0].km == 11.1 && cards[0].initial == "古")
    }

    @Test("F-15b rows 17-18: 10 km/h → strip with moving=yes; 2 km/h for 3 s → cards, moving=no; 模拟导航 still → cards; 真实导航 unknown speed → strip")
    func rows17and18() async {
        var moving = TripMoving()
        let t0 = NovaInstant.zero
        #expect(moving.update(speedKmh: 10, gpsNavigating: false, at: t0) == true)
        #expect(TripMoving.line(true) == "trip strip moving=yes")
        #expect(moving.update(speedKmh: 2, gpsNavigating: false, at: t0 + .seconds(1)) == nil)
        #expect(moving.update(speedKmh: 2, gpsNavigating: false, at: t0 + .seconds(3)) == nil)
        #expect(moving.update(speedKmh: 2, gpsNavigating: false, at: t0 + .seconds(4)) == false)
        #expect(TripMoving.line(false) == "trip strip moving=no")
        // Between 3 and 8 km/h nothing changes.
        #expect(moving.update(speedKmh: 5, gpsNavigating: false, at: t0 + .seconds(5)) == nil && !moving.moving)
        // 模拟导航 alone with the phone still: not moving. 真实导航 with speed unknown: moving.
        #expect(moving.update(speedKmh: 0, gpsNavigating: false, at: t0 + .seconds(6)) == nil && !moving.moving)
        #expect(moving.update(speedKmh: nil, gpsNavigating: true, at: t0 + .seconds(7)) == true)
        var list = TripList()
        list.replace([("古文化街", spot("古文化街", lat: 39.1, lng: 117.2), 1000), ("五大道", spot("五大道", lat: 39.0, lng: 117.2), nil)])
        #expect(TripScreen.of(list, moving: true) == .strip("1 古文化街 · 2 五大道"))
        guard case .cards = TripScreen.of(list, moving: false) else { Issue.record("cards"); return }
        let long = TripList.withStops((1...16).map { "很长很长的景点名字\($0)" })
        guard case .strip(let text) = TripScreen.of(long, moving: true) else { Issue.record("strip"); return }
        #expect(text.count == TripScreen.stripLimit && text.hasSuffix("…"))
    }

    @Test("F-15b row 19: an http first link becomes https; no photo and a failed call show the placeholder; the line; the list unchanged")
    func row19() async {
        // The parser makes the http link secure (NovaServices TripPhotoParseTests); the detail gives it so here.
        let photos: [String: URL?] = ["古文化街": TripPhotoLink.secure("http://store.is.autonavi.com/a.jpg"), "五大道": URL?.none]
        let search = PhotoSearch(photos: photos)
        let rig = await PhotoRig(search)
        await rig.make(["古文化街", "五大道", "天津之眼"])
        let list = await rig.planner.current
        #expect(list.stops.map { $0.place.photoURL?.absoluteString } == ["https://store.is.autonavi.com/a.jpg", nil, nil])
        #expect(list.generation == 1)
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip photo vendor=amap ok=1 none=1 failed=1 ms=") })
        #expect(TripPhotoLink.secure("http://a.cn/x.jpg")?.absoluteString == "https://a.cn/x.jpg")
        #expect(TripPhotoLink.secure("ftp://a.cn/x.jpg") == nil && TripPhotoLink.secure("") == nil)
        // §12 item 5: the failed one is tried once more after the next change, the no-photo one is not.
        _ = await rig.planner.tap(.move(from: 3, to: 1), moving: false)
        await rig.planner.photosSettled()
        #expect(search.details.withLock { $0 }.filter { $0 == "天津之眼" }.count == 2)
        #expect(search.details.withLock { $0 }.filter { $0 == "五大道" }.count == 1)
        _ = await rig.planner.tap(.move(from: 3, to: 1), moving: false)
        await rig.planner.photosSettled()
        #expect(search.details.withLock { $0 }.filter { $0 == "天津之眼" }.count == 2)
    }

    @Test("F-15b row 20: a stop that already has a photo link makes no detail call")
    func row20() async {
        let rig = await PhotoRig()
        let saved = spot("瓷房子", lat: 39.02, lng: 117.2).with(photoURL: URL(string: "https://a.cn/c.jpg"))
        _ = await rig.planner.tap(.add(saved), moving: false)
        await rig.planner.photosSettled()
        #expect(rig.search.details.withLock { $0 }.isEmpty)
    }

    @Test("F-15b rows 21-23: ✕ on card 2 is one remove index=2 with a note and a tap line; moving refuses with no note; a drag is one move")
    func rows21to23() async {
        let rig = await PhotoRig()
        await rig.make(["古文化街", "五大道", "天津之眼", "瓷房子"])
        let moving = await rig.planner.tap(.remove(index: 2), moving: true)
        #expect(moving.result.code == .notWhileMoving && moving.note == nil)
        #expect(await rig.planner.current.count == 4)
        let removed = await rig.planner.tap(.remove(index: 2), moving: false)
        #expect(removed.result.ok)
        #expect(removed.note == "[系统] 司机在屏幕上去掉了第2个：五大道，现在清单有3个地点。这句不用回答。")
        #expect(await rig.planner.current.stops.map(\.index) == [1, 2, 3])
        #expect(rig.lines.withLock { $0 }.filter { $0.hasPrefix("trip tap") } == ["trip tap action=remove ok=no", "trip tap action=remove ok=yes"])
        let dragged = await rig.planner.tap(.move(from: 3, to: 1), moving: false)
        #expect(dragged.result.data["changed"] == "moved" && dragged.note?.contains("把第3个移到了第1个") == true)
        #expect(await rig.order() == ["瓷房子", "古文化街", "天津之眼"])
    }

    @Test("F-15b row 24: 加入清单 with 16 stops is TRIP_TOO_LONG; with 15 the place is added with no new lookup")
    func row24() async {
        let table = Dictionary(uniqueKeysWithValues: (1...16).map { ("景点\($0)", [spot("景点\($0)", lat: 39 + Double($0) / 100, lng: 117.2)]) })
        let rig = await PhotoRig(PhotoSearch(table))
        await rig.make((1...16).map { "景点\($0)" })
        let place = spot("天津之眼", lat: 39.16, lng: 117.2)
        let long = await rig.planner.tap(.add(place), moving: false).result
        #expect(long.code == .tripTooLong)
        // F-09b §13 row 7 (T-031o): the limit is a fact.
        #expect(long.data["facts"] == .object(["max_stops": .int(16)]))
        _ = await rig.planner.tap(.remove(index: 16), moving: false)
        let lookups = rig.search.texts.withLock { $0 }
        let added = await rig.planner.tap(.add(place), moving: false)
        #expect(added.result.ok && added.note == "[系统] 司机在屏幕上加入了天津之眼，现在清单有16个地点。这句不用回答。")
        #expect(rig.search.texts.withLock { $0 } == lookups)
        #expect(await rig.planner.current.stops.last?.place.name == "天津之眼")
    }

    @Test("F-15b row 25 (§29 item 4): pins 1-4 without 途经 labels; a visited stop is greyed")
    func row25() async {
        var list = TripList.withStops(["古文化街", "五大道", "天津之眼", "瓷房子"])
        #expect(TripPin.pins(list).map(\.label) == ["1", "2", "3", "4"])
        #expect(TripPin.pins(list).allSatisfy { !$0.passed })
        list.setMark(at: 1, .visited)
        #expect(TripPin.pins(list).map(\.passed) == [true, false, false, false])
        guard case .cards(let cards) = TripScreen.of(list, moving: false) else { Issue.record("cards"); return }
        #expect(cards[0].mark == .visited && cards[0].passed && cards[1].mark == nil)
    }

    @Test("F-15b §12 item 4: the disk cache drops the oldest until 20 MB fit")
    func cache() {
        let mb = 1024 * 1024
        let entries = (0..<5).map { TripPhotoCachePolicy.Entry(name: "p\($0)", bytes: 6 * mb, added: Date(timeIntervalSince1970: Double($0))) }
        #expect(TripPhotoCachePolicy.evict(entries) == ["p0", "p1"])
        #expect(TripPhotoCachePolicy.evict(Array(entries.prefix(3))).isEmpty)
    }
}

extension TripList {
    static func withStops(_ names: [String]) -> TripList {
        var list = TripList()
        list.replace(names.enumerated().map { ($0.element, spot($0.element, lat: 39 + Double($0.offset) / 100, lng: 117.2), nil) })
        return list
    }
}

extension PhotoRig {
    func order() async -> [String] { await planner.current.stops.map(\.place.name) }
}

@Suite("T-040j F-15b §12 photos on re-resolve")
struct TripPhotoAgainTests {
    @Test("F-15b §12 item 2: a place resolved again gets its photo back with no new call; a re-add of a listed place sends no note")
    func again() async {
        let photos: [String: URL?] = ["古文化街": URL(string: "https://a.cn/a.jpg"), "五大道": URL(string: "https://a.cn/b.jpg"),
                                      "天津之眼": URL(string: "https://a.cn/c.jpg")]
        let search = PhotoSearch(photos: photos)
        let rig = await PhotoRig(search)
        await rig.make(["古文化街", "五大道"])
        await rig.make(["古文化街", "五大道", "天津之眼"])
        let links = await rig.planner.current.stops.map { $0.place.photoURL?.absoluteString }
        #expect(links == ["https://a.cn/a.jpg", "https://a.cn/b.jpg", "https://a.cn/c.jpg"])
        #expect(search.details.withLock { $0 }.sorted() == ["五大道", "古文化街", "天津之眼"].sorted())
        let listed = await rig.planner.current.stops[0].place
        let again = await rig.planner.tap(.add(listed), moving: false)
        #expect(again.result.ok && again.note == nil)
    }
}
