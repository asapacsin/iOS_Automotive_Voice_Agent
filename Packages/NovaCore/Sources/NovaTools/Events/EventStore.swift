import Foundation
import NovaKit
import Synchronization

/// F-18 §35 item 5 (T-046x): one kept event. Only events whose dates code found on their opened page (item 6).
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

/// Item 5: a city's browsed window and when.
public struct BrowsedWindow: Sendable, Hashable, Codable {
    public let city: String
    public let from: String
    public let to: String
    public let at: Date
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

/// Item 5: the event store. Entries whose `end` is before today are dropped on load; a refresh replaces a city's
/// entries for the window it browsed. Never sent anywhere.
public actor EventStore {
    struct File: Codable {
        var version = 1
        var events: [EventEntry] = []
        var windows: [BrowsedWindow] = []
    }

    /// Item 2: a browse younger than this answers from the store.
    public static let freshFor: TimeInterval = 24 * 3600
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

    /// Item 2: every city browsed less than 24 h ago for a window covering `from`…`to`.
    public func covers(cities: [String], from: String, to: String) -> Bool {
        let t = now()
        return cities.allSatisfy { city in
            file.windows.contains { $0.city == city && $0.from <= from && $0.to >= to && t.timeIntervalSince($0.at) < Self.freshFor }
        }
    }

    /// The kept events of `cities` overlapping `from`…`to`, sorted by start.
    public func events(cities: [String], from: String, to: String) -> [EventEntry] {
        file.events.filter { cities.contains($0.city) && $0.start <= to && $0.end >= from }
            .sorted { ($0.start, $0.name) < ($1.start, $1.name) }
    }

    /// Item 5: the cities whose today…+30 window is older than 24 h (the app-open refresh).
    public func stale(_ cities: [String]) -> [String] {
        let from = today.description, to = today.adding(days: Self.refreshDays).description
        return cities.filter { !covers(cities: [$0], from: from, to: to) }
    }

    /// A browse of `city` for `from`…`to`: its entries in that window are replaced by `entries`.
    public func replace(city: String, from: String, to: String, with entries: [EventEntry]) {
        file.events.removeAll { $0.city == city && $0.start <= to && $0.end >= from }
        file.events += entries.filter { $0.city == city }
        file.windows.removeAll { $0.city == city && $0.from >= from && $0.to <= to }
        file.windows.append(BrowsedWindow(city: city, from: from, to: to, at: now()))
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
