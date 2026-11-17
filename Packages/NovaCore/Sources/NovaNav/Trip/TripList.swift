import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// One stop of the trip list (F-15b §3 item 1): the name asked and the place 高德 resolved it to.
public struct TripStop: Sendable, Hashable {
    /// 1-based, renumbered 1…n after every change.
    public let index: Int
    public let asked: String
    public let place: Place
    /// Great-circle distance from the origin when it was resolved; nil when the origin was unknown.
    public let distanceMeters: Int?

    public init(index: Int, asked: String, place: Place, distanceMeters: Int?) {
        self.index = index
        self.asked = asked
        self.place = place
        self.distanceMeters = distanceMeters
    }

    func renumbered(_ index: Int) -> TripStop {
        TripStop(index: index, asked: asked, place: place, distanceMeters: distanceMeters)
    }
}

/// F-15b §3 (T-040i): the ordered list of 1–16 stops the app owns. Pure. Every change raises `generation`; a resolve
/// that finishes after a newer change is dropped by its caller (`OPTIONS_STALE`).
public struct TripList: Sendable, Hashable {
    public static let maxStops = RouteRequest.maxWaypoints

    public private(set) var stops: [TripStop] = []
    public private(set) var generation = 0

    public init() {}

    public var count: Int { stops.count }
    public var isEmpty: Bool { stops.isEmpty }

    /// `make_trip_list`: the whole list replaced.
    public mutating func replace(_ entries: [(asked: String, place: Place, distanceMeters: Int?)]) {
        stops = entries.prefix(Self.maxStops).map { TripStop(index: 0, asked: $0.asked, place: $0.place,
                                                             distanceMeters: $0.distanceMeters) }
        changed()
    }

    public mutating func clear() {
        stops = []
        changed()
    }

    /// `at` is 1-based. Precondition: 1…count.
    public mutating func remove(at index: Int) {
        stops.remove(at: index - 1)
        changed()
    }

    /// Inserts at the 1-based `position` (1…count+1), or appends when nil.
    public mutating func insert(_ stop: TripStop, at position: Int? = nil) {
        stops.insert(stop, at: (position ?? stops.count + 1) - 1)
        changed()
    }

    public mutating func set(_ stop: TripStop, at index: Int) {
        stops[index - 1] = stop
        changed()
    }

    /// Moves the stop at `from` so it ends up at `to` (both 1-based, 1…count).
    public mutating func move(from: Int, to: Int) {
        let stop = stops.remove(at: from - 1)
        stops.insert(stop, at: to - 1)
        changed()
    }

    /// `route_trip order=nearest`: the list takes the route's order (`order` holds 0-based indexes). An unchanged
    /// order is no change.
    public mutating func reorder(_ order: [Int]) {
        guard order != Array(stops.indices), Set(order) == Set(stops.indices) else { return }
        stops = order.map { stops[$0] }
        changed()
    }

    public func contains(placeID: String) -> Bool { stops.contains { $0.place.id == placeID } }

    /// F-15b §12: a photo link arrived. Not a list change: no renumbering, no new generation, so it never makes a
    /// resolve stale.
    public mutating func setPhoto(placeID: String, url: URL?) {
        stops = stops.map { $0.place.id == placeID
            ? TripStop(index: $0.index, asked: $0.asked, place: $0.place.with(photoURL: url), distanceMeters: $0.distanceMeters)
            : $0 }
    }

    /// §5.2: stops whose resolved or asked name contains `name`, after normalize (1-based indexes).
    public func matches(_ name: String) -> [Int] {
        let wanted = TranscriptText.normalize(name)
        guard !wanted.isEmpty else { return [] }
        return stops.filter {
            TranscriptText.normalize($0.place.name).contains(wanted) || TranscriptText.normalize($0.asked).contains(wanted)
        }.map(\.index)
    }

    private mutating func changed() {
        stops = stops.enumerated().map { $0.element.renumbered($0.offset + 1) }
        generation += 1
    }
}

/// F-15b §4 item 2: a search result is accepted when one normalized name contains the other. §4 item 6 (device
/// 2026-11-17: 「路环安德鲁葡挞」 is 高德's 「安德鲁饼店」): the first of the top 5 results that matches so; otherwise the
/// first result when it shares a run of at least 3 characters with the asked name.
public enum TripNameMatch {
    public static let scanned = 5
    public static let sharedRun = 3

    public static func accepts(asked: String, found: String) -> Bool {
        let a = TranscriptText.normalize(asked), f = TranscriptText.normalize(found)
        guard !a.isEmpty, !f.isEmpty else { return false }
        return f.contains(a) || a.contains(f)
    }

    /// Place-type words that say nothing about which place it is; removed before the shared run is measured.
    static let typeWords = ["购物中心", "国际机场", "博物馆", "博物院", "机场", "国际", "医院", "大学", "大饭店", "饭店", "酒店", "公园", "广场", "景区", "大街", "中心", "饼店", "车站", "站", "店"]

    public static func pick(asked: String, from places: [Place], city: String? = nil) -> Place? {
        if let match = places.prefix(scanned).first(where: { accepts(asked: asked, found: $0.name) }) { return match }
        guard let first = places.first else { return nil }
        let regions = [city, first.city, first.district].compactMap { $0 }
        let (a, f) = cores(TranscriptText.normalize(asked), TranscriptText.normalize(first.name), regions: regions)
        return longestRun(a, f) >= sharedRun ? first : nil
    }

    /// Review 2026-11-17: the city argument and the result's own city and district (「哈尔滨中央大街」/「哈尔滨站」,
    /// with and without 市/区/县/省) and place-type words (「天津博物馆」/「天津自然博物馆」) are removed, so only the
    /// distinctive part is compared. A shared start that is not a region still counts (「安德鲁葡挞」/「安德鲁饼店」).
    static func cores(_ asked: String, _ found: String, regions: [String]) -> (String, String) {
        var a = asked, f = found
        var names = Set<String>()
        for region in regions.map(TranscriptText.normalize) where !region.isEmpty {
            names.insert(region)
            for suffix in ["特别行政区", "自治区"] where region.hasSuffix(suffix) && region.count > suffix.count + 1 {
                names.insert(String(region.dropLast(suffix.count)))
            }
            if let last = region.last, "市区县省".contains(last), region.count > 2 { names.insert(String(region.dropLast())) }
        }
        for name in names.sorted(by: { $0.count > $1.count }) {
            a = a.replacingOccurrences(of: name, with: ""); f = f.replacingOccurrences(of: name, with: "")
        }
        for word in typeWords {
            a = a.replacingOccurrences(of: word, with: ""); f = f.replacingOccurrences(of: word, with: "")
        }
        return (a, f)
    }

    /// Length of the longest run of characters the two strings share.
    static func longestRun(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1), best = 0
        for i in 1...x.count {
            var row = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                row[j] = previous[j - 1] + 1
                best = max(best, row[j])
            }
            previous = row
        }
        return best
    }
}

/// F-15b §5.3 item 2: from the origin, repeatedly the closest unvisited stop (great-circle distance).
public enum TripOrder {
    /// 0-based indexes of `stops` in visiting order. Without an origin, the first stop starts the chain.
    public static func nearest(from origin: GeoCoordinate?, _ stops: [GeoCoordinate]) -> [Int] {
        guard !stops.isEmpty else { return [] }
        var left = Array(stops.indices)
        var order: [Int] = []
        var here: GeoCoordinate
        if let origin {
            here = origin
        } else {
            order.append(left.removeFirst())
            here = stops[order[0]]
        }
        while !left.isEmpty {
            let best = left.indices.min { a, b in
                SelfPosition.distanceMeters(here, stops[left[a]]) < SelfPosition.distanceMeters(here, stops[left[b]])
            }!
            let next = left.remove(at: best)
            order.append(next)
            here = stops[next]
        }
        return order
    }
}

/// F-15b §6 item 3 (T-040i): which waypoints the car has passed. A waypoint is passed when the car's matched
/// position along the route goes past the polyline point closest to it, or the car comes within 100 m of it.
/// Passed stops never become unpassed. Pure.
public struct TripStopTracker: Sendable {
    public static let nearMeters = 100.0

    public struct Waypoint: Sendable, Hashable {
        /// 1-based, the stop's index in route order (kept across a reroute that drops passed ones).
        public let index: Int
        public let coordinate: GeoCoordinate
        public init(index: Int, coordinate: GeoCoordinate) {
            self.index = index
            self.coordinate = coordinate
        }
    }

    private let waypoints: [(Waypoint, Double)]
    public private(set) var passed: Set<Int> = []

    /// `points`: the route polyline; `waypoints`: the not yet passed stops on it.
    public init(points: [GeoCoordinate], waypoints: [Waypoint], passed: Set<Int> = []) {
        var cumulative = [0.0]
        for i in points.indices.dropFirst() {
            cumulative.append(cumulative[i - 1] + SelfPosition.distanceMeters(points[i - 1], points[i]))
        }
        // Stops are in route order: each one's closest point is searched from the previous stop's point on, so a stop
        // that lies near an earlier leg (out and back, a route that crosses itself) is not passed early.
        var from = 0
        var located: [(Waypoint, Double)] = []
        for wp in waypoints {
            guard from < points.count else {
                located.append((wp, .infinity))
                continue
            }
            let closest = (from..<points.count).min {
                SelfPosition.distanceMeters(points[$0], wp.coordinate) < SelfPosition.distanceMeters(points[$1], wp.coordinate)
            }!
            located.append((wp, cumulative[closest]))
            from = closest
        }
        self.waypoints = located
        self.passed = passed
    }

    /// The car at `along` metres on the route, at `position`: the stops passed by this update, in order.
    public mutating func update(along: Double, position: GeoCoordinate) -> [Int] {
        var fresh: [Int] = []
        for (wp, at) in waypoints where !passed.contains(wp.index) {
            if along > at || SelfPosition.distanceMeters(position, wp.coordinate) <= Self.nearMeters {
                passed.insert(wp.index)
                fresh.append(wp.index)
            }
        }
        return fresh.sorted()
    }
}
