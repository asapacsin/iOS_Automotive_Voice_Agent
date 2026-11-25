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
    /// §29 item 4: greyed and marked 已到 (visited) or 跳过 (skipped).
    public let passed: Bool
    public var mark: TripMark? = nil
    /// §29 item 4: driving minutes from the stop before, when known.
    public var minutes: Int? = nil
    /// §21 item 3: the stop's city (高德 `cityname`), for the introduction query.
    public var city: String? = nil
    /// §37 item 8 (T-040o): 住 on a hotel, 机场 on an airport start or end, 租 on a rental stop (§45); nil otherwise.
    public var tag: String? = nil
    /// §46 item 6 (T-040r): the placeholder's icon and colours; `.other` when the kind is unknown.
    public var kind: PlaceKind = .other
    /// §52 item 9 (T-040zc): false for a stop not on the map yet; the card shows `unplacedText` instead of the place.
    public var placed = true
    public static let unplacedText = "位置待确认"
    /// F-15b §64 item 6 (T-040zq): 「<title> · <start>～<end>」 under the venue of an event stop; nil otherwise.
    public var event: String? = nil
    /// F-15b §67 item 4 (T-040zt): the map's place name under the title when it differs from the title; nil otherwise.
    public var place: String? = nil

    static func tag(_ stop: TripStop) -> String? {
        switch stop.role {
        case .hotel: return "住"
        case .start, .end:
            let name = stop.place.name
            return name.contains("机场") || name.contains("空港") || name.localizedCaseInsensitiveContains("airport") ? "机场" : nil
        // §45 item 9 (T-040q): 租 on a rental pickup or return.
        case .rentalPickup, .rentalReturn: return "租"
        case .sight: return nil
        }
    }
}

/// §11: what the 导航 tab shows of the trip list.
public enum TripScreen: Sendable, Hashable {
    /// Empty list: no row.
    case none
    /// Not moving: cards with photos, ✕, dragging and buttons.
    case cards([TripCard])
    /// Moving: one text line of numbers and names, no photos, no buttons, taps do nothing.
    case strip(String)
    /// §52 item 9 (T-040zc): the plan has stops but the day in front has none (not moving): the day tabs and
    /// `emptyDayText`.
    case emptyDay

    public static let emptyDayText = "这一天还没有安排"

    /// F-15b §57 item 2 (T-040zj): the one navigation button under the cards. 「去下一站：<名字>」 (with its icon) to the
    /// next open stop; while navigation runs the same spot shows 「结束导航」. nil: no button.
    public enum NavButton: Sendable, Hashable {
        case next(String)
        case stop
    }

    public static func navButton(nextStop: String?, navigating: Bool) -> NavButton? {
        if navigating { return .stop }
        return nextStop.map { .next($0) }
    }

    /// §52 item 9: the screen from the whole plan. Nothing only when the plan has no stop; the day in front decides
    /// the cards, and an empty day is still the trip screen.
    public static func of(plan: TripPlan, moving: Bool) -> TripScreen {
        guard !plan.isEmpty else { return .none }
        let day = plan.days[plan.currentDay - 1]
        if day.isEmpty { return moving ? .strip(emptyDayText) : .emptyDay }
        return of(day, moving: moving)
    }

    /// §11 item 4: the strip is at most 2 lines.
    public static let stripLimit = 48

    public static func of(_ list: TripList, moving: Bool) -> TripScreen {
        guard !list.isEmpty else { return .none }
        if moving {
            let full = list.stops.map { "\($0.index) \($0.title)" }.joined(separator: " · ")
            return .strip(full.count <= stripLimit ? full : String(full.prefix(stripLimit - 1)) + "…")
        }
        return .cards(list.stops.map { stop in
            // F-15b §67 item 4 (T-040zt): the title is the stop's name; the map's name goes on the line under it.
            TripCard(index: stop.index, placeID: stop.place.id, name: stop.title,
                     district: stop.placed ? stop.place.district : TripCard.unplacedText,
                     km: stop.placed ? stop.distanceMeters.map { (Double($0) / 100).rounded() / 10 } : nil, photoURL: stop.place.photoURL,
                     initial: String(stop.title.prefix(1)), passed: stop.mark != nil, mark: stop.mark,
                     minutes: stop.legSeconds.map { max(1, ($0 + 59) / 60) }, city: stop.place.city,
                     tag: TripCard.tag(stop), kind: stop.place.kind ?? .other, placed: stop.placed,
                     event: stop.event?.cardText,
                     place: stop.placed && stop.title != stop.place.name ? stop.place.name : nil)
        })
    }
}

/// §13 item 5: a numbered pin on the map.
public struct TripPin: Sendable, Hashable, Identifiable {
    public var id: Int { index }
    public let index: Int
    public let coordinate: GeoCoordinate
    /// The stop's number (§29 item 4: no 途经 labels).
    public let label: String
    public let passed: Bool

    /// Pins 1…n at the stops; visited and skipped stops greyed.
    public static func pins(_ list: TripList) -> [TripPin] {
        // §52 item 9 (T-040zc): a stop not on the map yet has no pin.
        list.stops.filter(\.placed).map { stop in
            TripPin(index: stop.index, coordinate: stop.place.coordinate, label: "\(stop.index)", passed: stop.mark != nil)
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
