import NovaKit
import NovaPorts

/// T-033 / F-18 caches: adcodes for 30 min per ~1 km cell. (F-18 §31: 高德 weather is gone; 和风's answers are cached
/// 10 min in `QWeatherClient`.)
/// Only successful answers are cached; a failure is never remembered as an answer (I-3).
public actor LiveInfoCache: ReverseGeocoder {
    private let geocoder: any ReverseGeocoder
    private let clock: any NovaClock
    private let tuning: AmapWebTuning
    private var adcodes: [String: (String, NovaInstant)] = [:]

    public init(geocoder: any ReverseGeocoder, clock: any NovaClock,
                tuning: AmapWebTuning = AmapWebTuning()) {
        self.geocoder = geocoder
        self.clock = clock
        self.tuning = tuning
    }

    public func adcode(at coordinate: GeoCoordinate) async throws -> String? {
        // 0.01° is about 1 km: close enough for a district code.
        let key = "\((coordinate.latitude * 100).rounded())|\((coordinate.longitude * 100).rounded())"
        if let (code, at) = adcodes[key], clock.now - at < tuning.adcodeTTL { return code }
        guard let code = try await geocoder.adcode(at: coordinate) else { return nil }
        adcodes[key] = (code, clock.now)
        return code
    }

    /// F-16a 「我现在在哪？」: never cached, the street changes as the car moves.
    public func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        try await geocoder.address(at: coordinate)
    }
}
