import NovaKit
import NovaPorts

/// The map camera (features/map-logic.md §4, F-16b): in-car conventions. It follows 我的位置, a driver's pan
/// stops that, and 15 s without a touch (or 回到我的位置) brings it back. Rules C1–C11. It never reads a
/// clock; every event carries its time.
public struct MapCameraPolicy: Sendable {
    public enum Mode: Sendable, Hashable { case awaitingFirstFix, following, free(lastTouch: NovaInstant) }
    /// What else the map shows: nothing (open), a place list or route choice (lists), a running route.
    public enum Framing: Sendable, Hashable { case open, lists, navigating }

    public enum Command: Sendable, Hashable {
        case center(GeoCoordinate, spanMeters: Double)
        /// Frame the routes or listed places (T-044 framing).
        case fitContent
        /// F-09b §19 item 4 (T-031zd): frame these points together (the car and the pin), the `fitContent` margin.
        case frame([GeoCoordinate])
    }

    /// §19 item 4: the pin alone is shown at this span; over `pinFarMeters` from the car the pin is shown alone.
    public static let pinSpanMeters = 5_000.0
    public static let pinFarMeters = 300_000.0

    public enum Event: Sendable, Hashable {
        case position(SelfPosition, at: NovaInstant)
        case framing(Framing, at: NovaInstant)
        /// Only gestures the driver made, never a move this policy commanded.
        case userGesture(at: NovaInstant)
        case locateMe(at: NovaInstant)
        /// Every `reevaluateEvery`, and at the last touch + `autoRecenterAfter`.
        case tick(at: NovaInstant)
        case sourceChanged
        /// F-09b §19 item 4: `show_on_map` drew a pin (nil: the pin went away).
        case mapPin(GeoCoordinate?, at: NovaInstant)
    }

    public let tuning: MapPositionTuning
    public private(set) var mode = Mode.awaitingFirstFix
    public private(set) var framing = Framing.open
    private var marker: GeoCoordinate?
    /// §19 item 4: while a pin is shown the 15 s auto-recenter does not run.
    public private(set) var pin: GeoCoordinate?
    private var lastCenter: (point: GeoCoordinate, at: NovaInstant)?

    public init(tuning: MapPositionTuning = MapPositionTuning()) {
        self.tuning = tuning
    }

    public static func framing(_ presentation: MapPresentation) -> Framing {
        if presentation.list != nil { return .lists }
        return presentation.followCar ? .navigating : .open
    }

    public mutating func handle(_ event: Event) -> Command? {
        switch event {
        case .position(let position, let now):
            marker = position.marker?.coordinate
            guard let point = marker else { return nil }  // C3: nothing to show, nothing to follow
            guard framing != .lists else { return nil }  // C1: lists keep their framing
            switch mode {
            case .awaitingFirstFix:
                mode = .following  // C4
                return center(point, at: now)
            case .following:
                // C5: no jitter on GPS noise.
                if let last = lastCenter,
                   SelfPosition.distanceMeters(last.point, point) < tuning.followMinMoveMeters
                    || now - last.at < tuning.followMinInterval {
                    return nil
                }
                return center(point, at: now)
            case .free:
                return nil  // C6
            }
        case .framing(let next, let now):
            let previous = framing
            framing = next
            guard next != previous else { return nil }
            if next == .lists { return .fitContent }  // C1
            // C2: closing a list resumes following only if it was following.
            guard previous == .lists, mode == .following, let point = marker else { return nil }
            return center(point, at: now)
        case .userGesture(let now):
            mode = .free(lastTouch: now)  // C7
            return nil
        case .tick(let now):
            // C8: the in-car return after no touch.
            guard pin == nil, case .free(let lastTouch) = mode, now - lastTouch >= tuning.autoRecenterAfter,
                  framing != .lists, let point = marker else { return nil }
            mode = .following
            return center(point, at: now)
        case .locateMe(let now):
            guard let point = marker else { return nil }  // C10: the view runs the LocateAction
            mode = .following  // C9: at once, no throttle
            return center(point, at: now)
        case .mapPin(let point, let now):
            pin = point
            // Navigating: the pin is drawn, the route view stays.
            guard let point, framing != .navigating else { return nil }
            // Following stops while the pin is shown, as a driver pan (C7).
            mode = .free(lastTouch: now)
            if let car = marker, SelfPosition.distanceMeters(car, point) <= Self.pinFarMeters { return .frame([car, point]) }
            return .center(point, spanMeters: Self.pinSpanMeters)
        case .sourceChanged:
            mode = .awaitingFirstFix  // C11
            marker = nil
            lastCenter = nil
            return nil
        }
    }

    private mutating func center(_ point: GeoCoordinate, at now: NovaInstant) -> Command {
        lastCenter = (point, now)
        return .center(point, spanMeters: tuning.followSpanMeters)
    }
}
