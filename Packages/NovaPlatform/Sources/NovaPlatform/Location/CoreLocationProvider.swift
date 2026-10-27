#if canImport(CoreLocation)
import CoreLocation
import Foundation
import NovaKit
import NovaPorts

/// The part of `CLLocationManager` the provider uses, so a fake manager can stand in for it in tests
/// (F-16a §10 row 6).
public protocol LocationManaging: AnyObject {
    var delegate: (any CLLocationManagerDelegate)? { get set }
    var authorizationStatus: CLAuthorizationStatus { get }
    var desiredAccuracy: CLLocationAccuracy { get set }
    func requestWhenInUseAuthorization()
    func startUpdatingLocation()
    func stopUpdatingLocation()
}

extension CLLocationManager: LocationManaging {}

/// F-16 location (T-042, F-16a T-042a): the latest CoreLocation fix as WGS-84; NovaNav judges freshness and
/// converts to GCJ-02. Permission is asked on first need (F-23): the first `latestFix()` requests When In Use
/// and waits up to `firstFixWait` for a fresh fix instead of answering nil (or an old fix) at once.
/// Updates pause in the background and resume in the foreground (F-16a §5, When In Use only).
public final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate, @unchecked Sendable {
    private let manager: any LocationManaging
    private let lock = NSLock()
    private let clock: any NovaClock
    private let firstFixWait: NovaDuration
    private let freshness: NovaDuration
    private var latest: LocationFix?
    private var started = false
    private var paused = false

    /// `clock` must be the clock that judges the fix (the navigation flow's). `manager` defaults to a real
    /// `CLLocationManager`; tests pass a fake. Create on the main thread (CoreLocation's delegate thread).
    public init(clock: any NovaClock, manager: any LocationManaging = CLLocationManager(),
                firstFixWait: NovaDuration = TuningDefaults.firstFixWait,
                freshness: NovaDuration = AmapWebTuning().locationFresh) {
        self.clock = clock
        self.manager = manager
        self.firstFixWait = firstFixWait
        self.freshness = freshness
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
            return !started && !paused
        }
        guard start else { return }
        await MainActor.run {
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startUpdatingLocation()
        }
    }

    /// F-16a §5: app in the background → updates paused (no background location).
    public func pause() async {
        let wasRunning = lock.withLock { () -> Bool in
            defer { paused = true }
            return started && !paused
        }
        guard wasRunning else { return }
        await MainActor.run { manager.stopUpdatingLocation() }
    }

    /// F-16a §5: foreground → updates resume if they were started and permission allows.
    public func resume() async {
        let restart = lock.withLock { () -> Bool in
            defer { paused = false }
            return started && paused
        }
        guard restart, !denied else { return }
        await MainActor.run { manager.startUpdatingLocation() }
    }

    public func latestFix() async -> LocationFix? {
        await start()
        if let fix = freshFix() { return fix }
        guard !denied, !lock.withLock({ paused }) else { return lock.withLock { latest } }
        // F-16a §4: the first request after start (or right after permission), or one that only has an
        // old fix, waits for a fresh one. On timeout the old fix is returned and NovaNav judges it.
        let deadline = clock.now + firstFixWait
        while clock.now < deadline {
            try? await clock.sleep(until: min(clock.now + .milliseconds(100), deadline))
            if Task.isCancelled { break }
            if let fix = freshFix() { return fix }
            if denied { return nil }
        }
        return lock.withLock { latest }
    }

    private func freshFix() -> LocationFix? {
        let now = clock.now
        return lock.withLock { () -> LocationFix? in
            guard let latest, now - latest.timestamp <= freshness else { return nil }
            return latest
        }
    }

    // MARK: Delegate (also driven directly by tests with a fake manager)

    func receive(_ location: CLLocation) {
        // Age relative to now, expressed on the judging clock.
        let age = Int64(max(0, -location.timestamp.timeIntervalSinceNow) * 1000)
        let fix = LocationFix(coordinate: GeoCoordinate(latitude: location.coordinate.latitude,
                                                        longitude: location.coordinate.longitude, datum: .wgs84),
                              horizontalAccuracyMeters: location.horizontalAccuracy,
                              timestamp: clock.now - NovaDuration(milliseconds: age))
        lock.withLock { latest = fix }
    }

    /// F-16a §7: granted → updates (re)start unless paused; denied → the last fix is dropped.
    func authorizationChanged(_ status: CLAuthorizationStatus) {
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            if !lock.withLock({ paused }) { manager.startUpdatingLocation() }
        case .denied, .restricted:
            manager.stopUpdatingLocation()
            lock.withLock { latest = nil }
        default:
            break
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        receive(location)
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationChanged(manager.authorizationStatus)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {}
}
#endif
