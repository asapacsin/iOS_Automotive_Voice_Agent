import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

private func spot(_ name: String, km: Double) -> Place {
    Place(id: name, name: name, address: "\(name)地址", coordinate: GeoCoordinate(latitude: 22.13 + km / 111,
          longitude: 113.54, datum: .gcj02), distanceMeters: Int(km * 1000), city: "珠海市", district: "香洲区")
}

private func entry(_ name: String, _ about: String) -> JSONValue {
    .object(["name": .string(name), "about": .string(about)])
}

private extension JSONValue {
    func item(_ index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

final class ExploreLines: @unchecked Sendable {
    let all = Mutex<[String]>([])
}

@Suite("T-042d F-16 §15 explore: searched and shown, not routed")
struct ExploreTests {
    func controller(_ search: StepSearch, lines: ExploreLines? = nil) async -> (NavigationController, ScriptedNaviEngine) {
        let engine = ScriptedNaviEngine(routes: [route(1, meters: 3_000, seconds: 360)])
        let fix = LocationFix(coordinate: GeoCoordinate(latitude: 22.13, longitude: 113.54, datum: .wgs84),
                              horizontalAccuracyMeters: 20, timestamp: .zero)
        let near = NearFirstSearch(match: DestinationMatch(pinyin: TablePinyin()), geocoder: HengqinGeocoder(),
                                   driverTurns: { 0 })
        let nav = NavigationController(search: search, engine: engine, location: FixLocation(fix: fix), clock: ManualClock(),
                                       nearFirst: near)
        await nav.start()
        await nav.setCityCode { "440404" }
        if let lines { await nav.setExploreLine { line in lines.all.withLock { $0.append(line) } } }
        return (nav, engine)
    }

    @Test("F-16 §15 row 4: 3 names, one unknown to 高德: 3 on the list, the unknown one without distance; no route")
    func threeNamesOneUnknown() async throws {
        let search = StepSearch(city: ["雪自由": [spot("雪自由(珠海环宇城)", km: 12)], "景山公园": [spot("景山公园", km: 16)]])
        let lines = ExploreLines()
        let (nav, engine) = await controller(search, lines: lines)
        let r = await nav.execute(tool("show_places", ["places": .array([
            entry("雪自由", "室内滑雪场"), entry("不存在的雪场", "网上提到的雪场"), entry("景山公园", "可以爬山")])]))
        #expect(r.ok)
        let state = await nav.current
        #expect(state.phase == .awaitingDestinationSelection)
        #expect(state.places.map(\.name) == ["雪自由(珠海环宇城)", "景山公园", "不存在的雪场"])
        #expect(state.places.map { state.about($0) } == ["室内滑雪场", "可以爬山", "网上提到的雪场"])
        #expect(state.places.map { state.unlocated($0) } == [false, false, true])
        #expect(state.places[0].distanceMeters == 12_000)
        // The unknown name has no marker; nothing routed.
        #expect(MapPresentation(state).markers.map(\.name) == ["雪自由(珠海环宇城)", "景山公园"])
        #expect(engine.calls.withLock { $0 }.isEmpty)
        #expect(state.destination == nil && state.routes.isEmpty)
        // Looked up in the car's city, no §14 name check.
        #expect(search.log.withLock { $0 } == ["city 雪自由 440404", "city 不存在的雪场 440404", "city 景山公园 440404"])
        let listed = r.data["facts"]?["listed"]
        #expect(listed?.item(2)?["located"] == false && listed?.item(0)?["distance_km"] == .double(12))
        #expect(r.data["facts"]?["routed"] == false)
        #expect(lines.all.withLock { $0 }.count == 1 && lines.all.withLock { $0 }[0].hasPrefix("show places n=3 located=2 ms="))
    }

    @Test("F-16 §15 item 3: navigate only on go; picking a listed place routes it; an unlocated one is searched by name")
    func navigateOnGo() async {
        let search = StepSearch(city: ["雪自由": [spot("雪自由(珠海环宇城)", km: 12)]])
        let (nav, engine) = await controller(search)
        _ = await nav.execute(tool("show_places", ["places": .array([entry("雪自由", "室内滑雪场")])]))
        #expect(engine.calls.withLock { $0 }.isEmpty)
        let picked = await nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(picked.ok)
        #expect(engine.calls.withLock { $0 }.contains("calculate 雪自由(珠海环宇城)"))
        // A new list clears the about lines (they belong to the show_places list only).
        #expect(await nav.current.about(spot("雪自由(珠海环宇城)", km: 12)) == nil)
    }

    @Test("F-16 §15 item 2: catalog validation: 1–5 places with a name, about optional")
    func validation() {
        #expect(ToolCatalog.validate("show_places", ["places": .array([entry("雪自由", "室内滑雪场")])]) == nil)
        #expect(ToolCatalog.validate("show_places", ["places": .array([.object(["name": "雪自由"])])]) == nil)
        #expect(ToolCatalog.validate("show_places", ["places": .array([])]) == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_places", ["places": .array(Array(repeating: entry("a", "b"), count: 6))])
                == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_places", ["places": .array([.object(["about": "x"])])]) == .invalidFieldType)
        #expect(ToolCatalog.validate("show_places", ["places": .array([entry("a", "b")]), "near": "here"]) == .invalidFields)
        #expect(ToolCatalog.spec("show_places") != nil)
        #expect(!ToolCatalog.declarations.contains { $0.name == "show_places" })
        #expect(ToolCatalog.declarations(webSearch: true).contains { $0.name == "show_places" })
    }

    @Test("F-16 §15 row 5: §14 search, 高德 returns 2, both under askMin: facts found=2, never found=0")
    func noSilentDrop() async {
        let search = StepSearch(around: ["滑雪场": [spot("雪自由(珠海环宇城)", km: 12), spot("鸿运坊", km: 3)]])
        let (nav, engine) = await controller(search)
        let home = await nav.execute(tool("navigate_to", ["destination": "滑雪场"]))
        #expect(home.code == .noCandidates)
        #expect(home.data["facts"]?["found"] == 2 && home.data["facts"]?["name_matched"] == 0)
        let here = await nav.execute(tool("navigate_to", ["destination": "滑雪场", "near": "here"]))
        #expect(here.code == .noCandidates)
        #expect(here.data["facts"]?["found"] == 2)
        #expect(engine.calls.withLock { $0 }.isEmpty)
    }
}
