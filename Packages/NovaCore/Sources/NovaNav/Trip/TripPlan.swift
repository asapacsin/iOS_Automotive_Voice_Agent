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
    public private(set) var days: [TripList] = [TripList()]
    /// 1-based.
    public private(set) var currentDay = 1
    public private(set) var revision = 0

    public init() {}

    public init(name: String?, days: [TripList], currentDay: Int = 1) {
        self.name = name
        self.days = days.isEmpty ? [TripList()] : Array(days.prefix(Self.maxDays))
        self.currentDay = min(max(currentDay, 1), self.days.count)
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

    /// `make_trip_list` without `day`: the whole plan becomes one day (phase 1); the name goes with the old plan.
    public mutating func replaceAll(with list: TripList) {
        days = [list]
        currentDay = 1
        name = nil
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

    /// Replaces this plan with `other` (open); always a change.
    public mutating func load(_ other: TripPlan) {
        name = other.name
        days = other.days
        currentDay = other.currentDay
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
    }

    struct Plan: Codable, Hashable {
        var name: String?
        var currentDay: Int
        var days: [[Stop]]
        var savedAt: Double?
    }

    struct Current: Codable { var version: Int; var plan: Plan }
    struct Saved: Codable {
        var version: Int
        var plans: [Plan]
        /// §16 item 3: 「上一个清单」.
        var previous: Plan?
    }

    static func encode(_ plan: TripPlan, savedAt: Date? = nil) -> Plan {
        Plan(name: plan.name, currentDay: plan.currentDay,
             days: plan.days.map { day in
                 day.stops.map { s in
                     Stop(asked: s.asked, id: s.place.id, name: s.place.name, address: s.place.address,
                          district: s.place.district, lat: s.place.coordinate.latitude, lng: s.place.coordinate.longitude,
                          photo: s.place.photoURL?.absoluteString)
                 }
             },
             savedAt: savedAt?.timeIntervalSince1970)
    }

    static func decode(_ plan: Plan) -> TripPlan {
        let days = plan.days.prefix(TripPlan.maxDays).map { stops in
            var list = TripList()
            list.replace(stops.prefix(TripList.maxStops).map { s in
                (s.asked, Place(id: s.id, name: s.name, address: s.address,
                                coordinate: GeoCoordinate(latitude: s.lat, longitude: s.lng, datum: .gcj02),
                                distanceMeters: nil, district: s.district, photoURL: TripPhotoLink.secure(s.photo)), nil)
            })
            return list
        }
        return TripPlan(name: plan.name, days: Array(days), currentDay: plan.currentDay)
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
