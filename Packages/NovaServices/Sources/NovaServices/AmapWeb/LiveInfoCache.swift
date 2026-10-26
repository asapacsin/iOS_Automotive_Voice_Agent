import NovaKit
import NovaPorts

/// T-033 / F-18 caches: weather for 10 min per (adcode, day), adcodes for 30 min per ~1 km cell.
/// Only successful answers are cached; a failure is never remembered as an answer (I-3).
public actor LiveInfoCache: WeatherService, ReverseGeocoder {
    private let weather: any WeatherService
    private let geocoder: any ReverseGeocoder
    private let clock: any NovaClock
    private let tuning: AmapWebTuning
    private var reports: [String: (WeatherReport, NovaInstant)] = [:]
    private var adcodes: [String: (String, NovaInstant)] = [:]

    public init(weather: any WeatherService, geocoder: any ReverseGeocoder, clock: any NovaClock,
                tuning: AmapWebTuning = AmapWebTuning()) {
        self.weather = weather
        self.geocoder = geocoder
        self.clock = clock
        self.tuning = tuning
    }

    public func weather(adcode: String, forecast: Bool) async throws -> WeatherReport {
        let key = "\(adcode)|\(forecast)"
        if let (report, at) = reports[key], clock.now - at < tuning.weatherTTL { return report }
        let report = try await weather.weather(adcode: adcode, forecast: forecast)
        reports[key] = (report, clock.now)
        return report
    }

    public func adcode(at coordinate: GeoCoordinate) async throws -> String? {
        // 0.01° is about 1 km: close enough for a district code.
        let key = "\((coordinate.latitude * 100).rounded())|\((coordinate.longitude * 100).rounded())"
        if let (code, at) = adcodes[key], clock.now - at < tuning.adcodeTTL { return code }
        guard let code = try await geocoder.adcode(at: coordinate) else { return nil }
        adcodes[key] = (code, clock.now)
        return code
    }
}
