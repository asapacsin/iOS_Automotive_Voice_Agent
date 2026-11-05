import Foundation
import Synchronization

/// F-18 §19 (T-046g): the app works out which day a search means from the phone's date, writes that date into the
/// question, and checks a future day's answer. Pure.
///
/// What this does not catch (§19 item 7), left to the record:
/// - She writes the wrong date herself (后天 becoming 11月7日 with no relative word left); the app cannot know.
/// - The right date with the wrong forecast, or a wrong number for the right date.
/// - An answer with no date (`no_date`).
/// - Other date words such as 周五 or 下周一: sent unchanged, with no target.
public enum SearchDate {
    public struct Day: Sendable, Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int
        public init(year: Int, month: Int, day: Int) {
            self.year = year
            self.month = month
            self.day = day
        }
        public static func < (a: Day, b: Day) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
        /// `2026-11-06`.
        public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }
        /// `11月6日`.
        public var short: String { "\(month)月\(day)日" }
        /// `2026年11月6日`.
        public var long: String { "\(year)年\(month)月\(day)日" }
    }

    public enum Check: String, Sendable, Hashable {
        case match, noDate = "no_date", mismatch, skipped
    }

    public struct Resolved: Sendable, Hashable {
        /// The query to send (with the bracketed date when one was added).
        public let query: String
        public let target: Day?
        public let added: Bool
        public let today: Day
        /// Items 4-5 apply only to a day after today.
        public var future: Bool { target.map { $0 > today } ?? false }
    }

    /// Longest first, so 大后天 is never read as 后天.
    static let relative: [(String, Int)] = [("大后天", 3), ("后天", 2), ("明天", 1), ("明日", 1), ("今天", 0), ("今日", 0)]

    static func calendar(_ zone: TimeZone) -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = zone
        return c
    }

    public static func today(_ now: Date, zone: TimeZone) -> Day {
        let c = calendar(zone).dateComponents([.year, .month, .day], from: now)
        return Day(year: c.year!, month: c.month!, day: c.day!)
    }

    public static func adding(_ days: Int, to day: Day, zone: TimeZone) -> Day {
        let cal = calendar(zone)
        let base = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12))!
        let c = cal.dateComponents([.year, .month, .day], from: cal.date(byAdding: .day, value: days, to: base)!)
        return Day(year: c.year!, month: c.month!, day: c.day!)
    }

    static func valid(_ day: Day, zone: TimeZone) -> Bool {
        let cal = calendar(zone)
        guard let date = cal.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) else { return false }
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return c.year == day.year && c.month == day.month && c.day == day.day
    }

    /// Relative words in order, as (range, offset), matched longest first without overlap.
    static func relativeWords(_ text: String) -> [(Range<String.Index>, Int)] {
        var out: [(Range<String.Index>, Int)] = []
        var i = text.startIndex
        while i < text.endIndex {
            if let (word, offset) = relative.first(where: { text[i...].hasPrefix($0.0) }) {
                let end = text.index(i, offsetBy: word.count)
                out.append((i..<end, offset))
                i = end
            } else {
                i = text.index(after: i)
            }
        }
        return out
    }

    static let writtenPattern = try! NSRegularExpression(pattern: #"(?:(\d{4})年)?(\d{1,2})月(\d{1,2})[日号]"#)

    /// Written dates in a query; a date with no year takes this year, or next year once it has passed.
    static func writtenDates(_ text: String, today: Day, zone: TimeZone) -> [Day] {
        let ns = text as NSString
        return writtenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            func int(_ i: Int) -> Int? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            guard let month = int(2), let d = int(3) else { return nil }
            var day = Day(year: int(1) ?? today.year, month: month, day: d)
            if int(1) == nil, day < today { day = Day(year: today.year + 1, month: month, day: d) }
            return valid(day, zone: zone) ? day : nil
        }
    }

    /// §19 items 1-2: the target day and the query to send. A query naming more than one day has no target.
    public static func resolve(_ query: String, now: Date, zone: TimeZone) -> Resolved {
        let today = today(now, zone: zone)
        let words = relativeWords(query)
        let written = writtenDates(query, today: today, zone: zone)
        let days = Set(words.map { adding($0.1, to: today, zone: zone) } + written)
        let target = days.count == 1 ? days.first : nil
        guard let target, written.isEmpty, !words.isEmpty else {
            return Resolved(query: query, target: target, added: false, today: today)
        }
        var out = query
        for (range, _) in words.reversed() {
            out.insert(contentsOf: "（\(target.long)）", at: range.upperBound)
        }
        return Resolved(query: out, target: target, added: true, today: today)
    }

    static let answerPattern = try! NSRegularExpression(
        pattern: #"(\d{1,2})月(\d{1,2})[日号]?(?:\s*(?:至|到|~|～|-|—)\s*(?:(\d{1,2})月)?(\d{1,2})[日号])?"#)

    /// `M月D日` / `M月D号` in an answer, ranges counted as every day in them, in the target's year. A bare `M月D`
    /// without 日 or 号 counts only as the start of a range.
    static func answerDays(_ answer: String, year: Int, zone: TimeZone) -> Set<Day> {
        let ns = answer as NSString
        var out = Set<Day>()
        for m in answerPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
            func int(_ i: Int) -> Int? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
            }
            guard let m1 = int(1), let d1 = int(2) else { continue }
            let start = Day(year: year, month: m1, day: d1)
            guard valid(start, zone: zone) else { continue }
            guard let d2 = int(4) else {
                // A single date needs its 日 or 号.
                let text = ns.substring(with: m.range)
                if text.hasSuffix("日") || text.hasSuffix("号") { out.insert(start) }
                continue
            }
            let m2 = int(3) ?? m1
            var end = Day(year: m2 < m1 ? year + 1 : year, month: m2, day: d2)
            guard valid(end, zone: zone) else { out.insert(start); continue }
            if end < start { end = start }
            var day = start
            var n = 0
            while day <= end, n < 62 {
                out.insert(day)
                day = adding(1, to: day, zone: zone)
                n += 1
            }
        }
        return out
    }

    /// §19 item 4: future targets only. Month and day are compared; the answer's dates take the target's year.
    public static func check(_ answer: String, _ resolved: Resolved, zone: TimeZone) -> Check {
        guard let target = resolved.target, resolved.future else { return .skipped }
        let days = answerDays(answer, year: target.year, zone: zone)
        if days.isEmpty { return .noDate }
        return days.contains { $0.month == target.month && $0.day == target.day } ? .match : .mismatch
    }
}

/// F-18 §21 items 1, 3-4 (T-046i): the current destination's name in the search. Pure.
public enum SearchPlace {
    /// Words that ask about opening hours (item 4).
    static let hoursWords = ["几点", "关门", "开门", "营业", "开放", "闭馆", "打烊"]
    static let destinationWords = ["目的地", "终点"]

    /// Item 1: no line breaks, none of `「」[]{}`, at most 60 characters; nil when nothing is left.
    public static func clean(_ name: String?) -> String? {
        guard let name else { return nil }
        let removed = Set("「」[]{}")
        let kept = name.filter { !$0.isNewline && !removed.contains($0) }
            .trimmingCharacters(in: .whitespaces)
        let cut = String(kept.prefix(60))
        return cut.isEmpty ? nil : cut
    }

    /// Item 3: 目的地 / 终点 become the destination's name when the query does not already name it.
    public static func substitute(_ query: String, destination: String?) -> (query: String, added: Bool) {
        guard let destination, !query.contains(destination),
              destinationWords.contains(where: { query.contains($0) }) else { return (query, false) }
        // One pass, so a name that itself contains 终点 is not replaced again.
        var out = ""
        var i = query.startIndex
        while i < query.endIndex {
            if let word = destinationWords.first(where: { query[i...].hasPrefix($0) }) {
                out += destination
                i = query.index(i, offsetBy: word.count)
            } else {
                out.append(query[i])
                i = query.index(after: i)
            }
        }
        return (out, true)
    }

    /// Item 4: a destination, a query that does not name it, and an opening-hours word.
    public static func hint(_ query: String, destination: String?) -> Bool {
        guard let destination else { return false }
        return !query.contains(destination) && hoursWords.contains { query.contains($0) }
    }
}

/// The current destination's name, shared between the navigation stream (writer) and `web_search` (reader).
public final class DestinationHolder: Sendable {
    private let value = Mutex<String?>(nil)
    public init() {}
    public var name: String? { value.withLock { $0 } }
    public func set(_ name: String?) { value.withLock { $0 = name } }
}
