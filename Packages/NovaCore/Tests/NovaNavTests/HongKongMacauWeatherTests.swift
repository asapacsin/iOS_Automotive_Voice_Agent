import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// Regeo answering one adcode (nil: fails), counting the calls.
final class AdcodeGeocoder: ReverseGeocoder, @unchecked Sendable {
    let code: String?
    let calls = Mutex(0)
    init(_ code: String?) { self.code = code }
    func adcode(at coordinate: GeoCoordinate) async throws -> String? {
        calls.withLock { $0 += 1 }
        guard let code else { throw AmapWebError.failed }
        return code
    }
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        PlaceAddress(formatted: "香港特别行政区湾仔区", district: "湾仔区", road: nil)
    }
}

/// 高德 weather answering `status 1` with nothing (`WeatherNotCovered`), or timing out.
final class EmptyAmap: WeatherService, @unchecked Sendable {
    let timesOut: Bool
    let asked = Mutex<[WeatherDay]>([])
    init(timesOut: Bool = false) { self.timesOut = timesOut }
    func weather(adcode: String, day: WeatherDay) async throws -> WeatherReport {
        asked.withLock { $0.append(day) }
        if timesOut { throw AmapWebError.timeout }
        throw WeatherNotCovered(adcode: adcode)
    }
}

/// 高德 weather with casts for `casts`, recording the adcodes asked for.
final class AdcodeWeather: WeatherService, @unchecked Sendable {
    let casts: [String]
    let adcodes = Mutex<[String]>([])
    init(casts: [String]) { self.casts = casts }
    func weather(adcode: String, day: WeatherDay) async throws -> WeatherReport {
        adcodes.withLock { $0.append(adcode) }
        guard day.live || casts.contains(day.date) else { throw WeatherForecastMissing(date: day.date) }
        return WeatherReport(adcode: adcode, summary: .object(["date": .string(day.date)]))
    }
}

let macauAmap = LookedUpPlace(name: "澳门特别行政区", coordinate: GeoCoordinate(latitude: 22.19, longitude: 113.54, datum: .gcj02),
                              formatted: "澳门特别行政区", adcode: "820000")
let shanghaiOM = LookedUpPlace(name: "上海", country: "中国", coordinate: GeoCoordinate(latitude: 31.22, longitude: 121.46, datum: .wgs84),
                               population: 24_870_895, countryCode: "CN")
let macauOM = LookedUpPlace(name: "澳门", country: "中国澳门", coordinate: GeoCoordinate(latitude: 22.16, longitude: 113.56, datum: .wgs84),
                            population: 680_000, countryCode: "MO")
let hongKongOM = LookedUpPlace(name: "香港", country: "中国香港", coordinate: GeoCoordinate(latitude: 22.25, longitude: 114.17, datum: .wgs84),
                               population: 7_000_000, countryCode: "HK")
let tokyoOM = LookedUpPlace(name: "東京", country: "日本", coordinate: GeoCoordinate(latitude: 35.69, longitude: 139.69, datum: .wgs84),
                            population: 8_336_599, countryCode: "JP")
let nowNov6 = CurrentWeather(time: "2026-11-06T12:00", temperature: 23.4, feelsLike: 24, humidity: 70, weatherCode: 2, windKmh: 9)

struct HKMOSetup {
    let ex: LiveInfoExecutor
    let amapWeather: any WeatherService
    let amapLookup: RecordingLookup
    let omLookup: RecordingLookup
    let forecast: RecordingForecast
    let geocoder: AdcodeGeocoder
}

func hkmoSetup(amap: [LookedUpPlace] = [macauAmap], om: [LookedUpPlace] = [], weather: (any WeatherService)? = nil,
               regeo: String? = "440402", log: LogBox = LogBox()) -> HKMOSetup {
    let location = FixedLocation()
    let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []), location: location,
                                   clock: ManualClock())
    let w = weather ?? CountingWeather()
    let amapLookup = RecordingLookup(amap), omLookup = RecordingLookup(om)
    let forecast = RecordingForecast(forecastDays(), current: nowNov6, hours: forecastHours(from: "2026-11-06"), utcOffset: 28_800)
    let geocoder = AdcodeGeocoder(regeo)
    let ex = LiveInfoExecutor(navigation: nav, weather: w, geocoder: geocoder, location: location, now: { phoneNov6 },
                              zone: { shanghai }, amapLookup: amapLookup, forecastLookup: omLookup, forecast: forecast,
                              onWeather: { l in log.lines.withLock { $0.append(l) } })
    return HKMOSetup(ex: ex, amapWeather: w, amapLookup: amapLookup, omLookup: omLookup, forecast: forecast, geocoder: geocoder)
}

private func amapCalls(_ w: any WeatherService) -> Int {
    if let c = w as? CountingWeather { return c.calls.withLock { $0 } }
    if let e = w as? EmptyAmap { return e.asked.withLock { $0.count } }
    return -1
}

@Suite("T-046r F-18 §29 香港, 澳门 and English names get weather")
struct HongKongMacauWeatherTests {
    @Test("T-046r row 1: 澳门 (adcode 820000) is Open-Meteo at 高德's coordinates for now, day and hours; reason=hkmo")
    func row1() async {
        let log = LogBox()
        let s = hkmoSetup(log: log)
        let views: [[String: JSONValue]] = [["where": "澳门"], ["where": "澳门", "day": "tomorrow"], ["where": "澳门", "part": "afternoon"]]
        for args in views {
            let r = await s.ex.execute(weatherCall(args))
            #expect(r.ok, "\(args)")
            #expect(r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["country"] == "澳门", "\(args)")
            #expect(r.data["weather"]?["place"] == "澳门特别行政区")
        }
        #expect(amapCalls(s.amapWeather) == 0)
        #expect(s.forecast.asked.withLock { $0 } == Array(repeating: [22.19, 113.54], count: 3))
        let lines = log.lines.withLock { $0 }
        #expect(lines.count == 3 && lines.allSatisfy { $0.source == "open-meteo" && $0.ok && $0.reason == "hkmo" && $0.lookup == "amap" })
        #expect(lines.map(\.view) == ["now", "day", "hours"])
    }

    @Test("T-046r row 2: where=香港 country=HK uses Open-Meteo geocoding with HK; here with regeo 810000 uses the position")
    func row2() async {
        let s = hkmoSetup(om: [hongKongOM])
        let r = await s.ex.execute(weatherCall(["where": "香港", "country": "HK"]))
        #expect(r.ok && r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["country"] == "香港")
        #expect(s.omLookup.asked.withLock { $0 } == ["香港|HK"] && s.amapLookup.asked.withLock { $0.isEmpty })
        #expect(amapCalls(s.amapWeather) == 0)

        let here = hkmoSetup(regeo: "810000")
        let h = await here.ex.execute(weatherCall(["where": "here", "day": "today"]))
        #expect(h.ok && h.data["weather"]?["source"] == "open-meteo" && h.data["weather"]?["country"] == "香港")
        #expect(h.data["weather"]?["place"] == "湾仔区")
        #expect(here.forecast.asked.withLock { $0 } == [[22.27, 113.57]])
        #expect(amapCalls(here.amapWeather) == 0)
    }

    @Test("T-046r row 3: an empty 高德 answer (no lives, no forecasts) falls back to Open-Meteo with reason=empty")
    func row3() async {
        let log = LogBox()
        let s = hkmoSetup(amap: [zhuhaiCity], weather: EmptyAmap(), log: log)
        let now = await s.ex.execute(weatherCall(["where": "珠海"]))
        #expect(now.ok && now.data["weather"]?["source"] == "open-meteo" && now.data["weather"]?["day"] == "now")
        #expect(now.data["weather"]?["now"] != nil && now.data["weather"]?["today"] != nil)
        let tomorrow = await s.ex.execute(weatherCall(["where": "珠海", "day": "tomorrow"]))
        #expect(tomorrow.ok && tomorrow.data["weather"]?["source"] == "open-meteo" && tomorrow.data["date"] == "2026-11-07")
        let lines = log.lines.withLock { $0 }
        #expect(lines.filter { $0.source == "amap" }.map(\.reason) == ["empty", "empty"])
        #expect(lines.filter { $0.source == "open-meteo" }.allSatisfy { $0.ok })
    }

    @Test("T-046r row 4: a 高德 weather timeout fails as before, with no Open-Meteo call")
    func row4() async {
        let s = hkmoSetup(amap: [zhuhaiCity], weather: EmptyAmap(timesOut: true))
        for args: [String: JSONValue] in [["where": "珠海"], ["where": "珠海", "day": "tomorrow"]] {
            let r = await s.ex.execute(weatherCall(args))
            #expect(!r.ok && r.code == .liveInfoUnavailable)
        }
        #expect(s.forecast.asked.withLock { $0.isEmpty })
    }

    @Test("T-046r row 5: where=Shanghai → Open-Meteo 上海 CN, regeo 310000, 高德 weather for 310000, place 上海")
    func row5() async {
        let amap = AdcodeWeather(casts: ["2026-11-06", "2026-11-07"])
        let s = hkmoSetup(om: [shanghaiOM], weather: amap, regeo: "310000")
        let r = await s.ex.execute(weatherCall(["where": "Shanghai", "day": "tomorrow"]))
        #expect(r.ok && r.data["weather"]?["source"] == "amap")
        #expect(s.amapLookup.asked.withLock { $0.isEmpty } && s.omLookup.asked.withLock { $0 } == ["Shanghai|"])
        #expect(s.geocoder.calls.withLock { $0 } == 1 && s.forecast.asked.withLock { $0.isEmpty })
        #expect(amap.adcodes.withLock { $0 } == ["310000"])
        #expect(r.data["weather"]?["place"] == "上海")
        // Now: 高德's live report, still named by Open-Meteo.
        let now = await s.ex.execute(weatherCall(["where": "Shanghai"]))
        #expect(now.ok && now.data["weather"]?["source"] == "amap" && now.data["weather"]?["place"] == "上海")
        // With country=CN the §26 高德 path runs (item 3 needs an empty country).
        let cn = await s.ex.execute(weatherCall(["where": "Shanghai", "country": "CN"]))
        #expect(s.amapLookup.asked.withLock { $0 } == ["Shanghai|"] && cn.code == .liveInfoUnavailable)
        // A day 高德 has no cast for: Open-Meteo, with Open-Meteo's name as place.
        let late = await s.ex.execute(weatherCall(["where": "Shanghai", "date": "2026-11-15"]))
        #expect(late.ok && late.data["weather"]?["place"] == "上海")
    }

    @Test("T-046r row 6: Macau is item 1 (澳门); Tokyo is Open-Meteo (日本); Xyzzy is notFoundAdvice")
    func row6() async {
        let m = hkmoSetup(om: [macauOM])
        let macau = await m.ex.execute(weatherCall(["where": "Macau"]))
        #expect(macau.ok && macau.data["weather"]?["country"] == "澳门" && macau.data["weather"]?["source"] == "open-meteo")
        #expect(m.amapLookup.asked.withLock { $0.isEmpty } && amapCalls(m.amapWeather) == 0)
        let t = hkmoSetup(om: [tokyoOM])
        let tokyo = await t.ex.execute(weatherCall(["where": "Tokyo", "day": "tomorrow"]))
        #expect(tokyo.ok && tokyo.data["weather"]?["country"] == "日本" && tokyo.data["weather"]?["place"] == "東京")
        let x = hkmoSetup(om: [])
        let none = await x.ex.execute(weatherCall(["where": "Xyzzy"]))
        #expect(none.code == .liveInfoUnavailable && none.advice == ForecastWeather.notFoundAdvice)
        #expect(x.amapLookup.asked.withLock { $0.isEmpty } && x.forecast.asked.withLock { $0.isEmpty })
    }

    @Test("T-046r row 7: where=珠海 keeps the §26 path: 高德 geocode and name check, no Open-Meteo geocoding")
    func row7() async {
        let s = hkmoSetup(amap: [zhuhaiCity])
        let r = await s.ex.execute(weatherCall(["where": "珠海", "day": "today"]))
        #expect(r.ok && r.data["weather"]?["source"] == "amap")
        #expect(s.amapLookup.asked.withLock { $0 } == ["珠海|"] && s.omLookup.asked.withLock { $0.isEmpty })
        #expect(ForecastWeather.hasHan("珠海") && !ForecastWeather.hasHan("Shanghai") && !ForecastWeather.hasHan("São Paulo"))
        #expect(ForecastWeather.usesAmap(country: nil) && ForecastWeather.usesAmap(country: "CN"))
        #expect(!ForecastWeather.usesAmap(country: "HK") && !ForecastWeather.usesAmap(country: "MO"))
    }

    @Test("T-046r row 8: RuntimeLog lines carry lookup= and reason=; no place names, dates or numbers")
    func row8() async {
        let log = LogBox()
        _ = await hkmoSetup(log: log).ex.execute(weatherCall(["where": "澳门"]))
        _ = await hkmoSetup(om: [hongKongOM], log: log).ex.execute(weatherCall(["where": "香港", "country": "HK"]))
        _ = await hkmoSetup(amap: [zhuhaiCity], weather: EmptyAmap(), log: log).ex.execute(weatherCall(["where": "珠海"]))
        _ = await hkmoSetup(amap: [zhuhaiCity], weather: EmptyAmap(timesOut: true), log: log).ex.execute(weatherCall(["where": "珠海"]))
        _ = await hkmoSetup(om: [shanghaiOM], weather: CastsWeather(casts: ["2026-11-06"]), regeo: "310000", log: log)
            .ex.execute(weatherCall(["where": "Shanghai", "day": "today"]))
        _ = await hkmoSetup(om: [macauOM], log: log).ex.execute(weatherCall(["where": "Macau"]))
        _ = await hkmoSetup(om: [], log: log).ex.execute(weatherCall(["where": "Xyzzy"]))
        let lines = log.lines.withLock { $0.map(\.line) }
        #expect(lines.contains("weather source=open-meteo ok=yes reason=hkmo view=now lookup=amap"))
        #expect(lines.contains("weather source=open-meteo ok=yes reason=hkmo view=now lookup=open-meteo"))
        #expect(lines.contains("weather source=amap ok=no reason=empty view=now lookup=amap"))
        #expect(lines.contains("weather source=amap ok=no reason=timeout view=now lookup=amap"))
        #expect(lines.contains("weather source=amap ok=yes reason=ok view=day lookup=open-meteo"))
        #expect(lines.contains("weather source=open-meteo ok=no reason=not_found view=now lookup=open-meteo"))
        for line in lines {
            #expect(!line.contains(where: { $0.isNumber }), "\(line)")
            for word in ["澳门", "香港", "珠海", "上海", "Shanghai", "Macau", "Xyzzy", "11月"] { #expect(!line.contains(word), "\(line)") }
        }
    }
}
