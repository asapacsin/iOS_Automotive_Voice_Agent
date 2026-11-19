import Foundation
import Synchronization
import NovaKit
import NovaPorts
@testable import NovaNav

/// F-18 §31 (T-046t): a recording 和风 fake. Each forecast call is recorded as `<request> <lat>,<lon>`, each lookup as
/// `<name>|<country>`.
final class RecordingQWeather: ViewForecastService, @unchecked Sendable {
    var days: [DailyForecastDay]
    var current: CurrentWeather?
    var hours: [HourlyForecast]
    var utcOffset: Int?
    var error: QWeatherError?
    var places: [LookedUpPlace]
    var lookupError: QWeatherError?
    let asked = Mutex<[String]>([])
    let lookups = Mutex<[String]>([])

    init(days: [DailyForecastDay] = qweatherDays(), current: CurrentWeather? = qweatherNow, hours: [HourlyForecast] = [],
         utcOffset: Int? = nil, error: QWeatherError? = nil, places: [LookedUpPlace] = [], lookupError: QWeatherError? = nil) {
        self.days = days
        self.current = current
        self.hours = hours
        self.utcOffset = utcOffset
        self.error = error
        self.places = places
        self.lookupError = lookupError
    }

    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        lookups.withLock { $0.append(name + "|" + (country ?? "")) }
        if let lookupError { throw lookupError }
        if places.isEmpty { throw QWeatherError.notFound }
        return places
    }

    func forecast(latitude: Double, longitude: Double, request: ForecastRequest) async throws -> DailyForecast {
        asked.withLock { $0.append("\(request.rawValue) \(latitude),\(longitude)") }
        if let error { throw error }
        switch request {
        case .now: return DailyForecast(days: Array(days.prefix(1)), current: current)
        case .day: return DailyForecast(days: days)
        case .hours: return DailyForecast(days: [], hours: hours, utcOffsetSeconds: utcOffset)
        }
    }
}

/// 10 days from `first`; day i: 晴/小雨, high 20+i, low 10+i, rain 30% (day) and 64% (night) → 64, 1.5 mm.
func qweatherDays(from first: String = "2026-11-13", count: Int = 10) -> [DailyForecastDay] {
    let start = ForecastWeather.isoDay(first)!
    return (0..<count).map { i in
        DailyForecastDay(time: ForecastWeather.adding(i, to: start).iso, weatherCode: nil, tempMax: 20.4 + Double(i),
                         tempMin: 10.4 + Double(i), rainChance: 64, rainMm: 1.5, windMaxKmh: 17.1,
                         dayText: i % 2 == 0 ? "晴" : "小雨", nightText: "多云")
    }
}

let qweatherNow = CurrentWeather(time: "", temperature: 18.6, feelsLike: 17.2, humidity: 69, weatherCode: nil, windKmh: 17.1, text: "少云")

/// 高德 geocoding that finds any Chinese name (formatted = the name), at 珠海's coordinates.
struct EchoLookup: PlaceLookup {
    var adcode = "440402"
    func lookUp(_ name: String, country: String?) async throws -> [LookedUpPlace] {
        [LookedUpPlace(name: name, coordinate: GeoCoordinate(latitude: 22.270978, longitude: 113.576677, datum: .gcj02),
                       formatted: name, adcode: adcode)]
    }
}
