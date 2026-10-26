import CoreLocation
import Foundation
import NovaKit
import NovaPorts

/// F-16 location (T-042): the latest CoreLocation fix as WGS-84; NovaNav judges freshness and converts
/// to GCJ-02. Permission is asked on first need (F-23): the first `latestFix()` requests When In Use.
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager = CLLocationManager()
    private let lock = NSLock()
    private let clock: SystemClock
    private var latest: LocationFix?
    private var started = false

    /// `clock` must be the clock that judges the fix (the navigation flow's).
    public init(clock: SystemClock) {
        self.clock = clock
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// Denied or restricted: features fall back to text search and say why (F-16 §3).
    public var denied: Bool {
        let status = manager.authorizationStatus
        return status == .denied || status == .restricted
    }

    public func latestFix() async -> LocationFix? {
        let start = lock.withLock { () -> Bool in
            defer { started = true }
            return !started
        }
        if start {
            await MainActor.run {
                if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
                manager.startUpdatingLocation()
            }
        }
        return lock.withLock { latest }
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

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
