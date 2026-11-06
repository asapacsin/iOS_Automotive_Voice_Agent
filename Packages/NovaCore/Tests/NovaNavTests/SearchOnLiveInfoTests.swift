import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// Records each asked day; answers like Amap would for `days` (offset → the casts it has).
final class CountingWeather: WeatherService, @unchecked Sendable {
    let calls = Mutex(0)
    let days = Mutex<[WeatherDay]>([])
    func weather(adcode: String, day: WeatherDay) async throws -> WeatherReport {
        calls.withLock { $0 += 1 }
        days.withLock { $0.append(day) }
        return WeatherReport(adcode: adcode, summary: .object(["day": .string(day.name), "date": .string(day.date)]))
    }
}

/// A forecast list in any order: picks by `date` like `AmapWebClient`, else `WeatherForecastMissing`.
struct CastsWeather: WeatherService {
    let casts: [String]
    func weather(adcode: String, day: WeatherDay) async throws -> WeatherReport {
        guard day.offset == 0 || casts.contains(day.date) else { throw WeatherForecastMissing(date: day.date) }
        return WeatherReport(adcode: adcode, summary: .object(["date": .string(day.date)]))
    }
}

/// 2026-11-05 15:00 in Asia/Shanghai.
let phoneNow = Date(timeIntervalSince1970: 1_793_862_000)
let shanghai = TimeZone(identifier: "Asia/Shanghai")!

func liveInfo(webSearch: Bool, weather: any WeatherService, search: any PlaceSearch = FixedSearch(places: [])) -> (LiveInfoExecutor, NavigationController) {
    let location = FixedLocation()
    let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: []), location: location, clock: ManualClock())
    return (LiveInfoExecutor(webSearch: webSearch, navigation: nav, weather: weather, geocoder: FakeGeocoder(), location: location,
                             now: { phoneNow }, zone: { shanghai }), nav)
}

func liveCall(_ args: [String: JSONValue]) -> ToolCall {
    ToolCall(id: CallID("c")!, name: "query_live_info", arguments: .object(args))
}

@Suite("T-046k F-18 §23 official data first")
struct SearchOnLiveInfoTests {
    @Test("F-18 §23 row 2: search on: weather today to 大后天 with date; hours answered; no hours → search advice")
    func searchOn() async {
        let weather = CountingWeather()
        let hours = Place(id: "Y", name: "Y", address: nil, coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02),
                          distanceMeters: nil, openingHours: "09:00-21:00", phone: nil)
        let bare = Place(id: "X", name: "长隆", address: nil, coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02),
                         distanceMeters: nil)
        let search = RecordingSearch(["X": [place("X", 1), place("Y", 2)]], details: ["X": bare, "Y": hours])
        let (on, nav) = liveInfo(webSearch: true, weather: weather, search: search)
        let expected = [("today", "2026-11-05"), ("tomorrow", "2026-11-06"), ("day_after", "2026-11-07"), ("day_after_next", "2026-11-08")]
        for (day, date) in expected {
            let r = await on.execute(liveCall(["kind": "weather", "where": "横琴", "day": .string(day)]))
            #expect(r.ok && r.data["date"] == .string(date), "\(day)")
        }
        #expect(weather.days.withLock { $0.map(\.offset) } == [0, 1, 2, 3])
        _ = await nav.execute(tool("navigate_to", ["destination": "X"]))
        let withHours = await on.execute(liveCall(["kind": "place_details", "target": "2"]))
        #expect(withHours.ok && withHours.data["opening_hours"] == "09:00-21:00")
        let noHours = await on.execute(liveCall(["kind": "place_details", "target": "1"]))
        #expect(noHours.code == .liveInfoUnavailable)
        #expect(noHours.advice?.contains("web_search") == true && noHours.advice?.contains("长隆") == true)
        #expect(weather.calls.withLock { $0 } == 4)
    }

    @Test("F-18 §23 row 2: search-on catalog keeps weather and place_details and adds the official-first sentence")
    func catalog() throws {
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let off = try #require(ToolCatalog.declarations(for: mode).first { $0.name == "query_live_info" })
            let on = try #require(ToolCatalog.declarations(for: mode, webSearch: true).first { $0.name == "query_live_info" })
            #expect(on.parametersJSONSchema == off.parametersJSONSchema)
            #expect(on.parametersJSONSchema["properties"]?["kind"]?["enum"] == .array(ToolCatalog.liveInfoKinds.map { .string($0) }))
            // §26 item 8 replaced the §23 sentence.
            #expect(on.description.contains("天气预报（今后16天内）只用 query_live_info，不用 web_search。地点营业时间先用 query_live_info；它没有数据时再用 web_search。"))
            #expect(on.description.contains("weather：") && on.description.contains("place_details："))
            #expect(!on.description.contains("新闻、股票、油价、汇率无数据源"))
        }
    }

    @Test("F-18 §23 row 3: casts in any order picked by date; a missing day → LIVE_INFO_UNAVAILABLE with the search advice")
    func byDate() async {
        let (on, _) = liveInfo(webSearch: true, weather: CastsWeather(casts: ["2026-11-07", "2026-11-05", "2026-11-06"]))
        let picked = await on.execute(liveCall(["kind": "weather", "day": "day_after"]))
        #expect(picked.ok && picked.data["date"] == "2026-11-07")
        let missing = await on.execute(liveCall(["kind": "weather", "day": "day_after_next"]))
        #expect(missing.code == .liveInfoUnavailable)
        #expect(missing.advice == "高德没有这一天的预报，请用 web_search 查。")
    }

    @Test("F-18 §23 row 4: search off: weather and place details as before; day enum is the longer list")
    func searchOff() async throws {
        let weather = CountingWeather()
        let bare = Place(id: "X", name: "长隆", address: nil, coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02),
                         distanceMeters: nil)
        let search = RecordingSearch(["X": [place("X", 1), place("Y", 2)]], details: ["X": bare])
        let (off, nav) = liveInfo(webSearch: false, weather: weather, search: search)
        let r = await off.execute(liveCall(["kind": "weather", "where": "上海", "day": "tomorrow"]))
        #expect(r.ok && r.data["date"] == "2026-11-06")
        _ = await nav.execute(tool("navigate_to", ["destination": "X"]))
        let details = await off.execute(liveCall(["kind": "place_details", "target": "1"]))
        #expect(details.ok && details.data["opening_hours"] == nil)
        #expect(details.data["next"]?.stringValue?.contains("web_search") == false)
        let live = try #require(ToolCatalog.declarations.first { $0.name == "query_live_info" })
        #expect(live.parametersJSONSchema["properties"]?["day"]?["enum"] == ["today", "tomorrow", "day_after", "day_after_next"])
        #expect(ToolCatalog.declarations(for: .table, webSearch: false) == ToolCatalog.declarations(for: .table))
    }
}
