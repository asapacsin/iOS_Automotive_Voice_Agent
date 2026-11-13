import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// 2026-11-13 14:20 UTC.
let placeNov13 = Date(timeIntervalSince1970: 1_794_579_600)
let tokyoQW = LookedUpPlace(name: "东京", country: "日本", coordinate: GeoCoordinate(latitude: 35.6895, longitude: 139.6917, datum: .wgs84))
let macauQW = LookedUpPlace(name: "澳门", country: "中国", coordinate: GeoCoordinate(latitude: 22.1987, longitude: 113.5439, datum: .wgs84))

/// Hourly 和风 entries from `first` 00:00 for 2 days; hour h: 小雨 after 15:00 else 多云, 10.4+h °C, rain 10·(h % 10) %.
func qweatherHours(from first: String = "2026-11-13") -> [HourlyForecast] {
    let start = ForecastWeather.isoDay(first)!
    return (0..<2).flatMap { d in
        (0..<24).map { h in
            HourlyForecast(time: ForecastWeather.adding(d, to: start).iso + String(format: "T%02d:00", h), weatherCode: nil,
                           temperature: 10.4 + Double(h), rainChance: Double(10 * (h % 10)), text: h > 15 ? "小雨" : "多云")
        }
    }
}

@Suite("T-046t F-18 §31 all weather from 和风天气")
struct QWeatherWeatherTests {
    @Test("T-046t F-18 §31 row 01: 珠海 now: 高德 geocode only; 和风 now at 高德's coordinates rounded, latitude first; source qweather")
    func row01() async {
        let qw = RecordingQWeather()
        let (ex, _, amap, foreign, forecast) = forecastSetup(qweather: qw, now: placeNov13)
        let r = await ex.execute(weatherCall(["where": "珠海"]))
        #expect(r.ok && r.data["weather"]?["source"] == "qweather" && r.data["weather"]?["place"] == "珠海市")
        #expect(qw.asked.withLock { $0 } == ["now 22.27,113.58"])
        #expect(amap.asked.withLock { $0 } == ["珠海|"] && foreign.asked.withLock { $0.isEmpty } && forecast.asked.withLock { $0.isEmpty })
        #expect(qw.lookups.withLock { $0.isEmpty })
        let w = r.data["weather"]
        #expect(w?["now"] == ["temperature_c": .int(19), "feels_like_c": .int(17), "humidity": .int(69), "weather": "少云",
                              "wind_kmh": .double(17.1)])
        #expect(w?["today"] == ["weather": "晴", "temp_high": .int(20), "temp_low": .int(10)])
        #expect(w?["day"] == "now" && r.data["date"] == "2026-11-13" && r.data["next"] == .string(ForecastWeather.nowNext))
    }

    @Test("T-046t F-18 §31 row 01 (§28 item 2): a failed daily answer leaves today out; the date is the phone's")
    func row01NoDaily() async {
        let qw = RecordingQWeather(days: [])
        let (ex, _, _, _, _) = forecastSetup(qweather: qw, now: placeNov13)
        let r = await ex.execute(weatherCall(["where": "珠海", "day": "now"]))
        #expect(r.ok && r.data["weather"]?["now"] != nil && r.data["weather"]?["today"] == nil && r.data["date"] == "2026-11-13")
    }

    @Test("T-046t F-18 §31 row 02: tomorrow is 2026-11-14 with day and night words; 11-20 that entry; 11-25 not out with 11月22日")
    func row02() async {
        let qw = RecordingQWeather()
        let (ex, _, _, _, forecast) = forecastSetup(qweather: qw, now: placeNov13)
        let t = await ex.execute(weatherCall(["where": "珠海", "day": "tomorrow"]))
        #expect(t.ok && t.data["date"] == "2026-11-14" && t.data["next"] == .string(ForecastWeather.next))
        let w = t.data["weather"]
        #expect(w?["weather_day"] == "小雨" && w?["weather_night"] == "多云" && w?["weather"] == "小雨")
        #expect(w?["temp_high"] == .int(21) && w?["temp_low"] == .int(11) && w?["rain_chance"] == .int(64) && w?["rain_mm"] == .double(1.5))
        #expect(w?["source"] == "qweather" && w?["weekday"] == "星期六")
        let d = await ex.execute(weatherCall(["where": "珠海", "date": "2026-11-20"]))
        #expect(d.ok && d.data["weather"]?["date"] == "2026-11-20" && d.data["weather"]?["temp_high"] == .int(27))
        let late = await ex.execute(weatherCall(["where": "珠海", "date": "2026-11-25"]))
        #expect(late.code == .liveInfoUnavailable && late.advice?.hasPrefix("预报只到11月22日") == true)
        #expect(qw.asked.withLock { $0 } == ["day 22.27,113.58", "day 22.27,113.58", "day 22.27,113.58"])
        #expect(forecast.asked.withLock { $0.isEmpty })
    }

    @Test("T-046t F-18 §31 row 03: place clock 14:20, afternoon: hours 14:00-17:00 with 和风 words, whole degrees, rain %")
    func row03() async {
        let qw = RecordingQWeather(hours: qweatherHours(), utcOffset: 0)
        let (ex, _, _, _, _) = forecastSetup(qweather: qw, now: placeNov13)
        let r = await ex.execute(weatherCall(["where": "珠海", "part": "afternoon"]))
        #expect(r.ok && r.data["next"] == .string(ForecastWeather.hoursNext) && r.data["weather"]?["source"] == "qweather")
        let hours = r.data["weather"]?["hours"]?.listValue ?? []
        #expect(hours.compactMap { $0["time"]?.stringValue } == ["14:00", "15:00", "16:00", "17:00"])
        #expect(hours.first == ["time": "14:00", "weather": "多云", "temp_c": .int(24), "rain_chance": .int(40)])
        #expect(hours.last?["weather"] == "小雨")
        #expect(qw.asked.withLock { $0 } == ["hours 22.27,113.58"])
    }

    @Test("T-046t F-18 §31 row 04: Tokyo JP is a 和风 lookup with range, then weather at its lat/lon; Macau without range")
    func row04() async {
        let qw = RecordingQWeather(places: [tokyoQW])
        let (ex, _, amap, foreign, forecast) = forecastSetup(qweather: qw, now: placeNov13)
        let r = await ex.execute(weatherCall(["where": "Tokyo", "country": "JP", "day": "today"]))
        #expect(r.ok && r.data["weather"]?["place"] == "东京" && r.data["weather"]?["country"] == "日本")
        #expect(qw.lookups.withLock { $0 } == ["Tokyo|JP"] && qw.asked.withLock { $0 } == ["day 35.69,139.69"])
        #expect(amap.asked.withLock { $0.isEmpty } && foreign.asked.withLock { $0.isEmpty } && forecast.asked.withLock { $0.isEmpty })
        qw.places = [macauQW]
        let m = await ex.execute(weatherCall(["where": "Macau"]))
        #expect(m.ok && m.data["weather"]?["place"] == "澳门" && m.data["weather"]?["country"] == nil)
        #expect(qw.lookups.withLock { $0.last } == "Macau|")
        // 澳门 with country MO: named 澳门, reason hkmo.
        let mo = await ex.execute(weatherCall(["where": "澳门", "country": "MO"]))
        #expect(mo.ok && mo.data["weather"]?["country"] == "澳门" && qw.lookups.withLock { $0.last } == "澳门|MO")
    }

    @Test("T-046t F-18 §31 row 05: an empty 和风 lookup is the not-found advice with no Open-Meteo call")
    func row05() async {
        let qw = RecordingQWeather(places: [])
        let (ex, _, _, foreign, forecast) = forecastSetup(qweather: qw)
        let r = await ex.execute(weatherCall(["where": "Nowhere", "country": "JP"]))
        #expect(r.code == .liveInfoUnavailable && r.advice == ForecastWeather.notFoundAdvice)
        #expect(foreign.asked.withLock { $0.isEmpty } && forecast.asked.withLock { $0.isEmpty } && qw.asked.withLock { $0.isEmpty })
        // A lookup that fails another way uses Open-Meteo geocoding (§31 item 5).
        let down = RecordingQWeather(lookupError: .http(503))
        let (ex2, _, _, foreign2, forecast2) = forecastSetup(qweather: down)
        let o = await ex2.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "today"]))
        #expect(o.ok && o.data["weather"]?["source"] == "open-meteo")
        #expect(foreign2.asked.withLock { $0 } == ["Oslo|NO"] && forecast2.asked.withLock { $0.count } == 1)
    }

    @Test("T-046t F-18 §31 row 06: no key, timeout, 401, 429, 503, unreadable: Open-Meteo at the same coordinates; qweather then open-meteo lines")
    func row06() async {
        let cases: [(QWeatherError?, String)] = [(nil, "nokey"), (.noKey, "nokey"), (.timeout, "timeout"), (.http(401), "http401"),
                                                 (.http(429), "http429"), (.http(503), "http503"), (.parse, "parse")]
        for (error, reason) in cases {
            let log = LogBox()
            let qw = error.map { RecordingQWeather(error: $0) }
            let (ex, _, _, _, forecast) = forecastSetup(qweather: qw, log: log)
            let r = await ex.execute(weatherCall(["where": "珠海", "day": "tomorrow"]))
            #expect(r.ok && r.data["weather"]?["source"] == "open-meteo", "\(reason)")
            #expect(forecast.asked.withLock { $0 } == [[22.27, 113.58]], "\(reason)")
            let lines = log.lines.withLock { $0 }
            #expect(lines.map(\.source) == ["qweather", "open-meteo"], "\(reason)")
            #expect(lines.first?.line.hasPrefix("weather source=qweather ok=no reason=\(reason) view=day lookup=amap ") == true, "\(reason)")
        }
    }

    @Test("T-046t F-18 §31 row 09: RuntimeLog lines after rows 1-6 have no place names, dates, coordinates or weather numbers")
    func row09() async {
        let log = LogBox()
        let qw = RecordingQWeather(hours: qweatherHours(), utcOffset: 0, places: [tokyoQW])
        let (ex, _, _, _, _) = forecastSetup(qweather: qw, log: log, now: placeNov13)
        for args: [String: JSONValue] in [["where": "珠海"], ["where": "珠海", "day": "tomorrow"], ["where": "珠海", "date": "2026-11-25"],
                                          ["where": "珠海", "part": "afternoon"], ["where": "Tokyo", "country": "JP"]] {
            _ = await ex.execute(weatherCall(args))
        }
        let (bad, _, _, _, _) = forecastSetup(qweather: RecordingQWeather(error: .http(503)), log: log)
        _ = await bad.execute(weatherCall(["where": "珠海"]))
        let lines = log.lines.withLock { $0.map(\.line) }
        #expect(lines.count == 7 && lines.contains { $0.hasPrefix("weather source=qweather ok=yes reason=ok view=hours lookup=amap") })
        #expect(lines.contains { $0.hasPrefix("weather source=qweather ok=yes reason=ok view=now lookup=qweather") })
        for line in lines {
            let codes = line.components(separatedBy: " attempts=")[0].replacingOccurrences(of: "http503", with: "")
            let hasNumber = codes.contains { $0.isNumber }
            #expect(!hasNumber, "\(line)")
            for word in ["珠海", "东京", "Tokyo", "日本", "11月", "22.27", "35.69", "°"] { #expect(!line.contains(word), "\(line)") }
        }
        #expect(!lines.contains { $0.contains("source=amap ok=yes") })
    }
}
