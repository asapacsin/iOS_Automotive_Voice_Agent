import CoreLocation
import Foundation
import NovaKit
import NovaPorts

/// F-16 location (T-042, F-16a T-042a): the latest CoreLocation fix as WGS-84; NovaNav judges freshness and
/// converts to GCJ-02. Permission is asked on first need (F-23): the first `latestFix()` requests When In Use
/// and waits up to `firstFixWait` for the first fix instead of answering nil at once.
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private let clock: SystemClock
    private let firstFixWait: Duration
    private var latest: LocationFix?
    private var started = false

    /// `clock` must be the clock that judges the fix (the navigation flow's).
    public init(clock: SystemClock, firstFixWait: Duration = .seconds(3)) {
        self.clock = clock
        self.firstFixWait = firstFixWait
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Denied or restricted: features fall back to text search and say why (F-16 §3, F-16a §8).
    public var denied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    public func authorization() async -> LocationAuthorization {
        switch manager.authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .authorized
        }
    }

    /// Asks for When In Use now (设置 → 手机定位) and starts updates; no-op once started.
    public func start() async {
        let start = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        guard start else { return }
        await MainActor.run {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startUpdatingLocation()
        }
    }

    public func latestFix() async -> LocationFix? {
        await start()
        if let fix = lock.withLock({ latest }) { return fix }
        guard !denied else { return nil }
        // F-16a §4: the first request after start (or right after permission) waits for the first fix.
        let deadline = ContinuousClock.now + firstFixWait
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if let fix = lock.withLock({ latest }) { return fix }
            if denied { return nil }
        }
        return nil
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        // Age relative to now, expressed on the judging clock.
        let age = Int64(max(0, -location.timestamp.timeIntervalSinceNow) * 1000)
        let fix = LocationFix(coordinate: GeoCoordinate(latitude: location.coordinate.latitude,
                                                        longitude: location.coordinate.longitude, datum: .wgs84),
                              horizontalAccuracyMeters: location.horizontalAccuracy,
                              timestamp: clock.now - .milliseconds(age))
        lock.withLock { latest = fix }
    }

    /// F-16a §7: granted → updates (re)start; denied → the last fix is dropped so nothing stale is used.
    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            lock.withLock { latest = nil }
        default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
