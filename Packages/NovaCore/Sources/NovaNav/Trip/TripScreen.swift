import Foundation
import NovaKit
import NovaPorts

/// F-15b §11 item 4 (T-040j): whether the phone is moving, for the card row. Moving at ≥ 8 km/h, or while 真实导航
/// runs; it stops being moving after 3 s below 3 km/h. 模拟导航 alone is not moving. Unknown speed counts as moving
/// while 真实导航 runs and as not moving otherwise. Pure: time comes from the caller.
public struct TripMoving: Sendable, Hashable {
    public static let movingKmh = 8.0
    public static let stillKmh = 3.0
    public static let stillFor = NovaDuration.seconds(3)

    public private(set) var moving = false
    private var slowSince: NovaInstant?

    public init() {}

    /// One sample; returns the new value when it changed (for `trip strip moving=<yes|no>`), else nil.
    public mutating func update(speedKmh: Double?, gpsNavigating: Bool, at now: NovaInstant) -> Bool? {
        let before = moving
        if gpsNavigating {
            moving = true
            slowSince = nil
        } else if let speed = speedKmh {
            if speed >= Self.movingKmh {
                moving = true
                slowSince = nil
            } else if speed < Self.stillKmh {
                let since = slowSince ?? now
                slowSince = since
                if moving, now - since >= Self.stillFor { moving = false }
            } else {
                slowSince = nil
            }
        } else {
            moving = false
            slowSince = nil
        }
        return moving == before ? nil : moving
    }

    public static func line(_ moving: Bool) -> String { "trip strip moving=\(moving ? "yes" : "no")" }
}

/// One card of the row (§11 item 2).
public struct TripCard: Sendable, Hashable, Identifiable {
    public var id: String { placeID }
    public let index: Int
    public let placeID: String
    public let name: String
    public let district: String?
    /// One decimal; nil when the origin was unknown.
    public let km: Double?
    public let photoURL: URL?
    /// The first character of the name, for the placeholder.
    public let initial: String
    /// §11 item 2: greyed and marked 已到.
    public let passed: Bool
}

/// §11: what the 导航 tab shows of the trip list.
public enum TripScreen: Sendable, Hashable {
    /// Empty list: no row.
    case none
    /// Not moving: cards with photos, ✕, dragging and buttons.
    case cards([TripCard])
    /// Moving: one text line of numbers and names, no photos, no buttons, taps do nothing.
    case strip(String)

    /// §11 item 4: the strip is at most 2 lines.
    public static let stripLimit = 48

    /// The route's passed stops, only when `routeStops` (the trip route's place ids) are this list's stops.
    public static func passed(_ list: TripList, routeStops: [String], passed: Set<Int>) -> Set<Int> {
        routeStops == list.stops.map(\.place.id) ? passed : []
    }

    public static func of(_ list: TripList, passed: Set<Int>, moving: Bool) -> TripScreen {
        guard !list.isEmpty else { return .none }
        if moving {
            let full = list.stops.map { "\($0.index) \($0.place.name)" }.joined(separator: " · ")
            return .strip(full.count <= stripLimit ? full : String(full.prefix(stripLimit - 1)) + "…")
        }
        return .cards(list.stops.map { stop in
            TripCard(index: stop.index, placeID: stop.place.id, name: stop.place.name, district: stop.place.district,
                     km: stop.distanceMeters.map { (Double($0) / 100).rounded() / 10 }, photoURL: stop.place.photoURL,
                     initial: String(stop.place.name.prefix(1)), passed: passed.contains(stop.index))
        })
    }
}

/// §13 item 5: a numbered pin on the map.
public struct TripPin: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let coordinate: GeoCoordinate
    /// The number before routing; 途经k and 终点 on a kept or running trip route.
    public let label: String
    public let passed: Bool

    /// Pins 1…n at the stops; on a trip route the stops are 途经1…途经n−1 and 终点; passed stops greyed.
    public static func pins(_ list: TripList, routed: Bool, passed: Set<Int>) -> [TripPin] {
        list.stops.map { stop in
            let label = !routed ? "\(stop.index)" : stop.index == list.count ? "终点" : "途经\(stop.index)"
            return TripPin(index: stop.index, coordinate: stop.place.coordinate, label: label,
                           passed: routed && passed.contains(stop.index))
        }
    }
}

/// §12 item 3: secure links only; an `http://` link is tried as `https://`.
public enum TripPhotoLink {
    public static func secure(_ raw: String?) -> URL? {
        guard var text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("http://") { text = "https://" + text.dropFirst("http://".count) }
        guard text.lowercased().hasPrefix("https://"), let url = URL(string: text), url.host != nil else { return nil }
        return url
    }
}

/// §12 item 4: the disk cache keeps at most 20 MB, oldest removed first. Pure.
public enum TripPhotoCachePolicy {
    public static let diskLimitBytes = 20 * 1024 * 1024
    public static let memoryCount = 32

    public struct Entry: Sendable, Hashable {
        public let name: String
        public let bytes: Int
        public let added: Date
        public init(name: String, bytes: Int, added: Date) {
            self.name = name
            self.bytes = bytes
            self.added = added
        }
    }

    /// The names to delete so the rest fit in `limit`.
    public static func evict(_ entries: [Entry], limit: Int = diskLimitBytes) -> [String] {
        var total = entries.reduce(0) { $0 + $1.bytes }
        var out: [String] = []
        for entry in entries.sorted(by: { $0.added < $1.added }) where total > limit {
            total -= entry.bytes
            out.append(entry.name)
        }
        return out
    }
}
