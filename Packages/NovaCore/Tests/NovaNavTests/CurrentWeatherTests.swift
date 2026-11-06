import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaNav

/// F-18 §27 items 3-4 (T-046p): `now` on the place's today, and the new `next`.
@Suite("F-18 §27 the temperature now")
struct CurrentWeatherTests {
    static let osloNow = CurrentWeather(time: "2026-11-06T06:00", temperature: 0.9, feelsLike: -2.2, humidity: 81, weatherCode: 1,
                                        windKmh: 4.3)
    static let nextText = "只按 weather 里的数据用一两句话回答，说出地点和几月几号星期几；问现在几度时说现在的气温（now 里的 temperature_c，高德结果的 temperature_c），不要编造。"

    @Test("F-18 §27 row 2: today (no day or date, and date 2026-11-06) has now = 06:00, 1, -2, 81, 大致晴, 4.3; tomorrow has none")
    func row2() async {
        let (ex, _, _, _, _) = forecastSetup(current: Self.osloNow)
        let expected: JSONValue = ["time": "06:00", "temperature_c": .int(1), "feels_like_c": .int(-2), "humidity": .int(81),
                                   "weather": "大致晴", "wind_kmh": .double(4.3)]
        for args: [String: JSONValue] in [["where": "Oslo", "country": "NO"],
                                          ["where": "Oslo", "country": "NO", "date": "2026-11-06"]] {
            let r = await ex.execute(weatherCall(args))
            #expect(r.ok)
            let w = r.data["weather"]
            #expect(w?["now"] == expected)
            #expect(w?["date"] == "2026-11-06" && w?["temp_high"] == .int(10) && w?["source"] == "open-meteo")
            #expect(r.data["next"] == .string(Self.nextText))
        }
        let t = await ex.execute(weatherCall(["where": "Oslo", "country": "NO", "day": "tomorrow"]))
        #expect(t.ok && t.data["weather"]?["date"] == "2026-11-07" && t.data["weather"]?["now"] == nil)
    }

    @Test("F-18 §27 row 3: no current block gives today's values without now and no error")
    func row3() async {
        let (ex, _, _, _, _) = forecastSetup(current: nil)
        let r = await ex.execute(weatherCall(["where": "Oslo", "country": "NO"]))
        #expect(r.ok && r.data["weather"]?["date"] == "2026-11-06" && r.data["weather"]?["now"] == nil)
        #expect(r.data["weather"]?["temp_high"] == .int(10))
    }

    @Test("F-18 §27 row 4: 高德 today for 横琴 is as before, with the item 4 next")
    func row4() async {
        let hengqin = LookedUpPlace(name: "珠海市", coordinate: GeoCoordinate(latitude: 22.13, longitude: 113.52, datum: .gcj02),
                                    formatted: "广东省珠海市香洲区横琴镇", adcode: "440404")
        let (ex, weather, _, _, forecast) = forecastSetup(amap: [hengqin], current: Self.osloNow)
        let r = await ex.execute(weatherCall(["where": "横琴"]))
        #expect(r.ok && weather.calls.withLock { $0 } == 1 && forecast.asked.withLock { $0.isEmpty })
        #expect(r.data["weather"]?["source"] == "amap" && r.data["weather"]?["now"] == nil)
        #expect(r.data["next"] == .string(Self.nextText) && ForecastWeather.next == Self.nextText)
    }
}
