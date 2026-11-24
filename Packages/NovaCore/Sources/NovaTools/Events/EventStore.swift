import Foundation
import NovaKit
import Synchronization

/// F-18 §35 item 5 (T-046x), §39 item 4 (T-046zb): one kept event, after code's checks.
public struct EventEntry: Sendable, Hashable, Codable {
    public let name: String
    public let start: String
    public let end: String
    public let datesText: String
    public let venue: String
    public let city: String
    public let sourceURL: String
    public let sourceSite: String
    public let fetchedAt: Date

    public init(name: String, start: String, end: String, datesText: String, venue: String, city: String,
                sourceURL: String, sourceSite: String, fetchedAt: Date) {
        self.name = name
        self.start = start
        self.end = end
        self.datesText = datesText
        self.venue = venue
        self.city = city
        self.sourceURL = sourceURL
        self.sourceSite = sourceSite
        self.fetchedAt = fetchedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, start, end, venue, city
        case datesText = "dates_text"
        case sourceURL = "source_url"
        case sourceSite = "source_site"
        case fetchedAt = "fetched_at"
    }

    /// What `find_events` returns for it.
    public var json: JSONValue {
        ["name": .string(name), "start": .string(start), "end": .string(end), "dates_text": .string(datesText),
         "venue": .string(venue), "city": .string(city), "source_url": .string(sourceURL)]
    }
}

/// F-18 §39 item 5 (T-046zb, amends §35 item 5): a city × kind searched for a window, when, and how many events it
/// kept (none: fresh for 30 minutes only). A window from an older file has no kind and never matches.
public struct SearchedWindow: Sendable, Hashable, Codable {
    public let city: String
    public let kind: String
    public let from: String
    public let to: String
    public let at: Date
    public let kept: Int

    public init(city: String, kind: String, from: String, to: String, at: Date, kept: Int) {
        self.city = city
        self.kind = kind
        self.from = from
        self.to = to
        self.at = at
        self.kept = kept
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        city = try c.decode(String.self, forKey: .city)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        from = try c.decode(String.self, forKey: .from)
        to = try c.decode(String.self, forKey: .to)
        at = try c.decode(Date.self, forKey: .at)
        kept = try c.decodeIfPresent(Int.self, forKey: .kept) ?? 0
    }

    /// How long it answers from the store.
    public var freshFor: TimeInterval { kept > 0 ? EventStore.freshFor : EventStore.emptyFreshFor }
}

/// Where the store's file lives (`Application Support/events.json` in the app). Local only (I-8).
public protocol EventStorage: Sendable {
    func load() -> Data?
    func save(_ data: Data)
}

/// The file in the app; any directory in tests.
public struct FileEventStorage: EventStorage {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> Data? { try? Data(contentsOf: url) }
    public func save(_ data: Data) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

public final class MemoryEventStorage: EventStorage {
    private let data: Mutex<Data?>
    public init(_ initial: Data? = nil) { data = Mutex(initial) }
    public func load() -> Data? { data.withLock { $0 } }
    public func save(_ d: Data) { data.withLock { $0 = d } }
    public var saved: Data? { load() }
}

/// Item 5: the event store. Entries whose `end` is before today are dropped on load; a search adds what it kept (the
/// same city, name and start replaced) and marks each city × kind it searched (§39 item 5). Never sent anywhere.
public actor EventStore {
    struct File: Codable {
        var version = 2
        var events: [EventEntry] = []
        var windows: [SearchedWindow] = []
    }

    /// Item 2: a search that kept events answers from the store this long.
    public static let freshFor: TimeInterval = 24 * 3600
    /// §39 item 5: a search that kept no event for a city × kind, only this long.
    public static let emptyFreshFor: TimeInterval = 30 * 60
    /// Item 5: the app-open refresh window, today…today+30.
    public static let refreshDays = 30

    private let storage: any EventStorage
    private let now: @Sendable () -> Date
    private let zone: @Sendable () -> TimeZone
    private var file = File()

    public init(storage: any EventStorage, now: @escaping @Sendable () -> Date = { Date() },
                zone: @escaping @Sendable () -> TimeZone = { .current }) {
        self.storage = storage
        self.now = now
        self.zone = zone
        let today = EventDay(now(), zone: zone()).description
        if let data = storage.load(), var f = try? Self.decoder.decode(File.self, from: data) {
            f.events.removeAll { $0.end < today }
            file = f
        }
    }

    public var today: EventDay { EventDay(now(), zone: zone()) }

    /// §39 item 5: a store hit only when every city × kind was searched for a window covering `from`…`to` and is still
    /// fresh. The age in seconds of the oldest of those (each pair's newest covering search); nil: a miss.
    public func age(cities: [String], kinds: [String], from: String, to: String) -> TimeInterval? {
        let t = now()
        var oldest: TimeInterval = 0
        for city in cities {
            for kind in kinds {
                let ages = file.windows.filter { $0.city == city && $0.kind == kind && $0.from <= from && $0.to >= to }
                    .map { (age: t.timeIntervalSince($0.at), fresh: $0.freshFor) }
                    .filter { $0.age < $0.fresh }.map(\.age)
                guard let newest = ages.min() else { return nil }
                oldest = max(oldest, newest)
            }
        }
        return oldest
    }

    public func covers(cities: [String], kinds: [String], from: String, to: String) -> Bool {
        age(cities: cities, kinds: kinds, from: from, to: to) != nil
    }

    /// The kept events of `cities` overlapping `from`…`to`, sorted by start.
    public func events(cities: [String], from: String, to: String) -> [EventEntry] {
        file.events.filter { cities.contains($0.city) && $0.start <= to && $0.end >= from }
            .sorted { ($0.start, $0.name) < ($1.start, $1.name) }
    }

    /// Item 5: the cities whose today…+30 window with the default kinds is not fresh (the app-open refresh).
    public func stale(_ cities: [String]) -> [String] {
        let from = today.description, to = today.adding(days: Self.refreshDays).description
        return cities.filter { !covers(cities: [$0], kinds: EventSearchRun.defaultKinds, from: from, to: to) }
    }

    /// §39 item 5: a search's kept events and the city × kind pairs it searched for `from`…`to`.
    public func record(_ entries: [EventEntry], searched: [SearchedPair], from: String, to: String) {
        for e in entries {
            file.events.removeAll { $0.city == e.city && $0.name == e.name && $0.start == e.start }
            file.events.append(e)
        }
        let at = now()
        for p in searched {
            file.windows.removeAll { $0.city == p.city && $0.kind == p.kind && $0.from >= from && $0.to <= to }
            file.windows.append(SearchedWindow(city: p.city, kind: p.kind, from: from, to: to, at: at, kept: p.kept))
        }
        save()
    }

    public var all: [EventEntry] { file.events }

    private func save() {
        guard let data = try? Self.encoder.encode(file) else { return }
        storage.save(data)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
