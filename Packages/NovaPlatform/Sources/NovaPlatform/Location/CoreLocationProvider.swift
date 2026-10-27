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
    private let clock: any NovaClock
    /// Fix-wait / freshness / authorization / pause logic lives in NovaPorts (Linux-tested); this is the adapter.
    let state: LocationFixState

    /// `clock` must be the clock that judges the fix (the navigation flow's). `manager` defaults to a real
    /// `CLLocationManager`; tests pass a fake. Create on the main thread (CoreLocation's delegate thread).
    public init(clock: any NovaClock, manager: any LocationManaging = CLLocationManager(),
                firstFixWait: NovaDuration = TuningDefaults.firstFixWait,
                freshness: NovaDuration = AmapWebTuning().locationFresh) {
        self.clock = clock
        self.manager = manager
        state = LocationFixState(clock: clock, permission: Self.map(manager.authorizationStatus),
                                 firstFixWait: firstFixWait, freshness: freshness)
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    static func map(_ status: CLAuthorizationStatus) -> LocationAuthorization {
        switch status {
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        default: .authorized
        }
    }

    /// Denied or restricted: features fall back to text search and say why (F-16 §3, F-16a §8).
    public var denied: Bool { Self.map(manager.authorizationStatus) == .denied }

    public func authorization() async -> LocationAuthorization { Self.map(manager.authorizationStatus) }

    /// Asks for When In Use now and starts updates; no-op once started.
    public func start() async { await perform(state.start()) }

    /// F-16a §5: app in the background → updates paused (no background location).
    public func pause() async { await perform(state.pause()) }

    /// F-16a §5: foreground → updates resume if they were started and permission allows.
    public func resume() async { await perform(state.resume()) }

    public func latestFix() async -> LocationFix? {
        await start()
        return await state.awaitFix()
    }

    private func perform(_ action: LocationFixState.ManagerAction?) async {
        guard let action else { return }
        await MainActor.run { apply(action) }
    }

    func apply(_ action: LocationFixState.ManagerAction) {
        // Hops to the main actor can land out of order (a start after a later pause, a stop after a later
        // resume); the state machine's current view decides.
        if (action == .stopUpdates) == state.mayStartUpdates() { return }
        switch action {
        case .requestAndStart:
            if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
            manager.startUpdatingLocation()
        case .startUpdates: manager.startUpdatingLocation()
        case .stopUpdates: manager.stopUpdatingLocation()
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
        state.receive(fix)
    }

    /// F-16a §7: granted → updates (re)start unless paused; denied → the last fix is dropped.
    func authorizationChanged(_ status: CLAuthorizationStatus) {
        if let action = state.authorizationChanged(Self.map(status)) { apply(action) }
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
