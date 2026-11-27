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

/// F-15b §52 item 1 (T-040zb): who chose a stop: the driver (a screen add), the model (`set_trip_plan`, from the
/// driver's words) or the app (a hotel or rental it picked).
public enum TripPickedBy: String, Sendable, Hashable, Codable {
    case driver, model, app
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
    /// §37 item 4: a hotel the app picked (not named by the driver). §52 item 1: `pickedBy == .app`.
    public var picked: Bool {
        get { pickedBy == .app }
        set { pickedBy = newValue ? .app : (pickedBy == .app ? .model : pickedBy) }
    }
    /// §52 item 1 (T-040zb): stable for the plan's life; "" until the plan gives it one (`TripPlan` assigns them).
    public var id: String
    /// §52 item 1: on the map (a place was found) or not yet (searched again in the background, item 4).
    public var placed: Bool
    /// §52 item 1: who chose the stop.
    public var pickedBy: TripPickedBy
    /// §48 item 1 (T-040t): the model's visit estimate (15–600), nil = by kind and role (`visitMinutes`).
    public var minutes: Int?
    /// §48 item 1: an extra the fit may leave out (kept as `spare`); the driver's and the must-see places are false.
    /// §49 item 1 (T-040u): replaced by `importance` (false = 3, true = 1).
    public var optional: Bool {
        get { importance < 3 }
        set { importance = newValue ? 1 : 3 }
    }
    /// §49 item 1: 3 = must-see (never dropped by code), 2 = worth it, 1 = extra.
    public var importance: Int
    /// F-15b §64 item 6 (T-040zq): a time-limited event at this venue, as the planner placed it and code checked it.
    public var event: TripEvent?
    /// F-15b §67 item 3 (T-040zt): the text looked up on the map (the planner's `location`); `asked` keeps its `name`.
    /// Equals `asked` when the planner gave no `location` and for stops from before §67.
    public var location: String

    public init(index: Int, asked: String, place: Place, distanceMeters: Int?, mark: TripMark? = nil,
                legSeconds: Int? = nil, role: TripRole = .sight, picked: Bool = false,
                minutes: Int? = nil, optional: Bool = false, importance: Int? = nil,
                id: String = "", placed: Bool = true, pickedBy: TripPickedBy? = nil, event: TripEvent? = nil,
                location: String? = nil) {
        self.event = event
        self.location = location ?? asked
        self.id = id
        self.placed = placed
        self.pickedBy = pickedBy ?? (picked ? .app : .model)
        self.minutes = minutes
        self.importance = importance.map(Self.clampImportance) ?? (optional ? 1 : 3)
        self.role = role
        self.index = index
        self.asked = asked
        self.place = place
        self.distanceMeters = distanceMeters
        self.mark = mark
        self.legSeconds = legSeconds
    }

    func renumbered(_ index: Int) -> TripStop {
        TripStop(index: index, asked: asked, place: place, distanceMeters: distanceMeters, mark: mark, legSeconds: legSeconds,
                 role: role, minutes: minutes, importance: importance, id: id, placed: placed, pickedBy: pickedBy, event: event,
                 location: location)
    }

    /// F-15b §67 item 4 (T-040zt): the card title: what the driver calls the stop (`asked`); the map's name for a stop
    /// the app picked (its `asked` is a search word such as 「酒店」) or one without `asked`.
    public var title: String { pickedBy == .app || asked.isEmpty ? place.name : asked }

    /// §67 item 4: 「<name>（<place name>）」 when the map's name differs, else 「<name>」 (a stop not placed: the name).
    /// F-15b §66 items 4, 6 (T-040zs): an event stop linked to the events list is 「<event>（<venue>，<start>–<end>）」,
    /// 「场馆未找到」 / 「日期未找到」 in place of what no source confirmed.
    public var label: String {
        if let e = event, e.linked == true {
            // §64 item 4: not placed as an event (closed that day); still no venue.
            if e.closedDay == true { return "\(e.title)（\(TripEvent.venueMissing)）" }
            return "\(e.title)（\(e.venueFound == false ? TripEvent.venueMissing : location)，\(e.shortDates)）"
        }
        return placed && title != place.name ? "\(title)（\(place.name)）" : title
    }

    /// §66 item 6: false for a linked event with no confirmed venue: never looked up on the map (not by the event's
    /// name, not by the planner's `location`), so never placed and no navigation.
    public var mapLookup: Bool { !(event?.linked == true && event?.venueFound == false) }

    /// The event shown on the stop (its line, picture, the planner's `event`): none for one not placed as an event
    /// (`closedDay`).
    public var shownEvent: TripEvent? { event?.closedDay == true ? nil : event }

    /// §49 item 1: importance is 1–3.
    public static func clampImportance(_ i: Int) -> Int { min(max(i, 1), 3) }

    /// §48 item 2: the visit minutes the fit counts: the model's, else by kind (sights) or role (the frame).
    public var visitMinutes: Int {
        switch role {
        case .start, .end: return 0
        // F-15b §63 item 2 (T-040zp): a hotel merged with the sight of the same place keeps that sight's minutes.
        case .hotel: return minutes ?? 0
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

    /// The whole list replaced.
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

    /// F-15b §63 items 1-3 (T-040zp): a stop that is the same place as the stop right before it is merged into it; a
    /// change only when something merged.
    mutating func mergeAdjacent() {
        let merged = Self.mergedAdjacent(stops)
        guard merged.count != stops.count else { return }
        stops = merged
        dropLegs()
        changed()
    }

    /// §63 item 1: same `Place.id`, or the same found name (both placed).
    static func samePlace(_ a: TripStop, _ b: TripStop) -> Bool {
        if !a.place.id.isEmpty, a.place.id == b.place.id { return true }
        guard a.placed, b.placed else { return false }
        let x = TranscriptText.normalize(a.place.name)
        return !x.isEmpty && x == TranscriptText.normalize(b.place.name)
    }

    /// §63 items 1-3: a sight or hotel next to a sight or hotel of the same place merges (a day's start and night
    /// hotel merge only when nothing is between them). The hotel wins and keeps the sight's minutes; two sights keep the larger minutes. The
    /// merged stop keeps the first stop's position.
    public static func mergedAdjacent(_ stops: [TripStop]) -> [TripStop] {
        var out: [TripStop] = []
        for s in stops {
            guard let last = out.last, last.role == .sight || last.role == .hotel, s.role == .sight || s.role == .hotel,
                  samePlace(last, s) else {
                out.append(s)
                continue
            }
            let hotel = last.role == .hotel ? last : (s.role == .hotel ? s : nil)
            var keep: TripStop
            if last.role == .hotel, s.role == .hotel {
                // The night's hotel (the later one) is kept, with the time already spent there.
                keep = s
                keep.minutes = max(last.visitMinutes, s.visitMinutes)
                if keep.minutes == 0 { keep.minutes = nil }
                if keep.mark == nil { keep.mark = last.mark }
            } else if let hotel {
                let sight = hotel == last ? s : last
                keep = hotel
                keep.minutes = max(sight.visitMinutes, hotel.visitMinutes)
                if keep.mark == nil { keep.mark = sight.mark }
            } else {
                keep = last
                keep.minutes = max(last.visitMinutes, s.visitMinutes)
                keep.importance = max(last.importance, s.importance)
            }
            out[out.count - 1] = keep.renumbered(last.index)
        }
        return out
    }

    /// §52 item 1 (T-040zb): the plan's stop ids, in order (not a change: the stops are the same).
    mutating func setIDs(_ ids: [String]) {
        for i in stops.indices where i < ids.count { stops[i].id = ids[i] }
    }

    public func contains(placeID: String) -> Bool { stops.contains { $0.place.id == placeID } }

    /// F-15b §12: a photo link arrived. Not a list change: no renumbering, no new generation, so it never makes a
    /// resolve stale.
    public mutating func setPhoto(placeID: String, url: URL?) {
        stops = stops.map { $0.place.id == placeID
            ? TripStop(index: $0.index, asked: $0.asked, place: $0.place.with(photoURL: url), distanceMeters: $0.distanceMeters,
                       mark: $0.mark, legSeconds: $0.legSeconds, role: $0.role,
                       minutes: $0.minutes, importance: $0.importance, id: $0.id, placed: $0.placed, pickedBy: $0.pickedBy,
                       event: $0.event, location: $0.location)
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
