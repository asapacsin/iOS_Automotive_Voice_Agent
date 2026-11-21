import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §15 (T-040l): a plan of 1–5 days, each a `TripList`, with an optional name and a current day (the last day
/// made, edited, read or routed). `revision` rises with every change of any day, so a kept trip route or a slow
/// lookup can tell the plan moved on. Pure.
public struct TripPlan: Sendable, Hashable {
    public static let maxDays = 5
    public static let maxName = 20

    public var name: String?
    /// §36 item 1 (T-040o): the trip is outside China; its names are searched on Apple.
    public var abroad = false
    /// §36 item 2d (T-040p): an `abroad` trip's city ("Tokyo, Japan"), the default of `navigate_to` while it runs.
    public var city: String?
    public private(set) var days: [TripList] = [TripList()] {
        didSet { assignIDs() }
    }
    /// §52 item 1 (T-040zb): the number of the next stop id (`s<n>`); ids are never reused within a plan.
    private var nextStopID = 1
    /// 1-based.
    public private(set) var currentDay = 1
    public private(set) var revision = 0
    /// §48 item 6 (T-040t): optional places the fit left out, resolved, not shown as cards.
    public var spare: [TripStop] = []
    /// §48 item 3: the day budget in minutes the plan was fitted to; nil for a plan never fitted.
    public var budgetMinutes: Int?
    /// §49 item 2 (T-040u): what the driver said about the trip that code cannot measure (≤ 60 characters); echoed to
    /// the model with the hotel choices, never read by code.
    public var wishes: String?

    public init() {}

    public init(name: String?, days: [TripList], currentDay: Int = 1) {
        self.name = name
        self.days = days.isEmpty ? [TripList()] : Array(days.prefix(Self.maxDays))
        self.currentDay = min(max(currentDay, 1), self.days.count)
        assignIDs()
    }

    /// §52 item 1: every stop gets a stable id. A stop without one gets `s<n>`; the two copies of one night's hotel
    /// (same place, both new) get the same id. An id already given is kept.
    private mutating func assignIDs() {
        var used = Set<String>()
        for day in days { for s in day.stops where !s.id.isEmpty { used.insert(s.id) } }
        for id in used {
            if id.hasPrefix("s"), let n = Int(id.dropFirst()), n >= nextStopID { nextStopID = n + 1 }
        }
        guard days.contains(where: { $0.stops.contains { $0.id.isEmpty } }) else { return }
        var fresh: [String: String] = [:]
        var out = days
        for d in out.indices {
            var stops = out[d].stops
            for i in stops.indices where stops[i].id.isEmpty {
                let key = stops[i].role == .hotel ? "hotel|\(stops[i].place.id)" : ""
                if !key.isEmpty, let known = fresh[key] {
                    stops[i].id = known
                } else {
                    stops[i].id = "s\(nextStopID)"
                    nextStopID += 1
                    if !key.isEmpty { fresh[key] = stops[i].id }
                }
            }
            out[d].setIDs(stops.map(\.id))
        }
        days = out
    }

    /// §52 item 1: the stop with this id and its day (1-based); the first copy of a night's hotel.
    public func stop(id: String) -> (day: Int, stop: TripStop)? {
        allStops.first { $0.stop.id == id }
    }

    /// §52 item 3 (T-040zb): the whole plan written by `set_trip_plan` (already checked). Stops keep their ids; the
    /// current day stays when it still exists. Always a change.
    public mutating func write(days lists: [TripList]) {
        days = lists.isEmpty ? [TripList()] : Array(lists.prefix(Self.maxDays))
        currentDay = min(max(currentDay, 1), days.count)
        revision += 1
    }

    /// §52 item 4: the stop with `id` is now placed at `place` (a background retry found it); false when gone.
    public mutating func place(id: String, at place: Place) -> Bool {
        var found = false
        for d in days.indices {
            for (i, s) in days[d].stops.enumerated() where s.id == id && !s.placed {
                var stop = TripStop(index: 0, asked: s.asked, place: place, distanceMeters: s.distanceMeters, mark: s.mark,
                                    role: s.role, minutes: s.minutes, importance: s.importance, id: s.id, placed: true,
                                    pickedBy: s.pickedBy)
                stop.legSeconds = nil
                days[d].set(stop, at: i + 1)
                found = true
            }
        }
        if found { revision += 1 }
        return found
    }

    public var dayCount: Int { days.count }
    public var stopCount: Int { days.reduce(0) { $0 + $1.count } }
    public var isEmpty: Bool { stopCount == 0 }

    /// The current day's list. Setting it is a change only when the list itself changed (a photo link is not).
    public var current: TripList {
        get { days[currentDay - 1] }
        set {
            let changed = newValue.generation != days[currentDay - 1].generation
            days[currentDay - 1] = newValue
            if changed { revision += 1 }
        }
    }

    /// Makes `day` (1…dayCount) the current day; false when out of range.
    /// Another day is a plan change (a kept route or a slow lookup of the old day no longer applies).
    public mutating func select(_ day: Int) -> Bool {
        guard (1...days.count).contains(day) else { return false }
        if day != currentDay {
            currentDay = day
            revision += 1
        }
        return true
    }

    /// §15 item 2: `make_trip_list day=d` replaces day d (d ≤ dayCount + 1, at most 5 days); false when out of range.
    public mutating func replaceDay(_ day: Int, with list: TripList) -> Bool {
        guard day >= 1, day <= min(days.count + 1, Self.maxDays) else { return false }
        if day == days.count + 1 {
            days.append(list)
        } else {
            days[day - 1] = list
        }
        currentDay = day
        revision += 1
        return true
    }

    /// §15 item 6: `make_trip_list days=[[…],[…]]`: a new plan of those days (at most 5), the first day with stops current; the name goes
    /// with the old plan.
    public mutating func replaceAll(withDays lists: [TripList]) {
        days = lists.isEmpty ? [TripList()] : Array(lists.prefix(Self.maxDays))
        // The first day with stops is current (a day where nothing was found stays, empty).
        currentDay = (days.firstIndex { $0.count > 0 } ?? 0) + 1
        name = nil
        spare = []
        budgetMinutes = nil
        wishes = nil
        revision += 1
    }

    /// `make_trip_list` without `day`: the whole plan becomes one day (phase 1); the name goes with the old plan.
    public mutating func replaceAll(with list: TripList) {
        days = [list]
        currentDay = 1
        name = nil
        spare = []
        budgetMinutes = nil
        wishes = nil
        revision += 1
    }

    /// §15 item 2: `clear day=d` removes that day; later days move up. The last day left becomes an empty day.
    public mutating func removeDay(_ day: Int) -> Bool {
        guard (1...days.count).contains(day) else { return false }
        days.remove(at: day - 1)
        if days.isEmpty { days = [TripList()] }
        currentDay = min(max(day - 1, 1), days.count)
        revision += 1
        return true
    }

    /// `clear` without `day`: the whole plan is cleared (the name too).
    public mutating func clearAll() {
        days = [TripList()]
        currentDay = 1
        name = nil
        spare = []
        budgetMinutes = nil
        wishes = nil
        revision += 1
    }

    /// §12: a photo link for every stop of that place, on any day; not a change.
    public mutating func setPhoto(placeID: String, url: URL?) {
        days = days.map { day in
            var d = day
            d.setPhoto(placeID: placeID, url: url)
            return d
        }
    }

    /// §28 item 3 (T-040n): the days ordered again; the name is kept, day 1 becomes current. Always a change.
    public mutating func arrange(days lists: [TripList]) {
        days = lists.isEmpty ? [TripList()] : Array(lists.prefix(Self.maxDays))
        currentDay = min(max(currentDay, 1), days.count)
        revision += 1
    }

    /// §29 item 2: marks stop `index` (1-based) of `day` (1-based); a change.
    public mutating func mark(day: Int, index: Int, _ mark: TripMark?) {
        guard days.indices.contains(day - 1), (1...days[day - 1].count).contains(index) else { return }
        days[day - 1].setMark(at: index, mark)
        revision += 1
    }

    /// Every stop of the plan, by day.
    public var allStops: [(day: Int, stop: TripStop)] {
        days.enumerated().flatMap { d, list in list.stops.map { (d + 1, $0) } }
    }

    /// Replaces this plan with `other` (open); always a change.
    public mutating func load(_ other: TripPlan) {
        name = other.name
        abroad = other.abroad
        city = other.city
        days = other.days
        currentDay = other.currentDay
        spare = other.spare
        budgetMinutes = other.budgetMinutes
        wishes = other.wishes
        revision += 1
    }
}

/// §14 and §16 item 8: what is written to `Application Support/trip/` (version 1). Per stop: asked name, place id,
/// name, address, district, coordinate (GCJ-02) and photo link. Not kept: generations, passed stops, the kept route.
public enum TripPlanFile {
    public static let version = 1

    struct Stop: Codable, Hashable {
        var asked: String
        var id: String
        var name: String
        var address: String?
        var district: String?
        var lat: Double
        var lng: Double
        var photo: String?
        /// T-040n §29 item 2 (optional, so older files still read): visited / skipped, driving seconds, city.
        var mark: TripMark?
        var leg: Int?
        var city: String?
        /// T-040o §37 (optional): role, a picked hotel, Apple's country code.
        var role: TripRole?
        var picked: Bool?
        var country: String?
        /// T-040r §46 item 6 (optional): the kind of place (a raw value; an unknown one reads as nil, not a broken file).
        var kind: String?
        /// T-040t §48 (optional): the model's visit minutes and the optional flag.
        var minutes: Int?
        var optional: Bool?
        /// T-040u §49 item 1 (optional): importance 1–3; nil reads from `optional` (false = 3, true = 1).
        var importance: Int?
        /// T-040zb §52 item 1 (optional): the stop id, not placed yet, who chose it.
        var sid: String?
        var unplaced: Bool?
        var by: TripPickedBy?
    }

    struct Plan: Codable, Hashable {
        var name: String?
        var currentDay: Int
        var days: [[Stop]]
        var savedAt: Double?
        /// T-040o §36 item 1 (optional).
        var abroad: Bool?
        /// T-040p §36 item 2d (optional).
        var city: String?
        /// T-040t §48 (optional): the spare places and the day budget.
        var spare: [Stop]?
        var budget: Int?
        /// T-040u §49 item 2 (optional): the driver's wishes.
        var wishes: String?
    }

    struct Current: Codable { var version: Int; var plan: Plan }
    struct Saved: Codable {
        var version: Int
        var plans: [Plan]
        /// §16 item 3: 「上一个清单」.
        var previous: Plan?
    }

    static func encode(_ s: TripStop) -> Stop {
        Stop(asked: s.asked, id: s.place.id, name: s.place.name, address: s.place.address,
             district: s.place.district, lat: s.place.coordinate.latitude, lng: s.place.coordinate.longitude,
             photo: s.place.photoURL?.absoluteString, mark: s.mark, leg: s.legSeconds, city: s.place.city,
             role: s.role == .sight ? nil : s.role, picked: s.picked ? true : nil, country: s.place.countryCode, kind: s.place.kind?.rawValue,
             minutes: s.minutes, optional: s.optional ? true : nil, importance: s.importance == 3 || s.importance == 1 ? nil : s.importance,
             sid: s.id.isEmpty ? nil : s.id, unplaced: s.placed ? nil : true, by: s.pickedBy)
    }

    static func encode(_ plan: TripPlan, savedAt: Date? = nil) -> Plan {
        Plan(name: plan.name, currentDay: plan.currentDay,
             days: plan.days.map { day in day.stops.map(encode) },
             savedAt: savedAt?.timeIntervalSince1970, abroad: plan.abroad ? true : nil, city: plan.abroad ? plan.city : nil,
             spare: plan.spare.isEmpty ? nil : plan.spare.map(encode), budget: plan.budgetMinutes, wishes: plan.wishes)
    }

    static func decode(_ s: Stop) -> TripStop {
        TripStop(index: 0, asked: s.asked,
                 place: Place(id: s.id, name: s.name, address: s.address,
                              coordinate: GeoCoordinate(latitude: s.lat, longitude: s.lng, datum: .gcj02),
                              distanceMeters: nil, city: s.city, district: s.district,
                              photoURL: TripPhotoLink.secure(s.photo), countryCode: s.country, kind: s.kind.flatMap(PlaceKind.init(rawValue:))),
                 distanceMeters: nil, mark: s.mark, legSeconds: s.leg, role: s.role ?? .sight, picked: s.picked ?? false,
                 minutes: s.minutes, optional: s.optional ?? false, importance: s.importance,
                 id: s.sid ?? "", placed: !(s.unplaced ?? false), pickedBy: s.by ?? ((s.picked ?? false) ? .app : .model))
    }

    static func decode(_ plan: Plan) -> TripPlan {
        let days = plan.days.prefix(TripPlan.maxDays).map { stops in
            var list = TripList()
            list.arrange(stops.prefix(TripList.maxStops + 2).map(decode))
            return list
        }
        var out = TripPlan(name: plan.name, days: Array(days), currentDay: plan.currentDay)
        out.abroad = plan.abroad ?? false
        out.city = out.abroad ? plan.city : nil
        out.spare = (plan.spare ?? []).prefix(TripFitter.maxCandidates).map(decode)
        out.budgetMinutes = plan.budget
        out.wishes = plan.wishes
        return out
    }

    public static func current(_ plan: TripPlan) -> Data {
        (try? JSONEncoder().encode(Current(version: version, plan: encode(plan)))) ?? Data()
    }

    /// nil when unreadable or of an unknown version (§14 item 4).
    public static func current(from data: Data) -> TripPlan? {
        guard let file = try? JSONDecoder().decode(Current.self, from: data), file.version == version else { return nil }
        return decode(file.plan)
    }
}

/// §16: the named plans (at most 20, newest first) and the 「上一个清单」 slot.
public struct SavedTripPlans: Sendable, Hashable {
    public static let maxPlans = 20
    public static let previousName = "上一个清单"

    public struct Entry: Sendable, Hashable {
        public let name: String
        public let plan: TripPlan
        public let savedAt: Date
    }

    public private(set) var entries: [Entry] = []
    public var previous: TripPlan?

    public init() {}

    /// §16 item 4: exact after normalize, else the one name containing it or contained in it.
    public enum Match: Sendable, Hashable { case found(Int), ambiguous, none }

    public func match(_ asked: String) -> Match {
        let wanted = TranscriptText.normalize(asked)
        guard !wanted.isEmpty else { return .none }
        if let exact = entries.firstIndex(where: { TranscriptText.normalize($0.name) == wanted }) { return .found(exact) }
        let near = entries.indices.filter {
            let name = TranscriptText.normalize(entries[$0].name)
            return name.contains(wanted) || wanted.contains(name)
        }
        if near.count > 1 { return .ambiguous }
        return near.first.map(Match.found) ?? .none
    }

    /// Saves under `name` (an existing exact name is replaced and moves to the front); returns whether it replaced.
    public mutating func save(_ plan: TripPlan, as name: String, at date: Date) -> Bool {
        var named = plan
        named.name = name
        let entry = Entry(name: name, plan: named, savedAt: date)
        if let i = entries.firstIndex(where: { TranscriptText.normalize($0.name) == TranscriptText.normalize(name) }) {
            entries.remove(at: i)
            entries.insert(entry, at: 0)
            return true
        }
        entries.insert(entry, at: 0)
        return false
    }

    public mutating func delete(at index: Int) { entries.remove(at: index) }

    public mutating func rename(at index: Int, to name: String) {
        let old = entries[index]
        var plan = old.plan
        plan.name = name
        entries[index] = Entry(name: name, plan: plan, savedAt: old.savedAt)
    }

    public func data() -> Data {
        let file = TripPlanFile.Saved(version: TripPlanFile.version,
                                      plans: entries.map { TripPlanFile.encode($0.plan, savedAt: $0.savedAt) },
                                      previous: previous.map { TripPlanFile.encode($0) })
        return (try? JSONEncoder().encode(file)) ?? Data()
    }

    public init?(data: Data) {
        guard let file = try? JSONDecoder().decode(TripPlanFile.Saved.self, from: data), file.version == TripPlanFile.version
        else { return nil }
        entries = file.plans.prefix(Self.maxPlans).compactMap { p in
            guard let name = p.name else { return nil }
            return Entry(name: name, plan: TripPlanFile.decode(p), savedAt: Date(timeIntervalSince1970: p.savedAt ?? 0))
        }
        previous = file.previous.map(TripPlanFile.decode)
    }
}

/// What the screen shows of the plans (§11 item 5 day tabs, §16 item 6 「我的行程」).
public struct TripPlansSummary: Sendable, Hashable {
    public struct Saved: Sendable, Hashable, Identifiable {
        public var id: String { name }
        public let name: String
        public let days: Int
        public let stops: Int
    }
    public let name: String?
    public let days: Int
    public let currentDay: Int
    public let saved: [Saved]

    public init(_ plan: TripPlan, _ saved: SavedTripPlans) {
        name = plan.name
        days = plan.dayCount
        currentDay = plan.currentDay
        self.saved = saved.entries.map { Saved(name: $0.name, days: $0.plan.dayCount, stops: $0.plan.stopCount) }
    }
}

/// §14: the app's files for the plan (`current.json`, `plans.json` in `Application Support/trip/`), written
/// atomically with complete-until-first-unlock protection and excluded from backup.
public protocol TripFiles: Sendable {
    func read(_ name: String) -> Data?
    func write(_ name: String, _ data: Data)
    /// §14 item 4: an unreadable file is moved aside as `<name without .json>.bad.json`, not deleted.
    func moveAside(_ name: String)
}
