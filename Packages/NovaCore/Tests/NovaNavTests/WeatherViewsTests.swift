import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// Hourly entries from `first` 00:00 for `days` days; hour h has temp 10+h, code 61 after 15:00, rain 10·(h % 10).
func forecastHours(from first: String, days: Int = 16) -> [HourlyForecast] {
    let start = ForecastWeather.isoDay(first)!
    return (0..<days).flatMap { d in
        (0..<24).map { h in
            HourlyForecast(time: ForecastWeather.adding(d, to: start).iso + String(format: "T%02d:00", h),
                           weatherCode: h > 15 ? 61 : 1, temperature: 10.2 + Double(h), rainChance: Double(10 * (h % 10)))
        }
    }
}

extension JSONValue {
    var listValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
}

/// 2026-11-09 14:20 UTC; with a UTC offset of 0 the place's clock reads the same.
let placeNov9 = Date(timeIntervalSince1970: 1_794_234_000)

/// F-18 §28 (T-046q): now, a whole day and part of a day are separate answers.
@Suite("T-046q F-18 §28 weather now, a day and part of a day")
struct WeatherViewsTests {
    static let osloNow = CurrentWeather(time: "2026-11-06T06:00", temperature: 0.9, feelsLike: -2.2, humidity: 81, weatherCode: 1,
                                        windKmh: 4.3)
    static let nowNext = "先说现在：地点、现在的天气和气温（now）；再用半句说今天的最高和最低气温（today）。一两句话，不说日期，不要编造。"
    static let dayNext = "只按 weather 里的数据用一两句话回答，说出地点和几月几号星期几，不要编造。"
    static let hoursNext = "只按 hours 用一两句话回答这段时间：会不会下雨（rain_chance）和气温范围，说出地点和是哪天的上午、下午或晚上，不要编造。"

    @Test("T-046q F-18 §28 row 4: Open-Meteo Oslo: now and today; today only; tomorrow only; no current block")
    func row4() async {
        let (ex, _, _, _, _) = forecastSetup(current: Self.osloNow)
        let n = await ex.execute(weatherCall(["where": "Oslo", "country": "NO"]))
        #expect(n.ok && n.data["next"] == .string(Self.nowNext))
        #expect(n.data["weather"]?["now"] == ["time": "06:00", "temperature_c": .int(1), "feels_like_c": .int(-2), "humidity": .int(81),
                                              "weather": "大致晴", "wind_kmh": .double(4.3)])
        #expect(n.data["weather"]?["today"] == ["weather": "阴", "temp_high": .int(10), "temp_low": .int(-1)])
        #expect(n.data["weather"]?["day"] == "now" && n.data["weather"]?["source"] == "open-meteo" && n.data["date"] == "2026-11-06")
        let t = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "today"]))
        #expect(t.ok && t.data["weather"]?["now"] == nil && t.data["weather"]?["date"] == "2026-11-06" && t.data["next"] == .string(Self.dayNext))
        let m = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "tomorrow"]))
        #expect(m.ok && m.data["weather"]?["now"] == nil && m.data["weather"]?["date"] == "2026-11-07")
        let (bare, _, _, _, _) = forecastSetup(current: nil)
        let b = await bare.execute(weatherCall(["where": "Oslo", "country": "NO"]))
        #expect(b.ok && b.data["weather"]?["now"] == nil && b.data["weather"]?["date"] == "2026-11-06")
        #expect(b.data["weather"]?["temp_high"] == .int(10) && b.data["next"] == .string(Self.dayNext))
    }

    func hoursSetup(amap: [LookedUpPlace] = [zhuhaiCity], log: LogBox = LogBox())
        -> (LiveInfoExecutor, RecordingQWeather?, RecordingForecast) {
        let (ex, weather, _, _, forecast) = forecastSetup(amap: amap, days: forecastDays(from: "2026-11-09"), log: log,
                                                          hours: forecastHours(from: "2026-11-09"), utcOffset: 0, now: placeNov9)
        return (ex, weather, forecast)
    }

    @Test("T-046q F-18 §28 row 5: place clock 14:20: afternoon 14-17; morning has passed; tomorrow morning 06-11")
    func row5() async {
        let (ex, _, _) = hoursSetup()
        let a = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "part": "afternoon"]))
        #expect(a.ok && a.data["next"] == .string(Self.hoursNext))
        let times = a.data["weather"]?["hours"]?.listValue?.compactMap { $0["time"]?.stringValue }
        #expect(times == ["14:00", "15:00", "16:00", "17:00"])
        #expect(a.data["weather"]?["hours"]?.listValue?.first == ["time": "14:00", "weather": "大致晴", "temp_c": .int(24), "rain_chance": .int(40)])
        #expect(a.data["weather"]?["part"] == "afternoon" && a.data["weather"]?["date"] == "2026-11-09" && a.data["weather"]?["weekday"] == "星期一")
        let m = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "part": "morning"]))
        #expect(!m.ok && m.code == .liveInfoUnavailable && m.advice == "这段时间已经过去了。请如实说明，可以说现在的天气。")
        let t = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "tomorrow", "part": "morning"]))
        #expect(t.ok && t.data["weather"]?["date"] == "2026-11-10")
        #expect(t.data["weather"]?["hours"]?.listValue?.compactMap { $0["time"]?.stringValue } == ["06:00", "07:00", "08:00", "09:00", "10:00", "11:00"])
        let late = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "date": "2026-11-30", "part": "evening"]))
        #expect(!late.ok && late.advice == ForecastWeather.notOutAdvice(last: SearchDate.Day(year: 2026, month: 11, day: 24)))
    }

    @Test("T-046q F-18 §28 row 6: 横琴 afternoon: Open-Meteo at 高德's coordinates rounded; hours; no 高德 weather call")
    func row6() async {
        let hengqin = LookedUpPlace(name: "珠海市", coordinate: GeoCoordinate(latitude: 22.1312, longitude: 113.5249, datum: .gcj02),
                                    formatted: "广东省珠海市香洲区横琴镇", adcode: "440404")
        let (ex, _, forecast) = hoursSetup(amap: [hengqin])
        let r = await ex.execute(weatherCall(["where": "横琴", "part": "afternoon"]))
        #expect(r.ok && r.data["weather"]?["source"] == "open-meteo" && r.data["weather"]?["hours"] != nil)
        #expect(forecast.asked.withLock { $0 } == [[22.13, 113.52]])
    }

    @Test("T-046q F-18 §28 row 14 (unit part): 「下午会下雨吗」 at the current location names the regeo district, not here")
    func herePart() async {
        let (ex, _, forecast) = hoursSetup()
        let r = await ex.execute(weatherCall(["part": "afternoon"]))
        #expect(r.ok && r.data["weather"]?["place"] == "香洲区" && forecast.asked.withLock { $0.count } == 1)
    }

    @Test("T-046q F-18 §28 row 7: part with day=now, or an unknown part, is INVALID_ARGUMENT with the item 1 advice")
    func row7() async {
        let (ex, _, _, _, _) = forecastSetup()
        for args: [String: JSONValue] in [["where": "珠海", "part": "afternoon", "day": "now"], ["where": "珠海", "part": "night"]] {
            let r = await ex.execute(weatherCall(args))
            #expect(r.code == .invalidArgument)
            #expect(r.advice == "日期用 yyyy-MM-dd（只填 day 或 date 其中一个）；国外地点 country 填两个大写字母，例如 NO。part 只能是 morning、afternoon、evening，不能和 day=now 一起用。")
        }
        #expect(ToolCatalog.validate(weatherCall(["part": "afternoon"])) == nil)
    }

    @Test("T-046q F-18 §28 row 9: day and part arguments and their descriptions are exactly item 1")
    func row9() {
        let props = ToolCatalog.spec("query_live_info")!.declaration.parametersJSONSchema["properties"]
        #expect(props?["day"]?["description"] == "现在的天气、现在几度填 now；今天一整天填 today；明天 tomorrow，后天 day_after，大后天 day_after_next。")
        #expect(props?["part"]?["enum"] == ["morning", "afternoon", "evening"])
        #expect(props?["part"]?["description"] == "问上午、下午、晚上时填 morning、afternoon、evening，可以和 day 或 date 一起用。")
    }

}
