import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
import NovaTools

final class MemorySettingsStore: SettingsStore {
    let values = Mutex<[String: String]>([:])
    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func set(_ value: Bool, for key: String) {}
}

/// Records every query; answers with fixed places or an error.
final class CountingSearch: PlaceSearch {
    let queries = Mutex<[String]>([])
    let places: [Place]
    let error: AmapWebError?

    init(places: [Place], error: AmapWebError? = nil) {
        self.places = places
        self.error = error
    }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        queries.withLock { $0.append(keywords) }
        if let error { throw error }
        return places
    }

    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await text(keywords, city: nil)
    }

    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

@Suite("F-16 saved places")
struct SavedPlacesTests {
    let routes = [route(1, meters: 8_000, seconds: 900)]
    let home = Place(id: "B1", name: "华发新城", address: "珠海市香洲区",
                     coordinate: GeoCoordinate(latitude: 22.25, longitude: 113.53, datum: .gcj02), distanceMeters: 120)

    func navigation(_ engine: ScriptedNaviEngine, search: CountingSearch, saved: SavedPlaces) async -> NavigationController {
        let nav = NavigationController(search: search, engine: engine, location: NoLocation(), clock: ManualClock(),
                                       saved: saved)
        await nav.start()
        return nav
    }

    @Test("save_place then 回家 routes straight to the saved place, no POI search")
    func saveThenGoHome() async {
        let saved = SavedPlaces(settings: MemorySettingsStore())
        let saveSearch = CountingSearch(places: [home, place("别处", 10)])
        let result = await SavePlaceExecutor(places: saved, search: saveSearch)
            .execute(tool("save_place", ["slot": "home", "address": "华发新城"]))
        #expect(result.ok && result.data["slot"] == "home" && result.data["name"] == "华发新城")
        #expect(result.data["next"]?.stringValue?.isEmpty == false)
        #expect(saveSearch.queries.withLock { $0 } == ["华发新城"])
        // Stored as returned: GCJ-02, not converted again.
        #expect(saved.place(.home)?.coordinate == home.coordinate)
        #expect(saved.setSlots == [.home])

        let engine = ScriptedNaviEngine(routes: routes)
        let navSearch = CountingSearch(places: [place("家", 1)])
        let nav = await navigation(engine, search: navSearch, saved: saved)
        let going = await nav.execute(tool("navigate_to", ["destination": "回家"]))
        #expect(going.ok && going.data["status"] == "navigation_started" && going.data["destination"] == "华发新城")
        #expect(navSearch.queries.withLock { $0 }.isEmpty)
        #expect(engine.calls.withLock { $0 }.first == "calculate 华发新城")
    }

    @Test("unset home → HOME_NOT_SET, unset work → WORK_NOT_SET, and no search")
    func unsetSlot() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let search = CountingSearch(places: [place("家", 1)])
        let nav = await navigation(engine, search: search, saved: SavedPlaces(settings: MemorySettingsStore()))
        let home = await nav.execute(tool("navigate_to", ["destination": "家"]))
        #expect(!home.ok && home.code == .homeNotSet && home.advice != nil)
        let work = await nav.execute(tool("navigate_to", ["destination": "去公司"]))
        #expect(!work.ok && work.code == .workNotSet)
        #expect(search.queries.withLock { $0 }.isEmpty)
        #expect(engine.calls.withLock { $0 }.isEmpty)
        #expect(await nav.current.phase == .idle)
    }

    @Test("unset 回家 while navigating keeps the current guidance running")
    func unsetSlotKeepsGuidance() async {
        let engine = ScriptedNaviEngine(routes: routes)
        let search = CountingSearch(places: [place("珠海站", 1)])
        let nav = await navigation(engine, search: search, saved: SavedPlaces(settings: MemorySettingsStore()))
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        _ = await nav.execute(tool("choose_navigation_option", ["preference": "recommended"]))
        #expect(await nav.current.phase == .navigating)
        let callsBefore = engine.calls.withLock { $0 }
        let home = await nav.execute(tool("navigate_to", ["destination": "回家"]))
        #expect(!home.ok && home.code == .homeNotSet)
        #expect(await nav.current.phase == .navigating)
        #expect(engine.calls.withLock { $0 } == callsBefore)
    }

    @Test("家乐福 is a normal search, not 家")
    func carrefour() async {
        let saved = SavedPlaces(settings: MemorySettingsStore())
        saved.save(home, in: .home)
        let engine = ScriptedNaviEngine(routes: routes)
        let search = CountingSearch(places: [place("家乐福", 900)])
        let nav = await navigation(engine, search: search, saved: saved)
        let result = await nav.execute(tool("navigate_to", ["destination": "家乐福"]))
        #expect(result.ok && result.data["destination"] == "家乐福")
        #expect(search.queries.withLock { $0 } == ["家乐福"])
    }

    @Test("save_place failures are honest and save nothing")
    func saveFailures() async {
        let cases: [(CountingSearch, ToolErrorCode)] = [
            (CountingSearch(places: []), .noCandidates),
            (CountingSearch(places: [], error: .keyMissing), .amapWebKeyMissing),
            (CountingSearch(places: [], error: .keyRejected), .amapWebKeyMissing),
            (CountingSearch(places: [], error: .failed), .liveInfoUnavailable),
            (CountingSearch(places: [], error: .timeout), .liveInfoUnavailable),
        ]
        for (search, code) in cases {
            let saved = SavedPlaces(settings: MemorySettingsStore())
            let result = await SavePlaceExecutor(places: saved, search: search)
                .execute(tool("save_place", ["slot": "work", "address": "横琴总部"]))
            #expect(!result.ok && result.code == code && result.advice != nil)
            #expect(saved.setSlots.isEmpty)
        }
        let blank = await SavePlaceExecutor(places: SavedPlaces(settings: MemorySettingsStore()),
                                            search: CountingSearch(places: [home]))
            .execute(tool("save_place", ["slot": "work", "address": "  "]))
        #expect(!blank.ok && blank.code == .invalidFieldValue)
    }

    @Test("save_place claims success only when the slot reads back the found place (I-1)")
    func saveReadBack() async {
        let result = await SavePlaceExecutor(places: SavedPlaces(settings: DroppingSettingsStore()),
                                             search: CountingSearch(places: [home]))
            .execute(tool("save_place", ["slot": "home", "address": "华发新城"]))
        #expect(!result.ok && result.code == .placeNotSaved && result.advice != nil)
    }
}

/// A store whose writes are lost (full disk, sandbox error).
final class DroppingSettingsStore: SettingsStore {
    func string(_ key: String) -> String? { nil }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) {}
    func set(_ value: Bool, for key: String) {}
}
