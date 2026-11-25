import Foundation
import NovaKit
import NovaPorts

/// F-18 §39 (T-046zb): what `find_events` (or the trip planner, F-15b §64) asks for.
public struct EventRequest: Sendable, Hashable {
    public let cities: [String]
    public let from: EventDay
    public let to: EventDay
    /// The driver's `kinds` text; empty: the default five (§39 item 1).
    public let kinds: String
    public let today: EventDay
    public init(cities: [String], from: EventDay, to: EventDay, kinds: String, today: EventDay) {
        self.cities = cities
        self.from = from
        self.to = to
        self.kinds = kinds
        self.today = today
    }

    /// §39 item 1: the kinds searched (the driver's split on 、，, and spaces, at most 5; else the default five).
    public var kindList: [String] { EventSearchRun.kinds(kinds) }
}

/// §39 item 1: one keyword query. `kind` nil: the extra English query of 澳门 or 香港.
public struct EventQuery: Sendable, Hashable {
    public let text: String
    public let city: String
    public let kind: String?
}

/// One event the extraction named, before code's checks.
public struct EventCandidate: Sendable, Hashable {
    public let name, start, end, datesText, venue, city, sourceURL: String
}

public struct EventSearchOutcome: Sendable, Hashable {
    public let kept: [EventEntry]
    /// §39 item 4: events the checks dropped.
    public let dropped: Int
    /// The sites of the kept events' sources.
    public let sites: [String]
    public let queries: Int
    public let failed: Int
    /// §39 item 1: queries past 12, dropped and counted.
    public let cut: Int
    public let tokens: Int
    /// §39 item 5: the kind queries that ran, with how many events each city × kind kept.
    public let searched: [SearchedPair]
}

public struct SearchedPair: Sendable, Hashable {
    public let city: String
    public let kind: String
    public let kept: Int
}

public enum EventSearchFailure: String, Error, Sendable, Hashable {
    /// §39 item 6: every query failed.
    case allQueriesFailed = "queries"
    /// The extraction call failed or its answer did not parse.
    case extract
}

/// F-18 §39 items 1-4, 8 (T-046zb, owner 2026-11-24; replaces §35's and §38's browse loop): city × kind keyword
/// queries on the search route with the search's own answer kept (at most 12, 4 at once, 45 s each), then one
/// extraction call; code checks each event's dates, window, city and source.
public struct EventSearchRun: Sendable {
    public static let maxQueries = 12
    public static let maxKinds = 5
    public static let parallel = 4
    public static let queryLimit = NovaDuration.seconds(45)
    public static let extractLimit = NovaDuration.seconds(30)
    /// Item 1: the default five kinds.
    public static let defaultKinds = ["展览展会", "漫展 ACG", "演唱会 演出", "AI 科技展", "节庆活动"]
    /// Item 1: the cities that get one extra English query, and their English names.
    static let english = ["澳门": "Macau", "香港": "Hong Kong"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]

    /// Item 3 (amended 2026-11-25): the system text (OpenAI "Structured Outputs" guide, copied; 「Answer in JSON.」 is
    /// what JSON mode requires: the word JSON in the messages) and the JSON shape, today and the window as values.
    public static let instruction = "Extract the event information. Answer in JSON."
    public static let shape = #"{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "dates_text": "", "venue": "", "city": "", "source_url": ""}]}"#

    public static func system(_ r: EventRequest) -> String {
        "\(instruction)\n\(shape)\ntoday: \(r.today)\nfrom: \(r.from)\nto: \(r.to)"
    }

    // MARK: Item 1, queries

    public static func kinds(_ text: String) -> [String] {
        let parts = text.split(whereSeparator: { "、，, ".contains($0) || $0.isWhitespace }).map(String.init).filter { !$0.isEmpty }
        var out: [String] = []
        for p in parts where !out.contains(p) { out.append(p) }
        return out.isEmpty ? defaultKinds : Array(out.prefix(maxKinds))
    }

    /// The months the window touches (at most 3), as (year, month).
    static func months(_ r: EventRequest) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var y = r.from.year, m = r.from.month
        while out.count < 3, (y, m) <= (r.to.year, r.to.month) {
            out.append((y, m))
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        return out
    }

    /// Cities × kinds in that order, then the English ones; at most 12 (the rest are `cut`).
    public static func queries(_ r: EventRequest) -> (queries: [EventQuery], cut: Int) {
        let ms = months(r)
        let when = "\(ms[0].0)年\(ms[0].1)月" + ms.dropFirst().map { " \($0.1)月" }.joined()
        var all: [EventQuery] = []
        for city in r.cities {
            for kind in r.kindList { all.append(EventQuery(text: "\(city) \(kind) \(when)", city: city, kind: kind)) }
        }
        for city in r.cities {
            if let en = english[city] {
                all.append(EventQuery(text: "\(en) events exhibition concert \(months[r.from.month - 1]) \(r.from.year)", city: city, kind: nil))
            }
        }
        return (Array(all.prefix(maxQueries)), max(0, all.count - maxQueries))
    }

    /// Item 3: each query's answer text followed by its numbered sources.
    public static func user(_ answers: [(EventQuery, EventSearchAnswer)]) -> String {
        answers.enumerated().map { i, qa in
            let sources = qa.1.sources.enumerated().map { "[\($0 + 1)] \($1.title) \($1.url)" }.joined(separator: "\n")
            return "## \(i + 1). \(qa.0.text)\n\(qa.1.text)\n\(sources)"
        }.joined(separator: "\n\n")
    }

    private let searcher: any EventWebSearcher
    private let extractor: any EventExtractor
    private let clock: any NovaClock
    private let now: @Sendable () -> Date
    /// Item 7: queries finished, of all.
    private let onProgress: @Sendable (_ done: Int, _ of: Int) -> Void
    /// Item 8: the record lines.
    private let onLine: @Sendable (String) -> Void

    public init(searcher: any EventWebSearcher, extractor: any EventExtractor, clock: any NovaClock,
                now: @escaping @Sendable () -> Date = { Date() },
                onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.searcher = searcher
        self.extractor = extractor
        self.clock = clock
        self.now = now
        self.onProgress = onProgress
        self.onLine = onLine
    }

    /// `body` within `limit`, else `EventLimitPassed`.
    private func within<T: Sendable>(_ limit: NovaDuration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let clock = clock
        return try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await clock.sleep(until: clock.now + limit)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let value = first else { throw EventLimitPassed() }
            return value
        }
    }

    struct EventLimitPassed: Error {}

    public func run(_ r: EventRequest) async throws(EventSearchFailure) -> EventSearchOutcome {
        let started = clock.now
        let (queries, cut) = Self.queries(r)
        if cut > 0 { onLine("events queries cut=\(cut)") }
        let m = queries.count
        var answers: [Int: EventSearchAnswer] = [:]
        // Item 2: at most 4 at once; a failed or timed-out query is skipped and counted.
        await withTaskGroup(of: (Int, EventSearchAnswer?, Int64).self) { group in
            var next = 0
            func add() {
                guard next < m else { return }
                let i = next
                next += 1
                let q = queries[i]
                group.addTask {
                    let t0 = clock.now
                    let a = try? await within(Self.queryLimit) { try await searcher.search(q.text, timeout: Self.queryLimit) }
                    return (i, a, (clock.now - t0).milliseconds)
                }
            }
            for _ in 0..<Self.parallel { add() }
            var finished = 0
            for await (i, a, ms) in group {
                if let a { answers[i] = a }
                finished += 1
                onLine("events query \(i + 1)/\(m) ms=\(ms) ok=\(a == nil ? "no" : "yes") "
                       + "sources=\(a?.sources.count ?? 0) searches=\(a?.searches ?? 0) tokens=\(a?.tokens ?? 0) q=\(queries[i].text)")
                onProgress(finished, m)
                add()
            }
        }
        let failed = m - answers.count
        var tokens = answers.values.reduce(0) { $0 + ($1.tokens ?? 0) }
        func finished(_ kept: Int, dropped: Int) {
            onLine("events search done ms=\((clock.now - started).milliseconds) queries=\(m) failed=\(failed) kept=\(kept) "
                   + "dropped=\(dropped) tokens=\(tokens)")
        }
        guard !answers.isEmpty else {
            finished(0, dropped: 0)
            throw .allQueriesFailed
        }
        let used = answers.keys.sorted().map { (queries[$0], answers[$0]!) }
        // Item 3: one extraction call.
        let t0 = clock.now
        let system = Self.system(r), user = Self.user(used)
        var reply: EventModelReply?
        do {
            reply = try await within(Self.extractLimit) { [extractor] in
                try await extractor.extract(system: system, user: user, timeout: Self.extractLimit)
            }
        } catch let EventExtractError.http(status, body) {
            // Item 3 (amended): a non-200 answer's error body, first 300 characters.
            onLine("events extract failed status=\(status) body=\(String(body.prefix(300)))")
        } catch {}
        tokens += reply?.tokens ?? 0
        let candidates = reply.flatMap { Self.candidates($0.content) }
        onLine("events extract ms=\((clock.now - t0).milliseconds) tokens=\(reply?.tokens ?? 0) found=\(candidates?.count ?? 0)")
        guard let candidates else {
            finished(0, dropped: 0)
            throw .extract
        }
        let checked = Self.check(candidates, answers: used, request: r, at: now())
        finished(checked.kept.count, dropped: checked.dropped)
        var pairs: [SearchedPair] = []
        for (q, _) in used {
            guard let kind = q.kind else { continue }
            pairs.append(SearchedPair(city: q.city, kind: kind,
                                      kept: checked.from.filter { $0.query.city == q.city && $0.query.kind == kind }.count))
        }
        let sites = checked.kept.map(\.sourceSite).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return EventSearchOutcome(kept: checked.kept, dropped: checked.dropped, sites: sites, queries: m, failed: failed,
                                  cut: cut, tokens: tokens, searched: pairs)
    }

    // MARK: Item 4, checks

    /// The JSON object in the model's text (a fenced block or bare).
    static func jsonText(_ text: String) -> String {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return text }
        return String(text[a...b])
    }

    public static func candidates(_ text: String) -> [EventCandidate]? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText(text).utf8)),
              case .array(let events)? = v["events"] else { return nil }
        return events.map { e in
            func s(_ k: String) -> String { e[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            return EventCandidate(name: s("name"), start: s("start"), end: s("end").isEmpty ? s("start") : s("end"),
                                  datesText: s("dates_text"), venue: s("venue"), city: s("city"), sourceURL: s("source_url"))
        }.filter { !$0.name.isEmpty }
    }

    /// The asked city an extracted `city` names (「珠海市」, 「Macau」 → 澳门); nil when it names none.
    static func city(_ text: String, in cities: [String]) -> String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let aliases = ["Macau": "澳门", "Macao": "澳门", "澳門": "澳门", "Hong Kong": "香港"]
        let named = aliases.first { t.localizedCaseInsensitiveContains($0.key) }?.value ?? t
        return cities.first { named.contains($0) || (named.count >= 2 && $0.contains(named)) }
    }

    /// Item 4: dates parse, `end` ≥ `start`, overlaps the window and `end` ≥ today; `city` one of the asked; the
    /// source one the searches returned (else the first source of the query whose answer names the event, else
    /// dropped); the same name and start once. `from` is each kept event with the query it came from.
    public static func check(_ candidates: [EventCandidate], answers: [(EventQuery, EventSearchAnswer)], request r: EventRequest,
                             at: Date) -> (kept: [EventEntry], dropped: Int, from: [(entry: EventEntry, query: EventQuery)]) {
        var kept: [(entry: EventEntry, query: EventQuery)] = []
        var dropped = 0
        var seen = Set<String>()
        for c in candidates {
            guard let start = EventDay(c.start), let end = EventDay(c.end), start <= end,
                  start <= r.to, end >= r.from, end >= r.today,
                  let city = city(c.city, in: r.cities) else {
                dropped += 1
                continue
            }
            var url = c.sourceURL
            var query = answers.first { $0.1.sources.contains { $0.url == url } }?.0
            if query == nil, let naming = answers.first(where: { $0.1.text.contains(c.name) && !$0.1.sources.isEmpty }),
               let first = naming.1.sources.first {
                url = first.url
                query = naming.0
            }
            guard let query, !url.isEmpty, seen.insert(c.name + "|" + c.start).inserted else {
                dropped += 1
                continue
            }
            let entry = EventEntry(name: c.name, start: c.start, end: c.end, datesText: c.datesText, venue: c.venue,
                                   city: city, sourceURL: url, sourceSite: site(url) ?? "", fetchedAt: at)
            kept.append((entry, query))
        }
        let sorted = kept.sorted { ($0.entry.start, $0.entry.name) < ($1.entry.start, $1.entry.name) }
        return (sorted.map(\.entry), dropped, sorted)
    }

    public static func site(_ url: String) -> String? { URL(string: url)?.host }
}
