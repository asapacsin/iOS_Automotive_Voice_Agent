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
    /// F-18 §43 item 2 (T-046zf): the event the driver named (≤ 30 characters); empty: none.
    public let name: String
    public init(cities: [String], from: EventDay, to: EventDay, kinds: String, today: EventDay, name: String = "") {
        self.cities = cities
        self.from = from
        self.to = to
        self.kinds = kinds
        self.today = today
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// §39 item 1: the kinds searched (the driver's split on 、，, and spaces, at most 5; else the default five).
    public var kindList: [String] { EventSearchRun.kinds(kinds) }
}

/// §39 item 1: one keyword query. `kind` nil: the extra English query of 澳门 or 香港.
/// F-18 §42 item 4: a Qiniu query names every city of the call (`cities`) and covers several of the request's kinds
/// (`covers`, for the store's city × kind marks); `city`/`kind` are the first of each.
public struct EventQuery: Sendable, Hashable {
    public let text: String
    public let city: String
    public let kind: String?
    public let cities: [String]
    public let covers: [String]
    public init(text: String, city: String, kind: String?, cities: [String]? = nil, covers: [String]? = nil) {
        self.text = text
        self.city = city
        self.kind = kind
        self.cities = cities ?? [city]
        self.covers = covers ?? kind.map { [$0] } ?? []
    }
}

/// F-18 §42: which search path a run uses. `qwen`: §39 queries on the Aliyun search (§41); `qiniu`: three Qiniu queries,
/// the numbered results extracted (§42 item 4).
public enum EventSearchMode: String, Sendable, Hashable {
    case qwen, qiniu
}

/// One event the extraction named, before code's checks.
public struct EventCandidate: Sendable, Hashable {
    public let name, start, end, datesText, venue, city, sourceURL: String
    /// F-18 §44 item 8: `HH:MM`, empty when not stated.
    public let time: String
    public init(name: String, start: String, end: String, datesText: String, venue: String, city: String, sourceURL: String,
                time: String = "") {
        self.name = name
        self.start = start
        self.end = end
        self.datesText = datesText
        self.venue = venue
        self.city = city
        self.sourceURL = sourceURL
        self.time = time
    }
}

public struct EventSearchOutcome: Sendable, Hashable {
    public var kept: [EventEntry]
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
    /// F-18 §46 item 7: events dropped because their dates, venue or hour were not sure.
    public var unsure: Int = 0
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
    /// §42 item 4: at most 3 Qiniu queries, all at once; the extraction gets 60 s.
    public static let qiniuMaxQueries = 3
    public static let qiniuExtractLimit = NovaDuration.seconds(60)
    /// §42 item 4: the kind groups with no `kinds`, and the default kinds each covers (for the store's marks).
    public static let qiniuGroups: [(text: String, covers: [String])] = [
        ("展览展会 科技展", ["展览展会", "AI 科技展"]),
        ("演唱会 演出", ["演唱会 演出"]),
        ("漫展 节庆 嘉年华", ["漫展 ACG", "节庆活动"]),
    ]
    /// §42 item 4: a result's content in the extraction message, first this many characters.
    public static let snippetChars = 300
    /// Item 1: the default five kinds.
    public static let defaultKinds = ["展览展会", "漫展 ACG", "演唱会 演出", "AI 科技展", "节庆活动"]
    /// Item 1: the cities that get one extra English query, and their English names.
    static let english = ["澳门": "Macau", "香港": "Hong Kong"]
    static let months = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                         "October", "November", "December"]

    /// Item 3 (amended 2026-11-25): the system text (OpenAI "Structured Outputs" guide, copied; 「Answer in JSON.」 is
    /// what JSON mode requires: the word JSON in the messages) and the JSON shape, today and the window as values.
    public static let instruction = "Extract the event information. Answer in JSON."
    /// F-18 §44 item 8: the shape gains `"time": "HH:MM"` (empty when not stated).
    public static let shape = #"{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "time": "HH:MM", "dates_text": "", "venue": "", "city": "", "source_url": ""}]}"#

    /// F-18 §43 item 6 (Qiniu, amends §42 item 4): the call's cities as one more data line, like today/from/to.
    public static func system(_ r: EventRequest, qiniu: Bool = false) -> String {
        "\(instruction)\n\(shape)\ntoday: \(r.today)\nfrom: \(r.from)\nto: \(r.to)"
            + (qiniu ? "\ncities: \(r.cities.joined(separator: ", "))" : "")
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

    static func when(_ r: EventRequest) -> String {
        let ms = months(r)
        return "\(ms[0].0)年\(ms[0].1)月" + ms.dropFirst().map { " \($0.1)月" }.joined()
    }

    /// §42 item 4: 「<城市1> <城市2> … <YYYY>年<M>月[ <M>月…] <kind group>」, at most 3, no English query. With no `kinds` the
    /// three groups; with the driver's kinds one per query in order, kinds 4–5 appended to queries 1–2.
    /// F-18 §43 item 2: with `name` the first query is 「<name> <城市1> <城市2> … <YYYY>年<M>月[ <M>月…]」 and the kind queries
    /// follow, 3 queries in all (the kind groups' first two; the driver's kinds spread over two queries).
    public static func qiniuQueries(_ r: EventRequest) -> [EventQuery] {
        let head = (r.cities + [when(r)]).joined(separator: " ")
        let given = r.kinds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : r.kindList
        let named: [EventQuery] = r.name.isEmpty ? [] : [
            EventQuery(text: "\(r.name) \(head)", city: r.cities.first ?? "", kind: nil, cities: r.cities, covers: []),
        ]
        let slots = qiniuMaxQueries - named.count
        if given.isEmpty {
            return named + qiniuGroups.prefix(slots).map { g in
                EventQuery(text: "\(head) \(g.text)", city: r.cities.first ?? "", kind: g.covers.first,
                           cities: r.cities, covers: g.covers)
            }
        }
        var groups = given.prefix(slots).map { [$0] }
        for (i, k) in given.dropFirst(slots).enumerated() { groups[i % groups.count].append(k) }
        return named + groups.map { g in
            EventQuery(text: "\(head) \(g.joined(separator: " "))", city: r.cities.first ?? "", kind: g.first,
                       cities: r.cities, covers: g)
        }
    }

    /// §42 item 4: every result of the answers, deduplicated by url, in query order.
    public static func numbered(_ answers: [(EventQuery, EventSearchAnswer)]) -> [EventSearchHit] {
        var seen = Set<String>()
        return answers.flatMap(\.1.sources).filter { !$0.url.isEmpty && seen.insert($0.url).inserted }
    }

    /// §42 item 4: one line per result, `[n] <date> <title> — <content, first 300 characters> (<url>)`.
    public static func qiniuUser(_ answers: [(EventQuery, EventSearchAnswer)]) -> String {
        numbered(answers).enumerated().map { i, h in
            "[\(i + 1)] \(h.date) \(h.title) — \(String(h.snippet.prefix(snippetChars))) (\(h.url))"
        }.joined(separator: "\n")
    }

    /// Cities × kinds in that order, then the English ones; at most 12 (the rest are `cut`).
    public static func queries(_ r: EventRequest) -> (queries: [EventQuery], cut: Int) {
        let when = when(r)
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
    private let fillSearcher: any EventWebSearcher
    private let fillExtractor: any EventExtractor
    private let clock: any NovaClock
    private let now: @Sendable () -> Date
    /// Item 7: queries finished, of all.
    private let onProgress: @Sendable (_ done: Int, _ of: Int) -> Void
    /// Item 8: the record lines.
    private let onLine: @Sendable (String) -> Void
    private let mode: EventSearchMode
    /// F-18 §43 item 4: the event pages and the image search; nil: no pictures are looked for.
    private let pages: (any EventPageSource)?

    /// F-18 §45 item 1 (T-046zh): `fillSearcher`/`fillExtractor` serve §44 item 2's search for what is missing, which
    /// gets no Qwen fallback; nil: `searcher`/`extractor`.
    public init(searcher: any EventWebSearcher, extractor: any EventExtractor, clock: any NovaClock,
                mode: EventSearchMode = .qwen, pages: (any EventPageSource)? = nil,
                fillSearcher: (any EventWebSearcher)? = nil, fillExtractor: (any EventExtractor)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.searcher = searcher
        self.extractor = extractor
        self.fillSearcher = fillSearcher ?? searcher
        self.fillExtractor = fillExtractor ?? extractor
        self.clock = clock
        self.mode = mode
        self.pages = pages
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

    /// `known`: the store's events (a picture looked for today is not looked for again, §43 item 4).
    public func run(_ r: EventRequest, known: [EventEntry] = []) async throws(EventSearchFailure) -> EventSearchOutcome {
        let started = clock.now
        let qiniu = mode == .qiniu
        let (queries, cut) = qiniu ? (Self.qiniuQueries(r), 0) : Self.queries(r)
        if cut > 0 { onLine("events queries cut=\(cut)") }
        let m = queries.count
        let parallel = qiniu ? m : Self.parallel
        if qiniu { onLine("events provider=qiniu queries=\(m)") }
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
            for _ in 0..<max(1, parallel) { add() }
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
        let system = Self.system(r, qiniu: qiniu), user = qiniu ? Self.qiniuUser(used) : Self.user(used)
        let limit = qiniu ? Self.qiniuExtractLimit : Self.extractLimit
        var reply: EventModelReply?
        do {
            reply = try await within(limit) { [extractor] in
                try await extractor.extract(system: system, user: user, timeout: limit)
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
        let checked = Self.check(candidates, answers: used, request: r, at: now(), numbered: qiniu ? Self.numbered(used) : [])
        // F-18 §43 item 3: one line per dropped candidate, the first failed check as the reason.
        for d in checked.drops { onLine("events drop name=\(d.name) reason=\(d.reason.rawValue)") }
        finished(checked.kept.count, dropped: checked.dropped)
        var pairs: [SearchedPair] = []
        for (q, _) in used {
            if qiniu {
                // §42 item 4 with §39 item 5: each city × kind the query covered.
                for city in q.cities {
                    for kind in q.covers {
                        pairs.append(SearchedPair(city: city, kind: kind,
                                                  kept: checked.from.filter { $0.query == q && $0.entry.city == city }.count))
                    }
                }
                continue
            }
            guard let kind = q.kind else { continue }
            pairs.append(SearchedPair(city: q.city, kind: kind,
                                      kept: checked.from.filter { $0.query.city == q.city && $0.query.kind == kind }.count))
        }
        let sites = checked.kept.map(\.sourceSite).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let times = Dictionary(candidates.map { ($0.name + "|" + $0.start, $0.time) }, uniquingKeysWith: { a, _ in a })
        let kept = await confirm(checked.kept, request: r, known: known, sources: used.flatMap(\.1.sources), modelTimes: times)
        return EventSearchOutcome(kept: kept, dropped: checked.dropped, sites: sites, queries: m, failed: failed,
                                  cut: cut, tokens: tokens, searched: pairs)
    }

    // MARK: F-18 §44 items 1-2, 5-6 and §43 item 4: checks, one search for what is missing, pictures

    /// F-18 §44 item 2: at most this many events per call get the search for what is missing.
    public static let fillMax = 3
    /// §44 item 2: at most this many result pages fetched per event.
    public static let fillPages = 3

    /// Fetches each page once per run (one fetch serves the checks and the picture, §44 item 1).
    final class PageCache: @unchecked Sendable {
        private var pages: [String: String?] = [:]
        private let source: any EventPageSource
        init(_ source: any EventPageSource) { self.source = source }
        func page(_ url: String) async -> String? {
            if let cached = pages[url] { return cached }
            let html = await source.page(url)
            pages[url] = .some(html)
            return html
        }
    }

    /// Each kept event in order: an event the store checked today is kept as stored; else §44 item 1's checks against
    /// its source result and its page, §44 item 2's search for what is still missing (at most 3 events, Qiniu only), a
    /// confirmed value from the store kept when the new check found none, §43 item 4's picture, and the
    /// `events check` line. `modelTimes`: the extraction's `time` by `name|start`.
    func confirm(_ kept: [EventEntry], request r: EventRequest, known: [EventEntry], sources: [EventSearchHit],
                 modelTimes: [String: String]) async -> [EventEntry] {
        guard let pages else { return kept }
        let cache = PageCache(pages)
        let today = r.today.description
        var filled = 0
        var out: [EventEntry] = []
        for var e in kept {
            let k = known.first { $0.city == e.city && $0.name == e.name && $0.start == e.start }
            if let k, k.checkedOn == today {
                out.append(k)
                continue
            }
            let html = await cache.page(e.sourceURL)
            var texts: [EventSourceCheck.Text] = []
            if let hit = sources.first(where: { $0.url == e.sourceURL }) {
                texts.append(EventSourceCheck.result(title: hit.title, content: hit.snippet))
            }
            if let html { texts.append(EventSourceCheck.page(html)) }
            // Item 1a: the confirmed parts only.
            let parts = EventSourceCheck.venue(e.venue, in: texts, cities: r.cities)
            e.venue = parts.joined(separator: "；")
            e.venueVia = parts.isEmpty ? "none" : "page"
            // Items 1b, 7.
            if let s = EventDay(e.start), let en = EventDay(e.end), EventSourceCheck.dates(start: s, end: en, in: texts) {
                e.datesVia = "page"
            } else {
                e.datesVia = "none"
            }
            // Items 8, 9.
            e.time = modelTimes[e.name + "|" + e.start].flatMap { EventSourceCheck.time($0, in: texts) } ?? ""
            e.ticket = EventDay(e.start).map { EventSourceCheck.ticket(start: $0, in: texts, today: r.today) } ?? []
            // Item 2.
            if mode == .qiniu, e.venueVia == "none" || e.datesVia == "none", filled < Self.fillMax {
                filled += 1
                await fill(&e, request: r, cache: cache)
            }
            // Item 5: a confirmed value is never replaced, and never refilled from a model.
            if let k {
                if e.venueVia == "none", k.venueVia != "none" { e.venue = k.venue; e.venueVia = k.venueVia }
                if e.datesVia == "none", k.datesVia != "none" { e.start = k.start; e.end = k.end; e.datesVia = k.datesVia }
                if e.time.isEmpty { e.time = k.time }
                if e.ticket.isEmpty { e.ticket = k.ticket }
            }
            e.checkedOn = today
            e.checkedAt = now()
            // §43 item 4: the picture (looked for at most once per event per day).
            if let k, k.imageOn == today {
                e.imageURL = k.imageURL
                e.imageVia = k.imageVia
                e.imageOn = k.imageOn
            } else {
                e.imageOn = today
                if let html, let og = EventPicture.ogImage(html) {
                    e.imageURL = og
                    e.imageVia = "og"
                } else if let hits = try? await pages.images(EventPicture.query(e)), let url = EventPicture.pick(hits, for: e) {
                    e.imageURL = url
                    e.imageVia = "search"
                } else {
                    e.imageURL = nil
                    e.imageVia = "none"
                }
                onLine(EventPicture.line(e))
            }
            onLine(Self.checkLine(e))
            out.append(e)
        }
        return out
    }

    /// §44 item 6.
    public static func checkLine(_ e: EventEntry) -> String {
        "events check name=\(e.name) venue=\(e.venueVia) dates=\(e.datesVia) image=\(e.imageVia) "
            + "time=\(e.time.isEmpty ? "none" : "page") ticket=\(e.ticket.isEmpty ? "none" : e.ticket.joined(separator: ","))"
    }

    /// §44 item 2: one search 「<name> <YYYY> 时间 地点」, one extraction on its results (§42 item 4's text and shape); the
    /// extracted event whose name matches (§43 item 5's variants) gives venue and dates, checked (item 1) against each
    /// result that names the event, then that result's page (at most 3 pages), in result order, until confirmed.
    /// Only what is missing is filled.
    func fill(_ e: inout EventEntry, request r: EventRequest, cache: PageCache) async {
        let text = "\(e.name) \(EventDay(e.start)?.year ?? r.today.year) 时间 地点"
        let answer: EventSearchAnswer
        do {
            answer = try await within(Self.queryLimit) { [fillSearcher] in try await fillSearcher.search(text, timeout: Self.queryLimit) }
        } catch {
            onLine("events fill name=\(e.name) search=failed")
            return
        }
        let query = EventQuery(text: text, city: e.city, kind: nil, cities: r.cities, covers: [])
        let system = Self.system(r, qiniu: true), user = Self.qiniuUser([(query, answer)])
        let reply = try? await within(Self.qiniuExtractLimit) { [fillExtractor] in
            try await fillExtractor.extract(system: system, user: user, timeout: Self.qiniuExtractLimit)
        }
        let variants = Self.nameVariants(e.name)
        guard let candidates = reply.flatMap({ Self.candidates($0.content) }),
              // The same event, and the same year's (the PoC: 横琴马拉松's only venue was the 2025 race's start, 「未找到」 is right).
              let c = candidates.first(where: { c in
                  (variants.contains { c.name.contains($0) } || Self.nameVariants(c.name).contains { e.name.contains($0) })
                      && EventDay(c.start)?.year == EventDay(e.start)?.year
              }) else {
            onLine("events fill name=\(e.name) found=no")
            return
        }
        let start = EventDay(c.start), end = EventDay(c.end)
        var venue: [String] = []
        var pagesLeft = Self.fillPages
        func apply(_ texts: [EventSourceCheck.Text]) {
            if e.venueVia == "none" {
                for p in EventSourceCheck.venue(c.venue, in: texts, cities: r.cities) where !venue.contains(p) { venue.append(p) }
            }
            if e.datesVia == "none", let start, let end, start <= end, EventSourceCheck.dates(start: start, end: end, in: texts) {
                e.start = start.description
                e.end = end.description
                e.datesVia = "search"
            }
        }
        var done: Bool { (e.venueVia != "none" || !venue.isEmpty) && e.datesVia != "none" }
        for hit in Self.numbered([(query, answer)]) where variants.contains(where: { (hit.title + " " + hit.snippet).contains($0) }) {
            apply([EventSourceCheck.result(title: hit.title, content: hit.snippet)])
            if done { break }
            guard pagesLeft > 0 else { continue }
            pagesLeft -= 1
            if let html = await cache.page(hit.url) { apply([EventSourceCheck.page(html)]) }
            if done { break }
        }
        if e.venueVia == "none", !venue.isEmpty {
            e.venue = venue.joined(separator: "；")
            e.venueVia = "search"
        }
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
                                  datesText: s("dates_text"), venue: s("venue"), city: s("city"), sourceURL: s("source_url"),
                                  time: s("time").isEmpty ? s("start_time") : s("time"))
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
    /// §42 item 4: with `numbered` (the Qiniu results as numbered in the message), a `source_url` that names a result
    /// number (「3」 or 「[3]」) is that result's url.
    /// F-18 §43 item 3: why a candidate was dropped (§39 item 4's checks, in that order).
    public enum DropReason: String, Sendable, Hashable {
        case noDate = "no_date"
        case endBeforeStart = "end_before_start"
        case outsideWindow = "outside_window"
        case past
        case city
        case noSource = "no_source"
        case duplicate
    }

    /// F-18 §43 item 5: the event's name, its name without a leading 4-digit year, and the part in brackets
    /// (「AIE电子展」 of 「2026全球智能制造与电子产品博览会（AIE电子展）」), each at least 3 characters.
    public static func nameVariants(_ name: String) -> [String] {
        var out = [name]
        if name.count > 4, name.prefix(4).allSatisfy(\.isASCII), name.prefix(4).allSatisfy(\.isNumber) {
            out.append(String(name.dropFirst(4)).trimmingCharacters(in: .whitespaces))
        }
        for (open, close) in [("（", "）"), ("(", ")")] {
            if let a = name.range(of: open), let b = name.range(of: close, range: a.upperBound..<name.endIndex) {
                out.append(String(name[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces))
            }
        }
        var seen = Set<String>()
        return out.filter { $0.count >= 3 && seen.insert($0).inserted }
    }

    public static func check(_ candidates: [EventCandidate], answers: [(EventQuery, EventSearchAnswer)], request r: EventRequest,
                             at: Date, numbered: [EventSearchHit] = [])
        -> (kept: [EventEntry], dropped: Int, from: [(entry: EventEntry, query: EventQuery)], drops: [(name: String, reason: DropReason)]) {
        var kept: [(entry: EventEntry, query: EventQuery)] = []
        var drops: [(name: String, reason: DropReason)] = []
        var seen = Set<String>()
        for c in candidates {
            guard let start = EventDay(c.start), let end = EventDay(c.end) else { drops.append((c.name, .noDate)); continue }
            guard start <= end else { drops.append((c.name, .endBeforeStart)); continue }
            guard start <= r.to, end >= r.from else { drops.append((c.name, .outsideWindow)); continue }
            guard end >= r.today else { drops.append((c.name, .past)); continue }
            guard let city = city(c.city, in: r.cities) else { drops.append((c.name, .city)); continue }
            var url = c.sourceURL
            let digits = url.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            if let n = Int(digits), n >= 1, n <= numbered.count { url = numbered[n - 1].url }
            var query = answers.first { $0.1.sources.contains { $0.url == url } }?.0
            if query == nil, !numbered.isEmpty {
                // F-18 §43 item 5 (Qiniu): the first result whose title or content names the event.
                let variants = nameVariants(c.name)
                if let hit = numbered.first(where: { h in variants.contains { h.title.contains($0) || h.snippet.contains($0) } }) {
                    url = hit.url
                    query = answers.first { $0.1.sources.contains { $0.url == hit.url } }?.0
                }
            } else if query == nil, let naming = answers.first(where: { $0.1.text.contains(c.name) && !$0.1.sources.isEmpty }),
                      let first = naming.1.sources.first {
                url = first.url
                query = naming.0
            }
            guard let query, !url.isEmpty else { drops.append((c.name, .noSource)); continue }
            guard seen.insert(c.name + "|" + c.start).inserted else { drops.append((c.name, .duplicate)); continue }
            let entry = EventEntry(name: c.name, start: c.start, end: c.end, datesText: c.datesText, venue: c.venue,
                                   city: city, sourceURL: url, sourceSite: site(url) ?? "", fetchedAt: at)
            kept.append((entry, query))
        }
        let sorted = kept.sorted { ($0.entry.start, $0.entry.name) < ($1.entry.start, $1.entry.name) }
        return (sorted.map(\.entry), drops.count, sorted, drops)
    }

    public static func site(_ url: String) -> String? { URL(string: url)?.host }
}
