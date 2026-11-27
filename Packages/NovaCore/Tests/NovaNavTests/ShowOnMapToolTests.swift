import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-09b §19 (T-031zd): `show_on_map(name, city)` puts one place on the map; looking is not going.
@Suite("T-031zd F-09b §19 show_on_map")
struct ShowOnMapToolTests {
    static let car = GeoCoordinate(latitude: 22.27, longitude: 113.58, datum: .gcj02)

    static func place(_ id: String, _ name: String, city: String?, lat: Double, district: String? = nil) -> Place {
        Place(id: id, name: name, address: "某路1号", coordinate: GeoCoordinate(latitude: lat, longitude: 113.58, datum: .gcj02),
              distanceMeters: nil, city: city, district: district)
    }

    final class Pins: Sendable {
        let all = Mutex<[MapPin]>([])
        var current: MapPin? { all.withLock { $0.last } }
    }

    /// A navigation that records any route or destination request (none may come from show_on_map).
    final class RouteSpy: Sendable { let calls = Mutex(0) }

    func tool(_ search: CitySearch, pins: Pins, car: GeoCoordinate? = car, lines: ShowPlaceToolTests.Lines = ShowPlaceToolTests.Lines()) -> ShowOnMapTool {
        ShowOnMapTool(onScreen: { [] }, search: search, cityCode: { "440400" }, car: { car },
                      pin: { pin in pins.all.withLock { $0.append(pin) }; return true },
                      clock: ManualClock(), onLine: { l in lines.all.withLock { $0.append(l) } })
    }

    static func call(_ name: String, _ city: String) -> ToolCall {
        ToolCall(id: CallID("m1")!, name: "show_on_map", arguments: ["name": .string(name), "city": .string(city)])
    }

    @Test("T-031zd F-09b row 1: one exact name in her city: ok with name, city, district, distance_km; the pin set; no route request; record line")
    func row1() async {
        let resort = Self.place("J1", "中旅·阿那亚·九龙湖度假区", city: "广州市", lat: 23.62, district: "花都区")
        let search = CitySearch(local: [resort])
        let pins = Pins()
        let lines = ShowPlaceToolTests.Lines()
        let r = await tool(search, pins: pins, lines: lines).execute(Self.call("中旅·阿那亚·九龙湖度假区", "广州"))
        #expect(r.ok, "\(r)")
        let facts = r.data["facts"]
        #expect(facts?["name"] == "中旅·阿那亚·九龙湖度假区" && facts?["city"] == "广州市" && facts?["district"] == "花都区")
        let km = MapPin.km(from: Self.car, to: resort.coordinate)!
        #expect(km == 150 && facts?["distance_km"] == .int(Int64(km)))
        #expect(r.data["next"] == .string(ShowOnMapTool.shownNext))
        #expect(pins.current == MapPin(name: resort.name, coordinate: resort.coordinate, district: "花都区", distanceKm: km))
        #expect(pins.current?.detail == "花都区，距离 150 公里")
        // Only the city-limited lookup ran; nothing else was asked of any service.
        #expect(search.queries.withLock { $0 } == [CitySearch.Query(keywords: "中旅·阿那亚·九龙湖度假区", city: "广州", cityLimit: true)])
        #expect(lines.first?.hasPrefix("show map ok=yes via=city sure=yes found=1 km=150 ms=") == true)
        // Car unknown: no distance.
        let noCar = await tool(CitySearch(local: [resort]), pins: Pins(), car: nil).execute(Self.call("中旅·阿那亚·九龙湖度假区", "广州"))
        #expect(noCar.ok && noCar.data["facts"]?["distance_km"] == nil)
    }

    @Test("T-031zd F-09b row 2: only other names: no pin, PLACE_UNSURE with found and the map next")
    func row2() async {
        let pins = Pins()
        let r = await tool(CitySearch(local: [Self.place("X", "九龙湖公园", city: "广州市", lat: 23.1)]), pins: pins)
            .execute(Self.call("九龙湖度假区", "广州"))
        #expect(!r.ok && r.code == .placeUnsure)
        #expect(r.data["next"] == .string(ShowOnMapTool.unsureNext) && ShowOnMapTool.unsureNext.hasPrefix("地图上没有标出来。看 found："))
        #expect(ShowPlaceToolTests.found(r) == ["九龙湖公园"])
        #expect(pins.all.withLock { $0.isEmpty })
    }

    @Test("T-031zd F-09b row 3: a second show_on_map for another place: the pin is the new one (the App keeps one)")
    func row3() async {
        let a = Self.place("A", "白云山", city: "广州市", lat: 23.18)
        let b = Self.place("B", "长隆野生动物世界", city: "广州市", lat: 23.0)
        let pins = Pins()
        _ = await tool(CitySearch(local: [a]), pins: pins).execute(Self.call("白云山", "广州"))
        _ = await tool(CitySearch(local: [b]), pins: pins).execute(Self.call("长隆野生动物世界", "广州"))
        #expect(pins.current?.name == "长隆野生动物世界")
    }

    @Test("T-031zd F-09b row 4: 关掉 with mapPin on top closes only mapPin; a navigate_to place list takes the pin away")
    func row4() async {
        let screen = ScreenStateStore()
        await screen.report(.navigation, on: true)
        await screen.report(.mapPin, on: true)
        let closed = Mutex<[ScreenPanel]>([])
        let nav = NotYetExecutor()
        let tool = ScreenConfirmedExecutor(nav, screen: screen, clock: ManualClock(), close: { panel in
            closed.withLock { $0.append(panel) }
            await screen.report(panel, on: false)
        })
        let r = await tool.execute(ToolCall(id: CallID("x")!, name: "exit_navigation_mode", arguments: [:]))
        #expect(r.ok && r.data["closed"] == "mapPin", "\(r)")
        #expect(closed.withLock { $0 } == [.mapPin])
        let after = await screen.current
        #expect(after.isOn(.navigation) && !after.isOn(.mapPin))
        // navigate_to listing places: the pin goes; route picking or guidance keep it.
        let pin = MapPin(name: "x", coordinate: Self.car, district: nil, distanceKm: nil)
        var flow = NavigationFlowState()
        flow.phase = .awaitingDestinationSelection
        #expect(MapPin.kept(pin, after: flow) == nil)
        flow.phase = .navigating
        #expect(MapPin.kept(pin, after: flow) == pin)
        #expect(ToolCatalog.exitPanels.contains("mapPin"))
    }

    @Test("T-031zd F-09b row 5: a sure show_on_map closes tripDetail and tripPlans (the layer-3 sheets over the map)")
    func row5() {
        #expect(MapPin.sheetsClosedOnShow == [.tripDetail, .tripPlans])
        #expect(MapPin.sheetsClosedOnShow.allSatisfy { ScreenConfirmedExecutor.ownClose[$0] != nil })
    }

    @Test("T-031zd F-09b row 6: declaration, navigate_to sentence and the mapPin registry entry")
    func row6() {
        let spec = ToolCatalog.spec("show_on_map")
        #expect(spec?.declaration.description == "在地图上标出一个地方给司机看，不导航、不算路线。司机问在哪里、在地图上看看、离这里多远时用；司机要去那里才用 navigate_to。city 填这个地方所在的城市；不确定在哪个城市时先用 web_search 查。")
        #expect(spec?.declaration.parametersJSONSchema["required"] == ["name", "city"])
        #expect(ToolCatalog.spec("navigate_to")?.declaration.description.contains("司机只是想看在哪里，用 show_on_map。") == true)
        #expect(ToolCatalog.validate(ToolCall(id: CallID("v")!, name: "show_on_map", arguments: ["name": "白云山", "city": "广州"])) == nil)
        let entry = PanelRegistry.entry(.mapPin)
        #expect(entry == PanelEntry(layer: 1, opens: ["show_on_map"], close: "exit_navigation_mode", acts: ["navigate_to"]))
    }
}
