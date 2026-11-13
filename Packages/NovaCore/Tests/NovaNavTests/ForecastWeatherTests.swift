import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// Records each lookup; answers with `places`.
final class RecordingLookup: PlaceLookup, @unchecked Sendable {
    let places: [LookedUpPlace]
    let asked = Mutex<[String]>([])
    init(_ places: [LookedUpPlace]) { self.places = places }
    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        asked.withLock { $0.append("\(name)|\(country ?? "")") }
        return places
    }
}

/// Records each forecast call; answers with `days` and `current` (§27 item 2).
final class RecordingForecast: DailyForecastService, @unchecked Sendable {
    let days: [DailyForecastDay]
    let current: CurrentWeather?
    let hours: [HourlyForecast]
    let utcOffset: Int?
    var error: ForecastError?
    let asked = Mutex<[[Double]]>([])
    init(_ days: [DailyForecastDay], current: CurrentWeather? = nil, error: ForecastError? = nil, hours: [HourlyForecast] = [],
         utcOffset: Int? = nil) {
        self.days = days
        self.current = current
        self.error = error
        self.hours = hours
        self.utcOffset = utcOffset
    }
    func dailyForecast(latitude: Double, longitude: Double) async throws -> DailyForecast {
        asked.withLock { $0.append([latitude, longitude]) }
        if let error { throw error }
        return DailyForecast(days: days, current: current, hours: hours, utcOffsetSeconds: utcOffset)
    }
}

/// 16 days from `first` (`yyyy-MM-dd`); day i has code `codes[i % codes.count]`, high 10+i.
func forecastDays(from first: String = "2026-11-06", count: Int = 16) -> [DailyForecastDay] {
    let start = ForecastWeather.isoDay(first)!
    return (0..<count).map { i in
        DailyForecastDay(time: ForecastWeather.adding(i, to: start).iso, weatherCode: [3, 61, 0][i % 3],
                         tempMax: 10.4 + Double(i), tempMin: -0.6 + Double(i), rainChance: Double(10 * (i % 10)),
                         rainMm: 0.5, windMaxKmh: 12.3)
    }
}

/// 2026-11-06 12:00 in Asia/Shanghai.
let phoneNov6 = Date(timeIntervalSince1970: 1_793_937_600)

let oslo = LookedUpPlace(name: "奥斯陆", country: "挪威", coordinate: GeoCoordinate(latitude: 59.91273, longitude: 10.74609, datum: .wgs84),
                         population: 580_000)
let zhuhaiCity = LookedUpPlace(name: "珠海市", coordinate: GeoCoordinate(latitude: 22.270978, longitude: 113.576677, datum: .gcj02),
                           formatted: "广东省珠海市", adcode: "440400")

final class LogBox: @unchecked Sendable { let lines = Mutex<[WeatherSourceLog]>([]) }

func forecastSetup(amap: [LookedUpPlace] = [zhuhaiCity], foreign: [LookedUpPlace] = [oslo], days: [DailyForecastDay] = forecastDays(),
                   weather: (any WeatherService)? = nil, log: LogBox = LogBox(), forecastError: ForecastError? = nil,
                   current: CurrentWeather? = nil, hours: [HourlyForecast] = [], utcOffset: Int? = nil,
                   now: Date = phoneNov6)
    -> (LiveInfoExecutor, CountingWeather, RecordingLookup, RecordingLookup, RecordingForecast) {
    let location = FixedLocation()
    let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []), location: location,
                                   clock: ManualClock())
    let counting = CountingWeather()
    let amapLookup = RecordingLookup(amap), foreignLookup = RecordingLookup(foreign)
    let forecast = RecordingForecast(days, current: current, error: forecastError, hours: hours, utcOffset: utcOffset)
    let executor = LiveInfoExecutor(navigation: nav, weather: weather ?? counting, geocoder: FakeGeocoder(), location: location,
                                    now: { now }, zone: { shanghai }, amapLookup: amapLookup, forecastLookup: foreignLookup,
                                    forecast: forecast, onWeather: { l in log.lines.withLock { $0.append(l) } })
    return (executor, counting, amapLookup, foreignLookup, forecast)
}

func weatherCall(_ args: [String: JSONValue]) -> ToolCall { liveCall(args.merging(["kind": "weather"]) { a, _ in a }) }

@Suite("T-046o F-18 §26 weather for 16 days from Open-Meteo")
struct ForecastWeatherTests {
    @Test("T-046o F-18 §26 row 01: Oslo date 2026-11-12 is that day's values, 星期四, open-meteo; tomorrow is 2026-11-07")
    func row01() async {
        let (ex, _, amap, _, _) = forecastSetup()
        let r = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-12"]))
        #expect(r.ok)
        let w = r.data["weather"]
        #expect(w?["date"] == "2026-11-12" && w?["weekday"] == "星期四" && w?["source"] == "open-meteo")
        // Day 6 of the fixture: code 3 (阴), high 16.4 → 16, low 5.4 → 5.
        #expect(w?["weather"] == "阴" && w?["temp_high"] == .int(16) && w?["temp_low"] == .int(5))
        #expect(w?["place"] == "奥斯陆" && w?["country"] == "挪威")
        #expect(w?["rain_chance"] == .int(60) && w?["rain_mm"] == .double(0.5) && w?["wind_max_kmh"] == .double(12.3))
        #expect(r.data["next"] == .string(ForecastWeather.next))
        #expect(r.data["next"] == "只按 weather 里的数据用一两句话回答，说出地点和几月几号星期几，不要编造。")
        let t = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "tomorrow"]))
        #expect(t.ok && t.data["weather"]?["date"] == "2026-11-07" && t.data["weather"]?["weekday"] == "星期六")
        #expect(amap.asked.withLock { $0.isEmpty })
    }

    @Test("F-18 §26 row 01: `day` counts from time[0], the place's own today, not the phone's")
    func row01PlaceToday() async {
        let (ex, _, _, _, _) = forecastSetup(days: forecastDays(from: "2026-11-05"))
        let t = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "tomorrow"]))
        #expect(t.data["weather"]?["date"] == "2026-11-06")
    }

    @Test("F-18 §26 row 02: before time[0] is the past advice; after the last time is the not-out advice with 11月21日")
    func row02() async {
        let (ex, _, _, _, _) = forecastSetup()
        let past = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-05"]))
        #expect(past.code == .liveInfoUnavailable && past.advice == "过去的天气查不到，请如实说明。")
        let late = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-30"]))
        #expect(late.code == .liveInfoUnavailable)
        #expect(late.advice == "预报只到11月21日，这一天的预报还没出来。请如实说还没有预报，不要用 web_search 查这一天的预报。可以说这个时候一般的气温，并说明不是预报。")
    }

    @Test("F-18 §26 row 03: day+date, bad dates, bad country, country with here: INVALID_ARGUMENT with the item 1 advice")
    func row03() async {
        let (ex, weather, amap, foreign, forecast) = forecastSetup()
        let bad: [[String: JSONValue]] = [
            ["where": "珠海", "day": "tomorrow", "date": "2026-11-07"],
            ["where": "珠海", "date": "11/12"], ["where": "珠海", "date": "2026-02-30"],
            ["where": "Oslo", "country": "no"], ["where": "Oslo", "country": "NOR"],
            ["where": "here", "country": "NO"], ["country": "NO"], ["where": "destination", "country": "NO"],
        ]
        for args in bad {
            let r = await ex.execute(weatherCall(args))
            #expect(r.code == .invalidArgument, "\(args)")
            #expect(r.advice == "日期用 yyyy-MM-dd（只填 day 或 date 其中一个）；国外地点 country 填两个大写字母，例如 NO。part 只能是 morning、afternoon、evening，不能和 day=now 一起用。")
        }
        #expect(weather.calls.withLock { $0 } == 0 && amap.asked.withLock { $0.isEmpty } && foreign.asked.withLock { $0.isEmpty })
        #expect(forecast.asked.withLock { $0.isEmpty })
        // The catalog lets date and country through to these checks; `where` may be 40 long.
        #expect(ToolCatalog.validate(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-12"])) == nil)
        #expect(ToolCatalog.validate(weatherCall(["where": .string(String(repeating: "a", count: 40))])) == nil)
        #expect(ToolCatalog.validate(weatherCall(["where": .string(String(repeating: "a", count: 41))])) == .invalidArgument)
    }

    @Test("F-18 §26 row 04: which source answers, phone date 2026-11-06")
    func row04() async {
        // 珠海 day_after: 高德 only.
        do {
            let (ex, weather, amap, foreign, forecast) = forecastSetup()
            let r = await ex.execute(weatherCall(["where": "珠海", "day": "day_after"]))
            #expect(r.ok && r.data["weather"]?["source"] == "amap" && r.data["weather"]?["weekday"] == "星期日")
            #expect(r.data["date"] == "2026-11-08" && r.data["next"] == .string(ForecastWeather.next))
            #expect(weather.days.withLock { $0 } == [WeatherDay(offset: 2, date: "2026-11-08")])
            #expect(weather.calls.withLock { $0 } == 1 && amap.asked.withLock { $0 } == ["珠海|"])
            #expect(foreign.asked.withLock { $0.isEmpty } && forecast.asked.withLock { $0.isEmpty })
        }
        // 珠海 date 2026-11-12: 高德 geocode, then Open-Meteo at coordinates rounded to 2 decimals.
        do {
            let (ex, weather, amap, foreign, forecast) = forecastSetup()
            let r = await ex.execute(weatherCall(["where": "珠海", "date": "2026-11-12"]))
            #expect(r.ok && r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["place"] == "珠海市")
            #expect(r.data["weather"]?["country"] == nil)
            #expect(weather.calls.withLock { $0 } == 0 && amap.asked.withLock { $0.count } == 1 && foreign.asked.withLock { $0.isEmpty })
            #expect(forecast.asked.withLock { $0 } == [[22.27, 113.58]])
        }
        // 珠海 day_after_next with no 高德 cast: Open-Meteo.
        do {
            let (ex, _, _, _, forecast) = forecastSetup(weather: CastsWeather(casts: ["2026-11-07"]))
            let r = await ex.execute(weatherCall(["where": "珠海", "day": "day_after_next"]))
            #expect(r.ok && r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["date"] == "2026-11-09")
            #expect(forecast.asked.withLock { $0.count } == 1)
        }
        // Oslo NO: Open-Meteo geocoding and forecast, no 高德.
        do {
            let (ex, weather, amap, foreign, forecast) = forecastSetup()
            let r = await ex.execute(weatherCall(["where": "Oslo", "country": "NO"]))
            #expect(r.ok && r.data["weather"]?["date"] == "2026-11-06")
            #expect(foreign.asked.withLock { $0 } == ["Oslo|NO"] && forecast.asked.withLock { $0 } == [[59.91, 10.75]])
            #expect(weather.calls.withLock { $0 } == 0 && amap.asked.withLock { $0.isEmpty })
        }
        // 澳门 MO: Open-Meteo since §29 item 1 (T-046r); no 高德 at all.
        do {
            let macau = LookedUpPlace(name: "澳门", country: "中国澳门", coordinate: GeoCoordinate(latitude: 22.16, longitude: 113.56, datum: .wgs84),
                                      population: 680_000, countryCode: "MO")
            let (ex, weather, amap, foreign, forecast) = forecastSetup(foreign: [macau])
            let r = await ex.execute(weatherCall(["where": "澳门", "country": "MO", "day": "today"]))
            #expect(r.ok && r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["country"] == "澳门")
            #expect(weather.calls.withLock { $0 } == 0 && amap.asked.withLock { $0.isEmpty })
            #expect(foreign.asked.withLock { $0 } == ["澳门|MO"] && forecast.asked.withLock { $0.count } == 1)
        }
    }

    @Test("F-18 §26 row 05: 奥斯陆 → 湖里区 fails the name check with no forecast call; 珠海横琴 → 横琴镇 passes")
    func row05() async {
        let huli = LookedUpPlace(name: "厦门市", coordinate: GeoCoordinate(latitude: 24.5, longitude: 118.1, datum: .gcj02),
                                 formatted: "福建省厦门市湖里区", adcode: "350206")
        let (ex, weather, _, _, forecast) = forecastSetup(amap: [huli])
        let r = await ex.execute(weatherCall(["where": "奥斯陆", "date": "2026-11-12"]))
        #expect(r.code == .liveInfoUnavailable)
        #expect(r.advice == "高德没有找到这个地点。如果是国外的地方，用英文名并填 country 再调用一次，例如 where=Oslo, country=NO。")
        #expect(weather.calls.withLock { $0 } == 0 && forecast.asked.withLock { $0.isEmpty })
        let hengqin = LookedUpPlace(name: "珠海市", coordinate: GeoCoordinate(latitude: 22.13, longitude: 113.52, datum: .gcj02),
                                    formatted: "广东省珠海市香洲区横琴镇", adcode: "440404")
        let (ok, w2, _, _, _) = forecastSetup(amap: [hengqin])
        let passed = await ok.execute(weatherCall(["where": "珠海横琴", "day": "tomorrow"]))
        #expect(passed.ok && w2.calls.withLock { $0 } == 1)
        #expect(ForecastWeather.nameMatches("珠海市横琴镇", formatted: "广东省珠海市香洲区横琴镇"))
        #expect(!ForecastWeather.nameMatches("奥斯陆", formatted: "福建省厦门市湖里区"))
    }

    @Test("F-18 §26 row 06: the largest population is picked; no result is the not-found advice")
    func row06() async {
        func at(_ lat: Double) -> GeoCoordinate { GeoCoordinate(latitude: lat, longitude: 140.87, datum: .wgs84) }
        let several = [LookedUpPlace(name: "A", country: "日本", coordinate: at(1), population: 1000),
                       LookedUpPlace(name: "仙台", country: "日本", coordinate: at(38.27), population: 1_063_103),
                       LookedUpPlace(name: "B", country: "日本", coordinate: at(3), population: nil),
                       LookedUpPlace(name: "C", country: "日本", coordinate: at(4), population: 1_063_103)]
        let (ex, _, _, _, forecast) = forecastSetup(foreign: several)
        let r = await ex.execute(weatherCall(["where": "Sendai", "country": "JP"]))
        #expect(r.ok && r.data["weather"]?["place"] == "仙台" && forecast.asked.withLock { $0 } == [[38.27, 140.87]])
        #expect(ForecastWeather.pick([LookedUpPlace(name: "x", coordinate: nil), LookedUpPlace(name: "y", coordinate: nil)])?.name == "x")
        let (none, _, _, _, f2) = forecastSetup(foreign: [])
        let n = await none.execute(weatherCall(["where": "Nowhere", "country": "JP"]))
        #expect(n.code == .liveInfoUnavailable && n.advice == "没有找到这个地点。请用一句话如实说没找到，问一下是哪里。")
        #expect(f2.asked.withLock { $0.isEmpty })
    }

    @Test("F-18 §26 row 07: every WMO code in item 7 has its words; code 4 is 未知")
    func row07() {
        let table: [Int: String] = [
            0: "晴", 1: "大致晴", 2: "局部多云", 3: "阴", 45: "雾", 48: "雾凇", 51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
            56: "冻毛毛雨", 57: "冻毛毛雨", 61: "小雨", 63: "中雨", 65: "大雨", 66: "冻雨", 67: "冻雨", 71: "小雪", 73: "中雪",
            75: "大雪", 77: "雪粒", 80: "小阵雨", 81: "阵雨", 82: "强阵雨", 85: "小阵雪", 86: "大阵雪", 95: "雷阵雨",
            96: "雷阵雨伴有冰雹", 99: "雷阵雨伴有冰雹",
        ]
        for (code, words) in table { #expect(ForecastWeather.words(code) == words, "\(code)") }
        #expect(ForecastWeather.wmo.count == table.count)
        #expect(ForecastWeather.words(4) == "未知" && ForecastWeather.words(nil) == "未知")
    }

    @Test("F-18 §26 row 04: a forecast timeout is LIVE_INFO_UNAVAILABLE with the weather failure advice")
    func timeout() async {
        let (ex, _, _, _, _) = forecastSetup(forecastError: .timeout)
        let r = await ex.execute(weatherCall(["where": "Oslo", "country": "NO"]))
        #expect(r.code == .liveInfoUnavailable && r.advice == "天气没有查到。请如实说明，不要编造。")
    }

    @Test("F-18 §26 row 09: the query_live_info arguments and description are exactly items 1 and 8; 设置 credit")
    func row09Catalog() {
        let d = ToolCatalog.spec("query_live_info")!.declaration
        let props = d.parametersJSONSchema["properties"]
        #expect(props?["where"]?["maxLength"] == .int(40))
        #expect(props?["where"]?["description"] == "here=当前位置，destination=导航目的地，或地名。中国（含香港、澳门）用中文；国外用英文名并填 country，例如 Oslo、Sendai。")
        #expect(props?["day"]?["enum"] == ["now", "today", "tomorrow", "day_after", "day_after_next"])
        #expect(props?["date"] == ["type": "string", "description": "说几号或星期几时填，yyyy-MM-dd。"])
        #expect(props?["country"] == ["type": "string", "description": "国外地点的国家代码，例如 NO、JP、US。中国、香港、澳门不填。"])
        #expect(d.description.contains("weather：任何地方现在的天气，和今后16天内任何一天、上午下午晚上的天气预报。「现在天气怎么样」「外面几度」→where=here, day=now；「今天天气怎么样」→day=today；「下午会下雨吗」→part=afternoon；「目的地会下雨吗」→destination；「珠海天气」→珠海；明天、后天、大后天用 day；说几号或星期几用 date（yyyy-MM-dd），不知道今天几号先调用 current_time；国外地点用英文名并填 country：「奥斯陆11月12日天气」→where=Oslo, country=NO, date=2026-11-12。"))
        #expect(!d.description.contains("问明天加 day=tomorrow"))
        #expect(ForecastWeather.credit == "天气数据：Open-Meteo.com（CC BY 4.0）")
    }

    @Test("F-18 §26 row 10: RuntimeLog lines after rows 1-6 have no place names, dates or coordinates")
    func row10() async {
        let log = LogBox()
        let huli = LookedUpPlace(name: "厦门市", coordinate: GeoCoordinate(latitude: 24.5, longitude: 118.1, datum: .gcj02),
                                 formatted: "福建省厦门市湖里区", adcode: "350206")
        let (ex, _, _, _, _) = forecastSetup(log: log)
        for args: [String: JSONValue] in [["where": "Oslo", "country": "NO", "date": "2026-11-12"],
                                          ["where": "Oslo", "country": "NO", "date": "2026-11-05"],
                                          ["where": "Oslo", "country": "NO", "date": "2026-11-30"],
                                          ["where": "珠海", "day": "day_after"], ["where": "珠海", "date": "2026-11-12"]] {
            _ = await ex.execute(weatherCall(args))
        }
        let (bad, _, _, _, _) = forecastSetup(amap: [huli], foreign: [], log: log)
        _ = await bad.execute(weatherCall(["where": "奥斯陆"]))
        _ = await bad.execute(weatherCall(["where": "Sendai", "country": "JP"]))
        let lines = log.lines.withLock { $0.map(\.line) }
        #expect(lines.count == 7)
        #expect(lines.contains { $0.hasPrefix("weather source=open-meteo ok=yes reason=ok view=day lookup=") } && lines.contains { $0.hasPrefix("weather source=amap ok=yes reason=ok view=day lookup=") })
        for line in lines {
            // §30 item 5: only `attempts=` and `ms=` carry numbers.
            let codes = line.components(separatedBy: " attempts=")[0]
            #expect(line.hasPrefix("weather source=") && !codes.contains(where: \.isNumber), "\(line)")
            for word in ["Oslo", "奥斯陆", "珠海", "厦门", "湖里", "Sendai", "挪威", "11月"] { #expect(!line.contains(word)) }
        }
    }
}
