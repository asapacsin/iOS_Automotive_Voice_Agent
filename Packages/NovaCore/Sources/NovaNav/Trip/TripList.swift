import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §29 item 2 (T-040n): a stop marked done.
public enum TripMark: String, Sendable, Hashable, Codable {
    case visited, skipped
}

/// F-15b §37 item 2 (T-040o): what a stop is in the trip's frame. nil on older stops counts as `sight`.
/// §45 item 12 (T-040q): `rental_pickup` (day 1, right after the start) and `rental_return` (last day, just before the end).
public enum TripRole: String, Sendable, Hashable, Codable {
    case start, sight, hotel, end
    case rentalPickup = "rental_pickup"
    case rentalReturn = "rental_return"
}

/// One stop of the trip list (F-15b §3 item 1): the name asked and the place 高德 resolved it to.
public struct TripStop: Sendable, Hashable {
    /// 1-based, renumbered 1…n after every change.
    public let index: Int
    public let asked: String
    public let place: Place
    /// Great-circle distance from the origin when it was resolved; nil when the origin was unknown.
    public let distanceMeters: Int?
    /// §29 item 2: visited or skipped; kept in `current.json`.
    public var mark: TripMark?
    /// §29 item 4: driving seconds from the stop before (from the start for the first), when known.
    public var legSeconds: Int?
    /// §37 item 2: start, sight, hotel or end.
    public var role: TripRole
    /// §37 item 4: a hotel the app picked (not named by the driver).
    public var picked: Bool
    /// §48 item 1 (T-040t): the model's visit estimate (15–600), nil = by kind and role (`visitMinutes`).
    public var minutes: Int?
    /// §48 item 1: an extra the fit may leave out (kept as `spare`); the driver's and the must-see places are false.
    public var optional: Bool

    public init(index: Int, asked: String, place: Place, distanceMeters: Int?, mark: TripMark? = nil,
                legSeconds: Int? = nil, role: TripRole = .sight, picked: Bool = false,
                minutes: Int? = nil, optional: Bool = false) {
        self.minutes = minutes
        self.optional = optional
        self.role = role
        self.picked = picked
        self.index = index
        self.asked = asked
        self.place = place
        self.distanceMeters = distanceMeters
        self.mark = mark
        self.legSeconds = legSeconds
    }

    func renumbered(_ index: Int) -> TripStop {
        TripStop(index: index, asked: asked, place: place, distanceMeters: distanceMeters, mark: mark, legSeconds: legSeconds,
                 role: role, picked: picked, minutes: minutes, optional: optional)
    }

    /// §48 item 2: the visit minutes the fit counts: the model's, else by kind (sights) or role (the frame).
    public var visitMinutes: Int {
        switch role {
        case .start, .end, .hotel: return 0
        case .rentalPickup: return minutes ?? 30
        case .rentalReturn: return minutes ?? 20
        case .sight: return minutes ?? Self.defaultMinutes(place.kind)
        }
    }

    /// §48 item 2: temple 60, tower/viewpoint 60, park 90, museum 120, shop/market 90, food 60, other 90.
    public static func defaultMinutes(_ kind: PlaceKind?) -> Int {
        switch kind {
        case .temple, .tower, .food: return 60
        case .museum: return 120
        default: return 90
        }
    }

    /// §48 item 1: outside 15–600 is clamped.
    public static func clampMinutes(_ m: Int) -> Int { min(max(m, 15), 600) }
}

/// F-15b §3 (T-040i): the ordered list of 1–16 stops the app owns. Pure. Every change raises `generation`; a resolve
/// that finishes after a newer change is dropped by its caller (`OPTIONS_STALE`).
public struct TripList: Sendable, Hashable {
    /// At most 16 stops (高德 `/v3/distance` makes one request per stop, §26 item 1).
    public static let maxStops = 16

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
        dropLegs()
        changed()
    }

    /// Inserts at the 1-based `position` (1…count+1), or appends when nil.
    public mutating func insert(_ stop: TripStop, at position: Int? = nil) {
        stops.insert(stop, at: (position ?? stops.count + 1) - 1)
        dropLegs()
        changed()
    }

    public mutating func set(_ stop: TripStop, at index: Int) {
        stops[index - 1] = stop
        dropLegs()
        changed()
    }

    /// Moves the stop at `from` so it ends up at `to` (both 1-based, 1…count).
    public mutating func move(from: Int, to: Int) {
        let stop = stops.remove(at: from - 1)
        stops.insert(stop, at: to - 1)
        dropLegs()
        changed()
    }

    /// §28 (T-040n): the list becomes `new` (an ordering of stops); always a change.
    public mutating func arrange(_ new: [TripStop]) {
        // §37 item 1 (T-040o): a day's start / hotel / end are not counted in the 16.
        stops = Array(new.prefix(Self.maxStops + 2))
        changed()
    }

    /// §29 item 2: marks stop `index` (1-based, 1…count); a change.
    public mutating func setMark(at index: Int, _ mark: TripMark?) {
        stops[index - 1].mark = mark
        // A skipped stop is no longer the one driven from: the next stop's time is from elsewhere.
        if mark == .skipped, index < stops.count { stops[index].legSeconds = nil }
        changed()
    }

    /// §29 item 4: driving seconds per stop (nil unknown), in list order. Not a change (as a photo link).
    public mutating func setLegs(_ legs: [Int?]) {
        for i in stops.indices where i < legs.count { stops[i].legSeconds = legs[i] }
    }

    /// A hand edit changes which stop comes before which, so known driving times no longer hold.
    private mutating func dropLegs() {
        for i in stops.indices { stops[i].legSeconds = nil }
    }

    public func contains(placeID: String) -> Bool { stops.contains { $0.place.id == placeID } }

    /// F-15b §12: a photo link arrived. Not a list change: no renumbering, no new generation, so it never makes a
    /// resolve stale.
    public mutating func setPhoto(placeID: String, url: URL?) {
        stops = stops.map { $0.place.id == placeID
            ? TripStop(index: $0.index, asked: $0.asked, place: $0.place.with(photoURL: url), distanceMeters: $0.distanceMeters,
                       mark: $0.mark, legSeconds: $0.legSeconds, role: $0.role, picked: $0.picked,
                       minutes: $0.minutes, optional: $0.optional)
            : $0 }
    }

    /// §5.2: stops whose resolved or asked name contains `name`, after normalize (1-based indexes).
    public func matches(_ name: String) -> [Int] {
        stops.filter { Self.matches($0, name) }.map(\.index)
    }

    /// §5.2: the stop's resolved or asked name contains `name`, after normalize.
    public static func matches(_ stop: TripStop, _ name: String) -> Bool {
        let wanted = TranscriptText.normalize(name)
        guard !wanted.isEmpty else { return false }
        return TranscriptText.normalize(stop.place.name).contains(wanted) || TranscriptText.normalize(stop.asked).contains(wanted)
    }

    private mutating func changed() {
        stops = stops.enumerated().map { $0.element.renumbered($0.offset + 1) }
        generation += 1
    }
}
