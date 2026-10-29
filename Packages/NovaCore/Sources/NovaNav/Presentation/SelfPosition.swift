import Foundation
import NovaKit
import NovaPorts

/// The 我的位置 marker (features/map-logic.md §3, F-16b): which marker the map draws, where and in which style.
/// Rules R1–R8, first match wins. Never a marker at a guessed place.
public struct SelfPosition: Sendable, Hashable {
    public enum Style: Sendable, Hashable { case fresh, provisional, demo, simulated }
    /// Why nothing is drawn.
    public enum Hidden: Sendable, Hashable { case notDetermined, denied, noFix, unusable }

    public struct Marker: Sendable, Hashable {
        /// Always GCJ-02, the datum of the routes and place markers.
        public let coordinate: GeoCoordinate
        public let style: Style
        /// nil draws a dot; set draws an arrow (0 = north, clockwise).
        public let headingDegrees: Double?
        public let accuracyRadiusMeters: Double?
        /// 「演示位置」 for the demo source.
        public let caption: String?
    }

    public struct Input: Sendable, Hashable {
        public var fix: LocationFix?
        public var source: LocationSource
        public var permission: LocationAuthorization
        public var now: NovaInstant
        public var phase: NavigationPhase
        /// `RouteGeometry.car` while a simulated route runs (GCJ-02).
        public var simulatedCar: GeoCoordinate?
        public var simulatedHeadingDegrees: Double?

        public init(fix: LocationFix?, source: LocationSource, permission: LocationAuthorization, now: NovaInstant,
                    phase: NavigationPhase = .idle, simulatedCar: GeoCoordinate? = nil,
                    simulatedHeadingDegrees: Double? = nil) {
            self.fix = fix
            self.source = source
            self.permission = permission
            self.now = now
            self.phase = phase
            self.simulatedCar = simulatedCar
            self.simulatedHeadingDegrees = simulatedHeadingDegrees
        }
    }

    public static let demoCaption = "演示位置"

    /// Set exactly when `hidden` is nil.
    public let marker: Marker?
    public let hidden: Hidden?

    private init(_ marker: Marker) {
        self.marker = marker
        hidden = nil
    }

    private init(hidden: Hidden) {
        marker = nil
        self.hidden = hidden
    }

    public static func make(_ input: Input, tuning: MapPositionTuning = MapPositionTuning(),
                            fixRules: AmapWebTuning = AmapWebTuning()) -> SelfPosition {
        let caption = input.source == .demo ? demoCaption : nil
        // R1 (OQ-MAP-2): during simulated navigation the simulated car is 我的位置; one marker only.
        if input.phase == .navigating, let car = input.simulatedCar {
            return SelfPosition(Marker(coordinate: CoordinateConverter.gcj02(car), style: .simulated,
                                       headingDegrees: input.simulatedHeadingDegrees, accuracyRadiusMeters: nil,
                                       caption: caption))
        }
        // R2: the demo point, labelled so a viewer is never misled (REC-003).
        if input.source == .demo {
            guard let fix = input.fix else { return SelfPosition(hidden: .noFix) }
            return SelfPosition(Marker(coordinate: CoordinateConverter.gcj02(fix.coordinate), style: .demo,
                                       headingDegrees: nil, accuracyRadiusMeters: nil, caption: caption))
        }
        switch input.permission {
        case .notDetermined: return SelfPosition(hidden: .notDetermined)  // R3
        case .denied: return SelfPosition(hidden: .denied)  // R4
        case .authorized: break
        }
        guard let fix = input.fix else { return SelfPosition(hidden: .noFix) }  // R5
        // R6: too old or too coarse (F-16 §3).
        guard let quality = LocationQuality.of(fix, at: input.now, tuning: fixRules) else {
            return SelfPosition(hidden: .unusable)
        }
        // R7 / R8. A provisional fix is not moving now, so it never shows an arrow.
        var heading: Double?
        if quality == .fresh, let speed = fix.speedMetersPerSecond, speed >= tuning.headingMinSpeedMetersPerSecond,
           let course = fix.courseDegrees, course >= 0, course < 360 {
            heading = course
        }
        let accuracy = fix.horizontalAccuracyMeters
        return SelfPosition(Marker(coordinate: CoordinateConverter.gcj02(fix.coordinate),
                                   style: quality == .fresh ? .fresh : .provisional, headingDegrees: heading,
                                   accuracyRadiusMeters: accuracy > tuning.accuracyCircleMinMeters ? accuracy : nil,
                                   caption: nil))
    }

    /// Initial great-circle bearing in [0, 360), for the simulated car's arrow; nil under
    /// `simulatedHeadingMinStepMeters`, so the caller keeps the last bearing while the car stands.
    public static func bearing(from a: GeoCoordinate, to b: GeoCoordinate,
                               tuning: MapPositionTuning = MapPositionTuning()) -> Double? {
        guard distanceMeters(a, b) >= tuning.simulatedHeadingMinStepMeters else { return nil }
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let y = sin(dLng) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLng)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Haversine distance; the datum offset is far below the 10 m and 1 m thresholds it is used for.
    public static func distanceMeters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }
}

/// What tapping 回到我的位置 does (features/map-logic.md §3).
public enum LocateAction: Sendable, Hashable { case none, recenter, askPermission, openSettings }

public enum LocateIcon: String, Sendable, Hashable {
    case following = "location.fill"
    case free = "location"
    case unavailable = "location.slash"
}

public struct LocateButton: Sendable, Hashable {
    public let icon: LocateIcon
    public let action: LocateAction
    /// 定位未开启 pill (F-16b §2).
    public let showsPermissionPill: Bool

    public init(_ position: SelfPosition, mode: MapCameraPolicy.Mode) {
        guard position.marker != nil else {
            icon = .unavailable
            switch position.hidden {
            case .notDetermined: action = .askPermission
            case .denied: action = .openSettings
            case .noFix, .unusable, nil: action = .none
            }
            showsPermissionPill = position.hidden == .denied
            return
        }
        showsPermissionPill = false
        if mode == .following {
            icon = .following
            action = .none
        } else {
            icon = .free
            action = .recenter
        }
    }
}
