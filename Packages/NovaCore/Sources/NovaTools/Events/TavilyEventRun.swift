import Foundation
import NovaKit
import NovaPorts

/// What `EventFinder` runs: §39's Qwen path (`EventSearchRun`) or §46's Tavily path (`TavilyEventRun`).
public protocol EventSearching: Sendable {
    func run(_ r: EventRequest, known: [EventEntry]) async throws(EventSearchFailure) -> EventSearchOutcome
}

extension EventSearchRun: EventSearching {}

// MARK: F-18 §46 item 0: text comparison

/// §46 item 0: every comparison first converts traditional to simplified Chinese, then lower-cases.
public enum EventText {
    public static func norm(_ s: String) -> String {
        (s.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? s).lowercased()
    }

    /// `norm` with spaces and punctuation removed.
    public static func squash(_ s: String) -> String {
        String(norm(s).filter { !($0.isWhitespace || $0.isPunctuation || $0.isSymbol) })
    }

    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
    }

    static func isLatin(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// §46 item 5: the words removed from an event's name before its key names are taken.
    public static let removedWords = ["2026", "2027", "演唱会", "演唱會", "巡回", "巡迴", "澳门站", "澳門站", "澳门", "澳門", "珠海",
                                      "横琴", "橫琴", "中国", "中國", "国际", "國際", "全球", "第十六届", "荣誉呈献", "荣誉", "呈献",
                                      "独家呈现", "秋季"]
    /// §46 item 5: removed as whole Latin words.
    public static let removedLatin: Set<String> = ["fancon", "in", "macau", "macao", "x"]

    /// §46 item 5: every Latin word of 3+ letters and every Han run of 2+ characters of the name, after the removals.
    public static func keys(_ name: String) -> [String] {
        var s = norm(name)
        for w in removedWords.map(norm) { s = s.replacingOccurrences(of: w, with: "") }
        var out: [String] = []
        var run = "", latin = ""
        func flush() {
            if run.count >= 2, !out.contains(run) { out.append(run) }
            if latin.count >= 3, !removedLatin.contains(latin), !out.contains(latin) { out.append(latin) }
            run = ""
            latin = ""
        }
        for c in s {
            if isHan(c) {
                if !latin.isEmpty { let r = run; flush(); run = r }
                run.append(c)
            } else if isLatin(c) {
                if !run.isEmpty { let l = latin; flush(); latin = l }
                latin.append(c)
            } else {
                flush()
            }
        }
        flush()
        return out
    }

    /// §46 item 5: `text` (squashed) names the event: a Latin key, a Han key of ≤ 6 characters, or any 4 characters
    /// in a row of a longer Han key.
    public static func names(_ text: String, keys: [String]) -> Bool {
        let t = squash(text)
        return keys.contains { k in
            if k.first.map(isLatin) == true || k.count <= 6 { return t.contains(k) }
            let a = Array(k)
            return (0...(a.count - 4)).contains { t.contains(String(a[$0..<($0 + 4)])) }
        }
    }

    /// §46 item 6: the text a key is looked for in an excerpt (Han keys over 6 characters by their first 4).
    static func mention(_ k: String) -> String {
        k.first.map(isLatin) == true || k.count <= 6 ? k : String(k.prefix(4))
    }
}

// MARK: F-18 §46 item 0: the date rows

public enum EventDates {
    static let english = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
                          "november", "december"]

    /// §46 item 0 row 4: the forms a day is written in (spaces removed).
    static func forms(_ d: EventDay) -> [String] {
        let m = d.month, day = d.day, y = d.year
        let mm = m < 10 ? "0\(m)" : "\(m)", dd = day < 10 ? "0\(day)" : "\(day)"
        var f = ["\(m)月\(day)日", "\(m)月\(day)号", "\(m)月\(day)號", "\(m).\(day)", "\(mm).\(dd)", "\(m)/\(day)", "\(mm)-\(dd)",
                 "\(y).\(mm).\(dd)", "\(y)-\(mm)-\(dd)", "\(y)年\(m)月\(day)日"]
        f.append("\(english[m - 1]) \(day)")
        f.append("\(day) \(english[m - 1])")
        return f
    }

    /// Every match of `form` in `t` not inside a longer number (a digit just before or after does not count).
    static func matches(_ form: String, in t: [Character]) -> [Range<Int>] {
        let f = Array(form)
        guard !f.isEmpty, t.count >= f.count else { return [] }
        var out: [Range<Int>] = []
        for i in 0...(t.count - f.count) where Array(t[i..<(i + f.count)]) == f {
            let before = i > 0 ? t[i - 1] : " ", after = i + f.count < t.count ? t[i + f.count] : " "
            // Only ASCII digits and letters join a match to its neighbours (a Han character is a letter too).
            func digit(_ c: Character) -> Bool { c.isASCII && c.isNumber }
            func latin(_ c: Character) -> Bool { c.isASCII && c.isLetter }
            if digit(f.first!), digit(before) { continue }
            if digit(f.last!), digit(after) { continue }
            if latin(f.first!), latin(before) { continue }
            if latin(f.last!), latin(after) { continue }
            out.append(i..<(i + f.count))
        }
        return out
    }

    /// §46 item 0 row 4 **(not tested)**: a year written within 20 characters before the match must be `year`.
    static func yearFits(_ t: [Character], before i: Int, year: Int) -> Bool {
        let a = max(0, i - 20)
        let window = String(t[a..<i])
        guard let re = try? NSRegularExpression(pattern: #"(?<!\d)(20\d\d)(?!\d)"#),
              let m = re.matches(in: window, range: NSRange(window.startIndex..., in: window)).last,
              let r = Range(m.range(at: 1), in: window) else { return true }
        return Int(window[r]) == year
    }

    /// §46 item 0 row 4: the start day (and, when `end` ≠ `start`, the end day) written in `excerpt`.
    public static func confirmed(start: EventDay, end: EventDay, in excerpt: String) -> Bool {
        // Spaces collapsed: every run of white space becomes one space, and none is kept next to a Han character.
        var t: [Character] = []
        for c in EventText.norm(excerpt) {
            if c.isWhitespace {
                if let last = t.last, last != " ", !EventText.isHan(last) { t.append(" ") }
            } else {
                if t.last == " ", EventText.isHan(c) || t.count < 2 || EventText.isHan(t[t.count - 2]) { t.removeLast() }
                t.append(c)
            }
        }
        let starts = forms(start).flatMap { matches($0, in: t) }.filter { yearFits(t, before: $0.lowerBound, year: start.year) }
        guard !starts.isEmpty else { return false }
        if end == start { return true }
        if !forms(end).flatMap({ matches($0, in: t) }).isEmpty { return true }
        let signs = Set("-–—~～至到")
        let endDay = "\(end.day)"
        for s in starts {
            let tail = Array(t[s.upperBound..<min(t.count, s.upperBound + 20)])
            guard let k = tail.firstIndex(where: { signs.contains($0) }) else { continue }
            let rest = Array(tail[(k + 1)...]).drop { !$0.isNumber }
            let digits = String(rest.prefix { $0.isNumber })
            if digits == endDay || digits == (end.day < 10 ? "0\(end.day)" : endDay) { return true }
        }
        return false
    }
}

// MARK: F-18 §46 item 5: poster

/// §46 item 5: what one picture call read.
public struct PosterReading: Sendable, Hashable {
    public let text: String
    public let dates: [String]
    public let times: [String]
    public let venue: String
    public let raw: String

    public static func parse(_ content: String) -> PosterReading? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(EventSearchRun.jsonText(content).utf8)) else { return nil }
        func list(_ k: String) -> [String] {
            guard case .array(let a)? = v[k] else { return [] }
            return a.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespaces) }
        }
        return PosterReading(text: v["text"]?.stringValue ?? "", dates: list("dates"), times: list("times"),
                             venue: (v["venue"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                             raw: content)
    }

    /// §46 item 5: a key name in the printed text and one printed month-day within `start`…`end`.
    public func matches(keys: [String], start: EventDay, end: EventDay) -> Bool {
        EventText.names(text, keys: keys) && dates.contains { d in Self.day(d, start: start, end: end) }
    }

    /// `MM-DD` (or `M-D`, `YYYY-MM-DD`) inside `start`…`end` (the year taken from the window).
    static func day(_ text: String, start: EventDay, end: EventDay) -> Bool {
        let p = text.split(whereSeparator: { "-/.".contains($0) }).compactMap { Int($0) }
        guard p.count >= 2 else { return false }
        let (m, d) = p.count >= 3 ? (p[p.count - 2], p[p.count - 1]) : (p[0], p[1])
        for y in Set([start.year, end.year]) {
            if let day = EventDay(String(format: "%04d-%02d-%02d", y, m, d)), day >= start, day <= end { return true }
        }
        return false
    }
}

/// §46 item 5: the picture prompt, exactly.
public enum EventPoster {
    public static let prompt = #"Read this picture. Answer in JSON only: {"text": "all text printed on it, converted to simplified Chinese", "dates": ["MM-DD for each date printed on it"], "times": ["HH:MM for each time of day printed on it"], "venue": "venue printed on it, else empty"}. Only what is printed on the picture; empty when nothing is."#
    public static let pageImages = 8
    public static let searchImages = 6
    public static let minBytes = 5 * 1024
    public static let maxBytes = 4 * 1024 * 1024

    /// §46 item 5: JPEG, PNG, GIF or WebP by its first bytes, 5 KB–4 MB; the `data:` URL, else nil.
    public static func dataURL(_ data: Data) -> String? {
        guard (minBytes...maxBytes).contains(data.count) else { return nil }
        let b = [UInt8](data.prefix(12))
        let mime: String
        if b.starts(with: [0xFF, 0xD8, 0xFF]) {
            mime = "image/jpeg"
        } else if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            mime = "image/png"
        } else if b.starts(with: Array("GIF8".utf8)) {
            mime = "image/gif"
        } else if b.count >= 12, b.starts(with: Array("RIFF".utf8)), Array(b[8..<12]) == Array("WEBP".utf8) {
            mime = "image/webp"
        } else {
            return nil
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }
}

// MARK: F-18 §46 item 6: venue and hour from the merged pool

public enum EventFacts {
    public static let before = 700, after = 700, perSource = 3, maxChars = 16_000

    /// One source's excerpts (each mention's window, overlaps joined).
    public struct Excerpt: Sendable, Hashable {
        public let source: Int
        public let windows: [String]
        public var text: String { windows.joined(separator: " … ") }
    }

    /// §46 item 6: in each source (pool order, numbered from 1), every mention of a key gives 700 characters before and
    /// after, at most 3 mentions per source, overlaps joined; stops once the excerpts pass 16,000 characters.
    public static func excerpts(_ pool: [EventPoolSource], keys: [String]) -> [Excerpt] {
        let mentions = keys.map(EventText.mention).filter { !$0.isEmpty }
        var out: [Excerpt] = []
        var total = 0
        for (i, s) in pool.enumerated() {
            guard total <= maxChars else { break }
            let original = Array(s.title + "\n" + s.text)
            let t = Array(EventText.norm(s.title + "\n" + s.text))
            // The windows are cut from the source's own text (the model reads it as written); positions found on the
            // normalised text, which keeps one character per character.
            let cut = original.count == t.count ? original : t
            var hits: [Int] = []
            for m in mentions {
                let f = Array(m)
                guard t.count >= f.count else { continue }
                var j = 0
                while j <= t.count - f.count {
                    if Array(t[j..<(j + f.count)]) == f { hits.append(j); j += f.count } else { j += 1 }
                }
            }
            let first = Array(Set(hits).sorted().prefix(perSource))
            guard !first.isEmpty else { continue }
            var ranges: [Range<Int>] = []
            for h in first {
                let r = max(0, h - before)..<min(t.count, h + after)
                if let last = ranges.last, last.upperBound >= r.lowerBound {
                    ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
                } else {
                    ranges.append(r)
                }
            }
            let windows = ranges.map { String(cut[$0]) }
            total += windows.reduce(0) { $0 + $1.count }
            out.append(Excerpt(source: i + 1, windows: windows))
        }
        return out
    }

    /// §46 item 6: the venue/hour prompt, exactly.
    public static func prompt(name: String, start: String, end: String, excerpts: [Excerpt]) -> String {
        "Event: \(name) (\(start) to \(end)).\nBelow are excerpts from several web sources, each marked [S<number>]. Using only them, give this event's venue and its start time of day. For an exhibition or fair with daily opening hours, give the opening time and set time_kind to \"opening\"; for a show or race, the start time and time_kind \"start\". Each answer needs the exact text of the source that states it for THIS event, copied word for word, and that source's number. Empty when no source states it for this event. Answer in JSON only: {\"venue\": \"\", \"venue_quote\": \"\", \"venue_source\": 0, \"start_time\": \"HH:MM\", \"time_kind\": \"start\", \"time_quote\": \"\", \"time_source\": 0}\n\n"
            + excerpts.map { "[S\($0.source)] \($0.text)" }.joined(separator: "\n\n")
    }

    public struct Answer: Sendable, Hashable {
        public var venue = "", venueQuote = "", startTime = "", timeKind = "start", timeQuote = ""
        public var venueSource = 0, timeSource = 0
        public init() {}

        public static func parse(_ content: String) -> Answer? {
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(EventSearchRun.jsonText(content).utf8)),
                  case .object = v else { return nil }
            func s(_ k: String) -> String { (v[k]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            func n(_ k: String) -> Int {
                if let i = v[k]?.intValue { return Int(i) }
                return Int(s(k).trimmingCharacters(in: CharacterSet(charactersIn: "Ss[] "))) ?? 0
            }
            var a = Answer()
            a.venue = s("venue")
            a.venueQuote = s("venue_quote")
            a.venueSource = n("venue_source")
            a.startTime = s("start_time")
            a.timeKind = s("time_kind") == "opening" ? "opening" : "start"
            a.timeQuote = s("time_quote")
            a.timeSource = n("time_source")
            return a
        }
    }

    static func excerpt(_ n: Int, in excerpts: [Excerpt]) -> String? { excerpts.first { $0.source == n }?.text }

    /// The quote, spaces and punctuation removed, inside that source's excerpt.
    static func quoted(_ quote: String, source: Int, in excerpts: [Excerpt]) -> Bool {
        let q = EventText.squash(quote)
        guard !q.isEmpty, let e = excerpt(source, in: excerpts) else { return false }
        return EventText.squash(e).contains(q)
    }

    /// §46 item 6 / item 0 row 5: the venue is sure.
    public static func venueSure(_ a: Answer, excerpts: [Excerpt]) -> Bool {
        let v = EventText.squash(a.venue), q = EventText.squash(a.venueQuote)
        guard !v.isEmpty, quoted(a.venueQuote, source: a.venueSource, in: excerpts) else { return false }
        return q.contains(String(v.prefix(4))) || v.contains(q)
    }

    /// Item 0 row 6: `HH:MM`, HH 00–23, MM 00–59.
    public static func clock(_ s: String) -> (h: Int, m: Int)? {
        let p = s.split(separator: ":", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count == 2, p[1].count == 2, let h = Int(p[0]), let m = Int(p[1]),
              (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// §46 item 6 / item 0 row 6: the hour is sure.
    public static func hourSure(_ a: Answer, excerpts: [Excerpt]) -> Bool {
        guard let (h, m) = clock(a.startTime), quoted(a.timeQuote, source: a.timeSource, in: excerpts) else { return false }
        let q = Array(EventText.norm(a.timeQuote).replacingOccurrences(of: "：", with: ":"))
        let mm = m < 10 ? "0\(m)" : "\(m)"
        for form in ["\(h):\(mm)", (h < 10 ? "0\(h)" : "\(h)") + ":\(mm)"] where !EventDates.matches(form, in: q).isEmpty {
            return true
        }
        let h12 = h >= 13 ? h - 12 : h
        guard !EventDates.matches("\(h12)", in: q).isEmpty else { return false }
        let qs = String(q)
        return ["晚", "下午", "pm", "點", "点", "時", "时"].contains { qs.contains($0) }
    }
}

// MARK: F-18 §46 items 2-10: the run

/// F-18 §46 (T-046zi, owner order 2026-11-26): three Tavily searches, one extraction on §40's text chain, Tavily
/// Extract of the kept events' pages, one poster per event read one picture per call, venue and hour quoted from the
/// merged pool; code decides every row of item 0, and an event that fails a required row is dropped whole.
public struct TavilyEventRun: EventSearching {
    /// Item 3: the system text, exactly (no cities line).
    public static let shape = #"{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "start_time": "HH:MM or empty", "venue": "", "city": "", "ticket": "", "source_url": ""}]}"#
    public static func system(_ r: EventRequest) -> String {
        "Extract the event information. Answer in JSON.\n\(shape)\ntoday: \(r.today)\nfrom: \(r.from)\nto: \(r.to)"
    }
    public static let extractLimit = NovaDuration.seconds(60)
    /// Item 5: up to 4 events at once.
    public static let parallel = 4

    /// Item 2: the call's cities with 「横琴」 after 珠海.
    static func withHengqin(_ cities: [String]) -> [String] {
        cities.flatMap { $0 == "珠海" ? ["珠海", "横琴"] : [$0] }
    }

    /// Item 2: the three queries (q1 all cities; q2 澳门/香港; q3 the others; an empty group uses all cities). With
    /// `name` the first query becomes 「<name> <cities> <months>」; with `kinds`, §42 item 4's rule on these queries.
    public static func queries(_ r: EventRequest) -> [EventQuery] {
        let when = EventSearchRun.when(r)
        let all = withHengqin(r.cities)
        let sar = r.cities.filter { ["澳门", "香港"].contains($0) }, other = r.cities.filter { !["澳门", "香港"].contains($0) }
        let g2 = sar.isEmpty ? all : withHengqin(sar), g3 = other.isEmpty ? all : withHengqin(other)
        func q(_ cities: [String], _ kinds: String, covers: [String]) -> EventQuery {
            EventQuery(text: (cities + [when, kinds]).joined(separator: " "), city: r.cities.first ?? "", kind: covers.first,
                       cities: r.cities, covers: covers)
        }
        var out: [EventQuery]
        let given = r.kinds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : r.kindList
        if given.isEmpty {
            out = [q(all, "展览展会 AI 科技展 航展", covers: ["展览展会", "AI 科技展"]),
                   q(g2, "演唱会 演出时间表 FANCON", covers: ["演唱会 演出"]),
                   q(g3, "演唱会 嘉年华 电音节 马拉松", covers: ["演唱会 演出", "漫展 ACG", "节庆活动"])]
        } else {
            let slots = r.name.isEmpty ? 3 : 2
            var groups = given.prefix(slots).map { [$0] }
            for (i, k) in given.dropFirst(slots).enumerated() { groups[i % groups.count].append(k) }
            out = groups.map { q(all, $0.joined(separator: " "), covers: $0) }
        }
        if !r.name.isEmpty {
            let named = EventQuery(text: ([r.name] + all + [when]).joined(separator: " "), city: r.cities.first ?? "",
                                   kind: nil, cities: r.cities, covers: [])
            out = [named] + out.dropFirst(given.isEmpty ? 1 : 0)
        }
        return Array(out.prefix(3))
    }

    static func sameURL(_ a: String, _ b: String) -> Bool {
        func f(_ s: String) -> String {
            var t = s.lowercased()
            for p in ["https://", "http://", "www."] where t.hasPrefix(p) { t.removeFirst(p.count) }
            while t.hasSuffix("/") { t.removeLast() }
            return t
        }
        return f(a) == f(b)
    }

    /// Item 3: the results in query order, deduplicated by url, one per line.
    public static func user(_ results: [EventWebResults]) -> (text: String, numbered: [EventSearchHit]) {
        var seen = Set<String>()
        let hits = results.flatMap(\.hits).filter { !$0.url.isEmpty && seen.insert($0.url).inserted }
        let text = hits.enumerated().map { i, h in
            "[\(i + 1)] \(h.date) \(h.title) — \(String(h.snippet.prefix(EventSearchRun.snippetChars))) (\(h.url))"
        }.joined(separator: "\n")
        return (text, hits)
    }

    /// Item 0: the drop reasons, in the table's order.
    public enum Drop: String, Sendable, Hashable {
        case noSource = "no_source", city
        case noDate = "no_date", endBeforeStart = "end_before_start", outsideWindow = "outside_window", past, duplicate
        case datesNotSure = "dates_not_sure", venueNotSure = "venue_not_sure", timeNotSure = "time_not_sure"
        /// Counted in 「另有N个活动时间或地点未确认」 (item 7).
        public var unsure: Bool { self == .datesNotSure || self == .venueNotSure || self == .timeNotSure }
    }

    /// Item 0 rows 1-3 on one extracted event: its source result, city and dates, or the first failing row.
    struct Pre: Sendable {
        let candidate: EventCandidate
        let source: EventSearchHit
        let city: String
        let start: EventDay
        let end: EventDay
        let keys: [String]
    }

    static func city(_ text: String, in cities: [String]) -> String? {
        if cities.contains("珠海"), EventText.norm(text).contains("横琴") { return "珠海" }
        return EventSearchRun.city(text, in: cities)
    }

    public static func precheck(_ candidates: [EventCandidate], numbered: [EventSearchHit], request r: EventRequest)
        -> (kept: [EventCandidate], drops: [(name: String, reason: Drop)]) {
        let (kept, drops) = pre(candidates, numbered: numbered, request: r)
        return (kept.map(\.candidate), drops)
    }

    static func pre(_ candidates: [EventCandidate], numbered: [EventSearchHit], request r: EventRequest)
        -> ([Pre], [(name: String, reason: Drop)]) {
        var kept: [Pre] = []
        var drops: [(name: String, reason: Drop)] = []
        var seen = Set<String>()
        for c in candidates {
            let keys = EventText.keys(c.name)
            // Row 1: the source is a result (a number is that result), else the first result naming the event; the
            // name's key in that result's title + content.
            var url = c.sourceURL
            if let n = Int(url.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))), n >= 1, n <= numbered.count {
                url = numbered[n - 1].url
            }
            let variants = EventSearchRun.nameVariants(c.name)
            let source = numbered.first { $0.url == url }
                ?? numbered.first { h in variants.contains { h.title.contains($0) || h.snippet.contains($0) } }
                ?? numbered.first { EventText.names($0.title + " " + $0.snippet, keys: keys) }
            guard let source, !keys.isEmpty, EventText.names(source.title + " " + source.snippet, keys: keys) else {
                drops.append((c.name, .noSource)); continue
            }
            guard let city = city(c.city, in: r.cities) else { drops.append((c.name, .city)); continue }
            guard let start = EventDay(c.start), let end = EventDay(c.end) else { drops.append((c.name, .noDate)); continue }
            guard start <= end else { drops.append((c.name, .endBeforeStart)); continue }
            guard start <= r.to, end >= r.from else { drops.append((c.name, .outsideWindow)); continue }
            guard end >= r.today else { drops.append((c.name, .past)); continue }
            guard seen.insert(c.name + "|" + c.start).inserted else { drops.append((c.name, .duplicate)); continue }
            kept.append(Pre(candidate: c, source: source, city: city, start: start, end: end, keys: keys))
        }
        return (kept, drops)
    }

    /// Items 5-6 decided by code for one event: rows 4-7 of item 0, given the readings and the facts answer.
    public struct Verdict: Sendable, Hashable {
        public var entry: EventEntry?
        public var drop: Drop?
        public var line: String
    }

    /// Rows 4-6 (dates confirmed, venue, hour) and row 7 (poster), in item 0's order.
    public static func decide(_ e: EventEntry, keys: [String], start: EventDay, end: EventDay, excerpts: [EventFacts.Excerpt],
                              pool: [EventPoolSource], answer: EventFacts.Answer?, poster: PosterReading?,
                              posterURL: String?, posterVia: String, pictures: Int) -> Verdict {
        var e = e
        let datesOK = excerpts.contains { x in x.windows.contains { EventDates.confirmed(start: start, end: end, in: $0) } }
        var venueVia = "none", timeVia = "none"
        if let a = answer, EventFacts.venueSure(a, excerpts: excerpts) {
            venueVia = "S\(a.venueSource)"
            e.venue = a.venue
            e.venueURL = pool.indices.contains(a.venueSource - 1) ? pool[a.venueSource - 1].url : ""
        } else if let p = poster, !p.venue.isEmpty {
            venueVia = "poster"
            e.venue = p.venue
            e.venueURL = posterURL ?? ""
        }
        if let a = answer, EventFacts.hourSure(a, excerpts: excerpts) {
            timeVia = "S\(a.timeSource)"
            e.time = a.startTime
            e.timeKind = a.timeKind
            e.timeURL = pool.indices.contains(a.timeSource - 1) ? pool[a.timeSource - 1].url : ""
        } else if let t = poster?.times.first, EventFacts.clock(t) != nil {
            timeVia = "poster"
            e.time = t
            e.timeKind = answer?.timeKind ?? "start"
            e.timeURL = posterURL ?? ""
        }
        let drop: Drop? = !datesOK ? .datesNotSure : venueVia == "none" ? .venueNotSure : timeVia == "none" ? .timeNotSure : nil
        let line = "events verify name=\(e.name) venue=\(venueVia) time=\(timeVia) kind=\(e.timeKind) "
            + "poster=\(posterURL == nil ? "none" : posterVia) pictures=\(pictures) kept=\(drop == nil ? "yes" : "no")"
        guard drop == nil else { return Verdict(entry: nil, drop: drop, line: line) }
        e.venueVia = venueVia
        e.datesVia = "source"
        e.imageURL = posterURL
        e.imageVia = posterURL == nil ? "none" : posterVia
        return Verdict(entry: e, drop: nil, line: line)
    }

    private let web: any EventWebSource
    private let extractor: any EventExtractor
    private let reader: any EventReader
    private let clock: any NovaClock
    private let sources: @Sendable (_ cities: [String]) async -> [EventPoolSource]
    private let saveSources: @Sendable ([EventPoolSource]) async -> Void
    private let now: @Sendable () -> Date
    private let onProgress: @Sendable (Int, Int) -> Void
    private let onLine: @Sendable (String) -> Void

    /// `sources`/`saveSources`: the store's source texts of the last 24 h (item 6, item 9).
    public init(web: any EventWebSource, extractor: any EventExtractor, reader: any EventReader, clock: any NovaClock,
                sources: @escaping @Sendable ([String]) async -> [EventPoolSource] = { _ in [] },
                saveSources: @escaping @Sendable ([EventPoolSource]) async -> Void = { _ in },
                now: @escaping @Sendable () -> Date = { Date() },
                onProgress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.web = web
        self.extractor = extractor
        self.reader = reader
        self.clock = clock
        self.sources = sources
        self.saveSources = saveSources
        self.now = now
        self.onProgress = onProgress
        self.onLine = onLine
    }

    public func run(_ r: EventRequest, known: [EventEntry] = []) async throws(EventSearchFailure) -> EventSearchOutcome {
        let queries = Self.queries(r)
        let started = clock.now
        let m = queries.count
        // Item 2: all three at once.
        var results: [Int: EventWebResults] = [:]
        await withTaskGroup(of: (Int, EventWebResults?, Int64).self) { [web, clock] group in
            for (i, q) in queries.enumerated() {
                group.addTask {
                    let t0 = clock.now
                    let a = try? await web.search(q.text, images: false)
                    return (i, a, (clock.now - t0).milliseconds)
                }
            }
            var done = 0
            for await (i, a, ms) in group {
                if let a { results[i] = a }
                done += 1
                onLine("events search provider=tavily q=\(i + 1) ms=\(ms) results=\(a?.hits.count ?? 0) attempt=\(a?.attempts ?? 0)")
                onProgress(done, m + 1)
            }
        }
        guard !results.isEmpty else { throw .allQueriesFailed }
        let used = results.keys.sorted().map { results[$0]! }
        // Item 3: one extraction.
        let (user, numbered) = Self.user(used)
        let t0 = clock.now
        var reply: EventModelReply?
        do {
            reply = try await extractor.extract(system: Self.system(r), user: user, timeout: Self.extractLimit)
        } catch let EventExtractError.http(status, body) {
            onLine("events extract failed status=\(status) body=\(String(body.prefix(300)))")
        } catch {}
        onLine("events extract model=\(reply?.model ?? "") ms=\((clock.now - t0).milliseconds) "
               + "tokens=\(reply?.promptTokens ?? 0),\(reply?.completionTokens ?? 0)")
        guard let reply, let candidates = EventSearchRun.candidates(reply.content) else { throw .extract }
        var (pres, drops) = Self.pre(candidates, numbered: numbered, request: r)
        let at = now()
        let today = r.today.description

        // Items 4-6 run at most once per event per day: an event the store verified today is kept as stored.
        var kept: [EventEntry] = []
        var fresh: [Pre] = []
        for p in pres {
            if let k = known.first(where: { $0.city == p.city && $0.name == p.candidate.name && $0.start == p.candidate.start }),
               k.verified, k.checkedOn == today {
                kept.append(k)
            } else {
                fresh.append(p)
            }
        }
        pres = fresh

        // Item 4: one Extract call for the kept events' pages.
        var pages: [String: EventPage] = [:]
        let urls = Array(Set(pres.map(\.source.url))).sorted()
        if !urls.isEmpty, let got = try? await web.extract(urls) {
            for p in got { pages[p.url] = p }
            for p in got where !urls.contains(p.url) {
                // A redirected or re-spelled url: matched to the asked one by its form without a trailing slash.
                if let u = urls.first(where: { Self.sameURL($0, p.url) }), pages[u] == nil { pages[u] = p }
            }
        }

        // Item 5: the posters (4 events at once).
        struct Poster: Sendable { let reading: PosterReading?; let url: String?; let via: String; let pictures: Int
            let readings: [String]; let searchHits: [EventSearchHit] }
        var posters: [Int: Poster] = [:]
        await withTaskGroup(of: (Int, Poster).self) { group in
            var next = 0
            func add() {
                guard next < pres.count else { return }
                let i = next
                next += 1
                let p = pres[i], page = pages[p.source.url]
                group.addTask {
                    let x = await poster(p, page: page)
                    return (i, Poster(reading: x.reading, url: x.url, via: x.via, pictures: x.pictures, readings: x.readings,
                                      searchHits: x.searchHits))
                }
            }
            for _ in 0..<Self.parallel { add() }
            for await (i, p) in group {
                posters[i] = p
                add()
            }
        }

        // Item 6: the pool (searches, pages, picture searches, the store's last 24 h).
        var pool: [EventPoolSource] = []
        var poolURLs = Set<String>()
        func add(_ url: String, _ title: String, _ text: String) {
            guard !text.isEmpty || !title.isEmpty else { return }
            if !url.isEmpty, !poolURLs.insert(url + "|" + String(text.prefix(40))).inserted { return }
            pool.append(EventPoolSource(url: url, title: title, text: text, cities: r.cities, at: at))
        }
        for h in used.flatMap(\.hits) { add(h.url, h.title, h.snippet) }
        for pg in pages.values.sorted(by: { $0.url < $1.url }) { add(pg.url, pg.title, pg.rawContent) }
        for i in pres.indices { for h in posters[i]?.searchHits ?? [] { add(h.url, h.title, h.snippet) } }
        let saved = pool
        for s in await sources(r.cities) { add(s.url, s.title, s.text) }
        await saveSources(saved)

        // Item 6 call and item 0 rows 4-7, 4 events at once.
        var verdicts: [Int: Verdict] = [:]
        await withTaskGroup(of: (Int, Verdict).self) { [reader] group in
            var next = 0
            func add() {
                guard next < pres.count else { return }
                let i = next
                next += 1
                let p = pres[i], po = posters[i] ?? Poster(reading: nil, url: nil, via: "none", pictures: 0, readings: [], searchHits: [])
                let pool = pool
                group.addTask {
                    let excerpts = EventFacts.excerpts(pool, keys: p.keys)
                    var answer: EventFacts.Answer?
                    if !excerpts.isEmpty {
                        let prompt = EventFacts.prompt(name: p.candidate.name, start: p.candidate.start, end: p.candidate.end,
                                                       excerpts: excerpts)
                        answer = (try? await reader.text(prompt)).flatMap(EventFacts.Answer.parse)
                    }
                    var e = EventEntry(name: p.candidate.name, start: p.start.description, end: p.end.description,
                                       datesText: p.candidate.datesText, venue: "", city: p.city, sourceURL: p.source.url,
                                       sourceSite: EventSearchRun.site(p.source.url) ?? "", fetchedAt: at)
                    e.readings = po.readings
                    e.checkedOn = today
                    e.checkedAt = at
                    e.imageOn = today
                    return (i, Self.decide(e, keys: p.keys, start: p.start, end: p.end, excerpts: excerpts, pool: pool,
                                           answer: answer, poster: po.reading, posterURL: po.url, posterVia: po.via,
                                           pictures: po.pictures))
                }
            }
            for _ in 0..<Self.parallel { add() }
            for await (i, v) in group {
                verdicts[i] = v
                add()
            }
        }
        for i in pres.indices {
            guard let v = verdicts[i] else { continue }
            onLine(v.line)
            if let e = v.entry { kept.append(e) } else if let d = v.drop { drops.append((pres[i].candidate.name, d)) }
        }
        for d in drops { onLine("events drop name=\(d.name) reason=\(d.reason.rawValue)") }
        onProgress(m + 1, m + 1)
        kept.sort { ($0.start, $0.name) < ($1.start, $1.name) }
        // Only the kinds the queries that answered covered are marked searched (a named query covers none).
        var covered: [String] = []
        for i in results.keys.sorted() { for k in queries[i].covers where !covered.contains(k) { covered.append(k) } }
        var pairs: [SearchedPair] = []
        for city in r.cities {
            for kind in r.kindList where covered.contains(kind) {
                pairs.append(SearchedPair(city: city, kind: kind, kept: kept.filter { $0.city == city }.count))
            }
        }
        let sites = kept.map(\.sourceSite).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        onLine("events search done ms=\((clock.now - started).milliseconds) queries=\(m) failed=\(m - results.count) "
               + "kept=\(kept.count) dropped=\(drops.count) tokens=\(reply.tokens ?? 0)")
        var outcome = EventSearchOutcome(kept: kept, dropped: drops.count, sites: sites, queries: m, failed: m - results.count,
                                         cut: 0, tokens: reply.tokens ?? 0, searched: pairs)
        outcome.unsure = drops.filter(\.reason.unsure).count
        outcome.droppedNames = drops.map(\.name)
        return outcome
    }

    /// Item 5: the page's first 8 pictures, read one per call; none matching: one 「<name> 海报」 picture search and its
    /// first 6. The first picture whose printed text has a key name and a date in the event's window is the poster.
    private func poster(_ p: Pre, page: EventPage?) async -> (reading: PosterReading?, url: String?, via: String, pictures: Int,
                                                             readings: [String], searchHits: [EventSearchHit]) {
        var readings: [String] = []
        var count = 0
        func first(_ urls: [String]) async -> (PosterReading, String)? {
            for u in urls {
                guard let data = await web.download(u), let dataURL = EventPoster.dataURL(data) else { continue }
                count += 1
                guard let text = try? await reader.picture(dataURL, prompt: EventPoster.prompt) else { continue }
                readings.append(text)
                if let reading = PosterReading.parse(text), reading.matches(keys: p.keys, start: p.start, end: p.end) {
                    return (reading, u)
                }
            }
            return nil
        }
        if let (r, u) = await first(Array((page?.images ?? []).prefix(EventPoster.pageImages))) {
            return (r, u, "page", count, readings, [])
        }
        let search = try? await web.search("\(p.candidate.name) 海报", images: true)
        if let (r, u) = await first(Array((search?.images ?? []).prefix(EventPoster.searchImages))) {
            return (r, u, "search", count, readings, search?.hits ?? [])
        }
        return (nil, nil, "none", count, readings, search?.hits ?? [])
    }
}
