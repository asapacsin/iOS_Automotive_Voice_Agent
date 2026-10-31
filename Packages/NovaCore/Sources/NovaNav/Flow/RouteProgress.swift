import Foundation
import NovaKit
import NovaPorts

/// F-15a §2.2 / §4 (T-040a): 真实导航 progress without the Navi SDK (OQ-NAVM-4). Each GPS fix is matched to the
/// Amap Web route polyline; step entry, distance to the next turn, remaining distance and time, off-route and
/// arrival come from the matched point. Pure: time comes from the fixes and `tick(at:)`.
public struct RouteProgress: Sendable {
    public struct Snapshot: Sendable, Hashable {
        /// The fix projected onto the route (GCJ-02).
        public let matched: GeoCoordinate
        public let distanceFromRouteMeters: Double
        /// Distance along the route of the matched point; it never goes back.
        public let alongMeters: Double
        public let stepIndex: Int
        /// The step this fix entered (its guidance is due), else nil.
        public let enteredStep: Int?
        public let distanceToNextStepMeters: Double
        public let remainingMeters: Double
        public let remainingSeconds: Int
        public let onRoute: Bool
        /// More than `offRouteMeters` for `offRouteFixes` counted fixes over `offRouteSpan`: recalculate.
        public let offRouteConfirmed: Bool
        /// Within `arrivalMeters` of the destination; reported once.
        public let arrived: Bool
    }

    public enum Signal: Sendable, Hashable {
        case ok
        /// No fix for `signalLostAfter`: the marker turns provisional and progress holds. `announce` is true once,
        /// at `signalWeakSentenceAfter` (「定位信号弱，导航暂停更新。」).
        case lost(announce: Bool)
    }

    public let tuning: RouteProgressTuning
    private let points: [GeoCoordinate]
    private let stepStarts: [Int]
    private let cumulative: [Double]
    private let durationSeconds: Int
    private var along = 0.0
    private var step = -1
    private var offRoute: [NovaInstant] = []
    private var lastFix: NovaInstant?
    private var announcedWeak = false
    private var arrived = false

    /// `points` is the route polyline (GCJ-02), `stepStarts` each step's index into it, `durationSeconds` the
    /// route's estimate; `start` is when guidance began (the signal clock runs from there until the first fix).
    public init(points: [GeoCoordinate], stepStarts: [Int], durationSeconds: Int, start: NovaInstant,
                tuning: RouteProgressTuning = RouteProgressTuning()) {
        self.points = points
        self.stepStarts = stepStarts.isEmpty ? [0] : stepStarts
        self.durationSeconds = durationSeconds
        self.tuning = tuning
        lastFix = start
        var total = 0.0
        var cumulative = [0.0]
        for index in points.indices.dropFirst() {
            total += SelfPosition.distanceMeters(points[index - 1], points[index])
            cumulative.append(total)
        }
        self.cumulative = cumulative
    }

    public var totalMeters: Double { cumulative.last ?? 0 }

    /// A fix in GCJ-02 (convert before calling, like the route).
    public mutating func update(_ fix: LocationFix) -> Snapshot? {
        guard let destination = points.last else { return nil }
        lastFix = fix.timestamp
        announcedWeak = false
        let (matched, distance, matchedAlong) = match(fix.coordinate)
        let counted = fix.horizontalAccuracyMeters <= tuning.countedAccuracyMeters
        let onRoute = distance <= tuning.offRouteMeters
        var confirmed = false
        if onRoute {
            if counted { offRoute = [] }
            along = max(along, matchedAlong)
        } else if counted {
            offRoute.append(fix.timestamp)
            if let first = offRoute.first, offRoute.count >= tuning.offRouteFixes,
               fix.timestamp - first >= tuning.offRouteSpan {
                confirmed = true
                offRoute = []
            }
        }
        let current = stepStarts.lastIndex { cumulative[min($0, cumulative.count - 1)] <= along } ?? 0
        let entered = current > step ? current : nil
        step = max(step, current)
        let remaining = max(totalMeters - along, 0)
        var arrivedNow = false
        if !arrived, SelfPosition.distanceMeters(fix.coordinate, destination) <= tuning.arrivalMeters
            || (onRoute && remaining <= tuning.arrivalMeters) {
            arrived = true
            arrivedNow = true
        }
        let nextStart = step + 1 < stepStarts.count ? cumulative[min(stepStarts[step + 1], cumulative.count - 1)] : totalMeters
        let seconds = totalMeters > 0 ? Int((Double(durationSeconds) * remaining / totalMeters).rounded()) : 0
        return Snapshot(matched: matched, distanceFromRouteMeters: distance, alongMeters: along, stepIndex: step,
                        enteredStep: entered, distanceToNextStepMeters: max(nextStart - along, 0),
                        remainingMeters: remaining, remainingSeconds: seconds, onRoute: onRoute,
                        offRouteConfirmed: confirmed, arrived: arrivedNow)
    }

    /// The signal clock, called on a timer while navigating.
    public mutating func tick(at now: NovaInstant) -> Signal {
        guard let lastFix, now - lastFix >= tuning.signalLostAfter else { return .ok }
        if !announcedWeak, now - lastFix >= tuning.signalWeakSentenceAfter {
            announcedWeak = true
            return .lost(announce: true)
        }
        return .lost(announce: false)
    }

    /// Nearest point on the polyline: (point, distance, distance along the route).
    private func match(_ p: GeoCoordinate) -> (GeoCoordinate, Double, Double) {
        guard points.count > 1 else { return (points[0], SelfPosition.distanceMeters(p, points[0]), 0) }
        var best = (points[0], Double.infinity, 0.0)
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            // Local plane around `a`; the segments are short enough for it.
            let metersPerDegree = 111_320.0
            let cosLat = cos(a.latitude * .pi / 180)
            let bx = (b.longitude - a.longitude) * metersPerDegree * cosLat, by = (b.latitude - a.latitude) * metersPerDegree
            let px = (p.longitude - a.longitude) * metersPerDegree * cosLat, py = (p.latitude - a.latitude) * metersPerDegree
            let length2 = bx * bx + by * by
            let t = length2 > 0 ? min(max((px * bx + py * by) / length2, 0), 1) : 0
            let dx = px - t * bx, dy = py - t * by
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < best.1 {
                let point = GeoCoordinate(latitude: a.latitude + t * (b.latitude - a.latitude),
                                          longitude: a.longitude + t * (b.longitude - a.longitude), datum: a.datum)
                best = (point, distance, cumulative[index] + t * (cumulative[index + 1] - cumulative[index]))
            }
        }
        return best
    }
}
