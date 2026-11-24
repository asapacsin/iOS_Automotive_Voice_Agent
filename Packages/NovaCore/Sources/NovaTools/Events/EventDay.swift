import Foundation

/// F-18 §35 item 6, §39 item 4 (T-046x, T-046zb): a calendar day as `YYYY-MM-DD` (string order is date order).
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
