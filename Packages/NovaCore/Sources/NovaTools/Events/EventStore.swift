import Foundation
import NovaKit
import Synchronization

/// F-18 §35 item 5 (T-046x), §39 item 4 (T-046zb): one kept event, after code's checks.
/// F-18 §43 item 4 (T-046zf): its picture (`image_url`), how it was found (`og`/`search`/`none`) and the day the
/// picture was looked for (at most once per event per day).
/// F-18 §44 item 5 (T-046zg): `venue` holds the confirmed parts only (「；」 between them); how the venue and the dates
/// were confirmed (`page`/`search`/`none`; with `none` the dates are the model's, used only to keep or drop the event);
/// the confirmed start time and ticket notes; the day and time the checks (and item 2's search) ran.
public struct EventEntry: Sendable, Hashable, Codable {
    public let name: String
    public var start: String
    public var end: String
    public let datesText: String
    public var venue: String
    public let city: String
    public let sourceURL: String
    public let sourceSite: String
    public let fetchedAt: Date
    public var imageURL: String?
    public var imageVia: String
    public var imageOn: String?
    public var venueVia: String
    public var datesVia: String
    /// §44 item 8: `HH:MM` when the source states it; empty otherwise.
    public var time: String
    /// §44 item 9: 「免费」 「需预约」 …; empty: nothing shown.
    public var ticket: [String]
    public var checkedOn: String?
    public var checkedAt: Date?
    /// F-18 §46 items 6, 9 (T-046zi): `start` (a show or race) or `opening` (daily opening hours); the urls of the
    /// sources that state the venue and the hour (empty: the poster); every picture reading of item 5 (its JSON text).
    public var timeKind: String = "start"
    public var venueURL: String = ""
    public var timeURL: String = ""
    public var readings: [String] = []

    public init(name: String, start: String, end: String, datesText: String, venue: String, city: String,
                sourceURL: String, sourceSite: String, fetchedAt: Date,
                imageURL: String? = nil, imageVia: String = "none", imageOn: String? = nil,
                venueVia: String = "none", datesVia: String = "none", time: String = "", ticket: [String] = [],
                checkedOn: String? = nil, checkedAt: Date? = nil) {
        self.name = name
        self.start = start
        self.end = end
        self.datesText = datesText
        self.venue = venue
        self.city = city
        self.sourceURL = sourceURL
        self.sourceSite = sourceSite
        self.fetchedAt = fetchedAt
        self.imageURL = imageURL
        self.imageVia = imageVia
        self.imageOn = imageOn
        self.venueVia = venueVia
        self.datesVia = datesVia
        self.time = time
        self.ticket = ticket
        self.checkedOn = checkedOn
        self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey {
        case name, start, end, venue, city
        case datesText = "dates_text"
        case sourceURL = "source_url"
        case sourceSite = "source_site"
        case fetchedAt = "fetched_at"
        case imageURL = "image_url"
        case imageVia = "image_via"
        case imageOn = "image_on"
        case venueVia = "venue_via"
        case datesVia = "dates_via"
        case time, ticket
        case checkedOn = "checked_on"
        case checkedAt = "checked_at"
        case timeKind = "time_kind"
        case venueURL = "venue_url"
        case timeURL = "time_url"
        case readings
    }

    /// An entry from an older store file has no picture fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        start = try c.decode(String.self, forKey: .start)
        end = try c.decode(String.self, forKey: .end)
        datesText = try c.decodeIfPresent(String.self, forKey: .datesText) ?? ""
        venue = try c.decodeIfPresent(String.self, forKey: .venue) ?? ""
        city = try c.decode(String.self, forKey: .city)
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? ""
        sourceSite = try c.decodeIfPresent(String.self, forKey: .sourceSite) ?? ""
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL)
        imageVia = try c.decodeIfPresent(String.self, forKey: .imageVia) ?? "none"
        imageOn = try c.decodeIfPresent(String.self, forKey: .imageOn)
        // §44 item 5: an entry from an older file was never checked: nothing of it counts as confirmed.
        venueVia = try c.decodeIfPresent(String.self, forKey: .venueVia) ?? "none"
        datesVia = try c.decodeIfPresent(String.self, forKey: .datesVia) ?? "none"
        time = try c.decodeIfPresent(String.self, forKey: .time) ?? ""
        ticket = try c.decodeIfPresent([String].self, forKey: .ticket) ?? []
        checkedOn = try c.decodeIfPresent(String.self, forKey: .checkedOn)
        checkedAt = try c.decodeIfPresent(Date.self, forKey: .checkedAt)
        timeKind = try c.decodeIfPresent(String.self, forKey: .timeKind) ?? "start"
        venueURL = try c.decodeIfPresent(String.self, forKey: .venueURL) ?? ""
        timeURL = try c.decodeIfPresent(String.self, forKey: .timeURL) ?? ""
        readings = try c.decodeIfPresent([String].self, forKey: .readings) ?? []
    }

    /// §44 item 3: the venue (confirmed parts) and the dates, nil when not confirmed.
    public var confirmedVenue: String? { venueVia == "none" || venue.isEmpty ? nil : venue }
    public var confirmedDates: (start: String, end: String)? { datesVia == "none" ? nil : (start, end) }

    /// §44 item 3: 「场馆：<venue>」 or 「场馆：未找到」, 「日期：<start>–<end>」 or 「日期：未找到」 (always both), then
    /// 「开始：HH:MM」 and 「门票：…」 when kept (item 8, item 9).
    public var factsText: String {
        var parts = ["场馆：\(confirmedVenue ?? Self.notFound)",
                     "日期：" + (confirmedDates.map { "\($0.start)–\($0.end)" } ?? Self.notFound)]
        // F-18 §46 item 8: 「开放：HH:MM」 for daily opening hours.
        if !time.isEmpty { parts.append((timeKind == "opening" ? "开放：" : "开始：") + time) }
        if !ticket.isEmpty { parts.append("门票：" + ticket.joined(separator: "，")) }
        return parts.joined(separator: "；")
    }

    public static let notFound = "未找到"
    /// §44 item 3: asked for a picture with none.
    public static let noPictureAnswer = "未找到这个活动的图片"

    /// §44 item 3, on screen: the venue, or 「场馆未找到」 with the city.
    public var venueCardText: String { confirmedVenue ?? "场馆未找到 · \(city)" }
    public var datesCardText: String { confirmedDates.map { "\($0.start)～\($0.end)" } ?? "日期未找到" }
    /// §43 item 4c / §44 item 3: in the picture's place when there is none.
    public var imageCardText: String? { imageURL == nil ? "未找到图片" : nil }
    /// §44 item 4: only a confirmed venue is looked up on the map or offers navigation; never the event's name.
    public var mapQuery: String? { confirmedVenue.flatMap { EventSourceCheck.venueParts($0).first } }

    /// §43 item 4: 「网络图片」 under a picture from the image search.
    public static let searchImageLabel = "网络图片"
    public var imageLabel: String? { imageURL != nil && imageVia == "search" ? Self.searchImageLabel : nil }

    /// What `find_events` returns for it: §44 item 3's facts (never the model's unconfirmed venue or dates), the
    /// picture or 「未找到这个活动的图片」.
    public var json: JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name), "city": .string(city), "facts": .string(factsText), "source_url": .string(sourceURL),
        ]
        if let imageURL { o["image_url"] = .string(imageURL) } else { o["image"] = .string(Self.noPictureAnswer) }
        return .object(o)
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
        /// F-18 §46 items 6, 9: the source texts of earlier runs (kept 24 h).
        var sources: [EventPoolSource] = []

        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 2
            events = try c.decodeIfPresent([EventEntry].self, forKey: .events) ?? []
            windows = try c.decodeIfPresent([SearchedWindow].self, forKey: .windows) ?? []
            sources = try c.decodeIfPresent([EventPoolSource].self, forKey: .sources) ?? []
        }
    }

    /// F-18 §46 item 9: source texts are kept this long.
    public static let sourcesFor: TimeInterval = 24 * 3600

    /// §46 item 6: the saved source texts of `cities` from the last 24 h.
    public func sources(cities: [String]) -> [EventPoolSource] {
        let t = now()
        return file.sources.filter { t.timeIntervalSince($0.at) < Self.sourcesFor && !Set($0.cities).isDisjoint(with: cities) }
    }

    /// §46 item 9: adds a run's source texts (the same url replaced); older than 24 h dropped.
    public func recordSources(_ new: [EventPoolSource]) {
        let t = now()
        let urls = Set(new.map(\.url).filter { !$0.isEmpty })
        file.sources.removeAll { t.timeIntervalSince($0.at) >= Self.sourcesFor || urls.contains($0.url) }
        file.sources.append(contentsOf: new)
        save()
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

/// F-18 §46 item 6: one source of the merged pool (a search result, a page or a picture-search result).
public struct EventPoolSource: Sendable, Hashable, Codable {
    public let url: String
    public let title: String
    public let text: String
    public let cities: [String]
    public let at: Date
    public init(url: String, title: String, text: String, cities: [String], at: Date) {
        self.url = url
        self.title = title
        self.text = text
        self.cities = cities
        self.at = at
    }
}
