import Foundation

/// F-18 §35 item 6 (T-046x): a calendar day as `YYYY-MM-DD` (string order is date order).
public struct EventDay: Sendable, Hashable, Comparable, CustomStringConvertible, Codable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (2000...2100).contains(year), (1...12).contains(month), (1...EventDay.days(year, month)).contains(day) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// `YYYY-MM-DD`; nil for anything else.
    public init?(_ text: String) {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The day of `date` in `zone`.
    public init(_ date: Date, zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        year = c.year ?? 2000
        month = c.month ?? 1
        day = c.day ?? 1
    }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public static func < (a: EventDay, b: EventDay) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }

    static func days(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// Days from `self` to `other` (positive when `other` is later).
    public func days(to other: EventDay) -> Int {
        func ordinal(_ d: EventDay) -> Int {
            // Days since 2000-01-01 (proleptic Gregorian).
            var n = 0
            for y in 2000..<d.year { n += (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 366 : 365 }
            for m in 1..<d.month { n += EventDay.days(d.year, m) }
            return n + d.day
        }
        return ordinal(other) - ordinal(self)
    }

    public func adding(days n: Int) -> EventDay {
        var y = year, m = month, d = day + n
        while d > EventDay.days(y, m) {
            d -= EventDay.days(y, m)
            m += 1
            if m > 12 { m = 1; y += 1 }
        }
        while d < 1 {
            m -= 1
            if m < 1 { m = 12; y -= 1 }
            d += EventDay.days(y, m)
        }
        return EventDay(year: y, month: m, day: d)!
    }
}

/// F-18 §35 item 6: the dates a page states. Reads 「2026年11月28日」, 「11月28日」, 「11月28日-29日」, 「11月28日至12月12日」,
/// 「11.28-29」, 「2026-11-28」, 「11/28」 (and ranges of each). A form without a year takes the page's own year (the first
/// 「20xx年」 or 「20xx-」 on it) or else the window's.
public enum EventDates {
    public struct Range: Sendable, Hashable {
        public let start: EventDay
        public let end: EventDay
    }

    private static let dash = #"\s*(?:-|–|—|~|～|至|到)\s*"#
    /// 「(2026年)11月28日(-(2026年)(12月)29日)」
    private static let chinese = try! NSRegularExpression(pattern:
        #"(?:(20\d{2})\s*年\s*)?(\d{1,2})\s*月\s*(\d{1,2})\s*[日号]?(?:"# + dash
        + #"(?:(20\d{2})\s*年\s*)?(?:(\d{1,2})\s*月\s*)?(\d{1,2})\s*[日号]?)?"#)
    /// 「2026-11-28」, 「2026/11/28」, 「2026.11.28」 with an optional end.
    private static let iso = try! NSRegularExpression(pattern:
        #"(?<!\d)(20\d{2})[-/.](\d{1,2})[-/.](\d{1,2})(?!\d)(?:"# + dash
        + #"(?:(20\d{2})[-/.])?(?:(\d{1,2})[-/.])?(\d{1,2})(?![\d年]))?"#)
    /// 「11.28-29」, 「11/28」, 「11.28-12.2」.
    private static let short = try! NSRegularExpression(pattern:
        #"(?<![\d./-])(\d{1,2})[./](\d{1,2})(?![\d])(?:"# + dash + #"(?:(\d{1,2})[./])?(\d{1,2})(?![\d./]))?(?![./]\d)"#)
    private static let pageYear = try! NSRegularExpression(pattern: #"(20\d{2})\s*(?:年|-\d{1,2}-)"#)

    /// The year the page states for itself, if any.
    public static func year(of text: String) -> Int? {
        let ns = text as NSString
        guard let m = pageYear.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Int(ns.substring(with: m.range(at: 1)))
    }

    /// Every date range on `text` (a single date is a range of one day).
    public static func ranges(in text: String, defaultYear: Int) -> [Range] {
        var masked = text as NSString
        var out: [Range] = []
        for (regex, kind) in [(chinese, 0), (iso, 1), (short, 2)] {
            let matches = regex.matches(in: masked as String, range: NSRange(location: 0, length: masked.length))
            for m in matches {
                if let r = range(m, kind: kind, in: masked, defaultYear: defaultYear) { out.append(r) }
            }
            // A matched span is not read again by the next form.
            let copy = NSMutableString(string: masked as String)
            for m in matches.reversed() {
                copy.replaceCharacters(in: m.range, with: String(repeating: " ", count: m.range.length))
            }
            masked = copy
        }
        return out
    }

    /// True when `text` states any date (item 4's excerpt lines).
    public static func hasDate(_ text: String) -> Bool { !ranges(in: text, defaultYear: 2026).isEmpty }

    /// Item 6: the page states the event's start and end (as a range, or each as a date).
    public static func onPage(_ text: String, start: EventDay, end: EventDay, windowYear: Int) -> Bool {
        let rs = ranges(in: text, defaultYear: year(of: text) ?? windowYear)
        if rs.contains(where: { $0.start == start && $0.end == end }) { return true }
        let days = Set(rs.flatMap { [$0.start, $0.end] })
        return days.contains(start) && days.contains(end)
    }

    private static func range(_ m: NSTextCheckingResult, kind: Int, in text: NSString, defaultYear: Int) -> Range? {
        func int(_ i: Int) -> Int? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(text.substring(with: r))
        }
        let y1: Int, mo1: Int, d1: Int, y2: Int?, mo2: Int?, d2: Int?
        switch kind {
        case 0, 1:
            guard let m1 = int(2), let dd = int(3) else { return nil }
            y1 = int(1) ?? defaultYear
            mo1 = m1
            d1 = dd
            y2 = int(4)
            mo2 = int(5)
            d2 = int(6)
        default:
            guard let m1 = int(1), let dd = int(2) else { return nil }
            y1 = defaultYear
            mo1 = m1
            d1 = dd
            y2 = nil
            mo2 = int(3)
            d2 = int(4)
        }
        guard let start = EventDay(year: y1, month: mo1, day: d1) else { return nil }
        guard let d2 else { return Range(start: start, end: start) }
        var endYear = y2 ?? y1
        var endMonth = mo2 ?? mo1
        if mo2 == nil && d2 < d1 { endMonth += 1 }  // 「11月30日-2日」: the next month
        if endMonth > 12 { endMonth = 1; endYear += 1 }
        if y2 == nil && endMonth < mo1 { endYear += 1 }  // 「12月28日至1月3日」
        guard let end = EventDay(year: endYear, month: endMonth, day: d2), start <= end else { return Range(start: start, end: start) }
        return Range(start: start, end: end)
    }
}
