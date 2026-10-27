import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaServices

final class CountingWeather: WeatherService, ReverseGeocoder, @unchecked Sendable {
    let calls = Mutex((weather: 0, regeo: 0))
    let fail = Mutex(false)
    func weather(adcode: String, forecast: Bool) async throws -> WeatherReport {
        calls.withLock { $0.weather += 1 }
        if fail.withLock({ $0 }) { throw AmapWebError.timeout }
        return WeatherReport(adcode: adcode, summary: "晴")
    }
    func adcode(at coordinate: GeoCoordinate) async throws -> String? {
        calls.withLock { $0.regeo += 1 }
        return "440402"
    }
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        PlaceAddress(formatted: "广东省珠海市香洲区情侣中路", district: "香洲区", road: "情侣中路")
    }
}

@Suite("T-033 F-18 live-info caches")
struct LiveInfoCacheTests {
    @Test("F-18 weather is cached 10 min and adcodes 30 min; failures are not cached")
    func ttl() async throws {
        let source = CountingWeather()
        let clock = ManualClock()
        let cache = LiveInfoCache(weather: source, geocoder: source, clock: clock)
        let here = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02)
        _ = try await cache.weather(adcode: "440402", forecast: false)
        clock.advance(by: .minutes(9))
        _ = try await cache.weather(adcode: "440402", forecast: false)
        #expect(source.calls.withLock { $0.weather } == 1)
        clock.advance(by: .minutes(1))
        source.fail.withLock { $0 = true }
        await #expect(throws: AmapWebError.self) { try await cache.weather(adcode: "440402", forecast: false) }
        source.fail.withLock { $0 = false }
        _ = try await cache.weather(adcode: "440402", forecast: false)
        #expect(source.calls.withLock { $0.weather } == 3)

        _ = try await cache.adcode(at: here)
        clock.advance(by: .minutes(29))
        _ = try await cache.adcode(at: here)
        #expect(source.calls.withLock { $0.regeo } == 1)
        clock.advance(by: .minutes(1))
        _ = try await cache.adcode(at: here)
        #expect(source.calls.withLock { $0.regeo } == 2)
    }

    @Test("F-16a 「我现在在哪？」: the cache passes the regeo address through (it used to answer nil)")
    func addressPassesThrough() async throws {
        let source = CountingWeather()
        let cache = LiveInfoCache(weather: source, geocoder: source, clock: ManualClock())
        let address = try await cache.address(at: GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02))
        #expect(address?.formatted == "广东省珠海市香洲区情侣中路")
    }
}
