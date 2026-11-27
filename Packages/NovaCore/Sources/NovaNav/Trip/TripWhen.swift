import Foundation
import NovaTools

/// F-15b §74 item 4 (T-040zza): the driver's date words (`asked.when`) as the trip's first day, by code (no model).
/// Only these forms: a weekend or a weekday of this week or next week (这/本/下/下个/下星期 + 周末/周六/周日/星期六/星期天…;
/// a bare 周末 is this weekend; a week runs Monday to Sunday, so this weekend on a Saturday or Sunday is that weekend;
/// a weekend's first day is its Saturday), 今天/明天/后天, and an explicit date (M月D日/号, this year, or the next when
/// already past). Anything else: nil.
public enum TripWhen {
    static let dayNumbers: [Character: Int] = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7]

    public static func resolve(_ text: String, today: EventDay) -> EventDay? {
        let t = text.filter { !$0.isWhitespace }
        guard !t.isEmpty else { return nil }
        // Review fix: only the listed forms; 大后天 and 下下周 are not among them (her `start` is kept).
        if t.contains("大后天") || t.contains("下下") { return nil }
        if let d = explicitDate(t, today: today) { return d }
        let monday = today.adding(days: 1 - weekday(today))
        if let (week, day) = weekForm(t) { return monday.adding(days: week * 7 + day - 1) }
        for (word, n) in [("今天", 0), ("明天", 1), ("后天", 2)] where t.contains(word) { return today.adding(days: n) }
        if t.contains("周末") { return monday.adding(days: 5) }
        return nil
    }

    /// 1 (Monday) … 7 (Sunday).
    static func weekday(_ d: EventDay) -> Int {
        let w = TripDayLabel.weekday(d)
        return dayNumbers[w.last ?? "一"] ?? 1
    }

    /// (0 this week / 1 next week, day 1…7, a weekend as 6) for 这/本/下/下个/下星期 + a day word.
    static func weekForm(_ t: String) -> (Int, Int)? {
        let chars = Array(t)
        var i = 0
        while i < chars.count {
            let week: Int? = chars[i] == "这" || chars[i] == "本" ? 0 : chars[i] == "下" ? 1 : nil
            if let week {
                var j = i + 1
                if j < chars.count, chars[j] == "个" { j += 1 }
                let rest = String(chars[j...])
                if let day = dayWord(rest) { return (week, day) }
                for w in ["星期", "礼拜", "周"] where rest.hasPrefix(w) {
                    if let day = dayWord(String(rest.dropFirst(w.count))) { return (week, day) }
                }
            }
            i += 1
        }
        return nil
    }

    /// The day a text starts with: 周末 (6), 周六 / 星期六 / 礼拜六 …, 末 after a week word (6).
    static func dayWord(_ s: String) -> Int? {
        for w in ["周末", "末"] where s.hasPrefix(w) { return 6 }
        for p in ["星期", "礼拜", "周"] where s.hasPrefix(p) {
            if let c = s.dropFirst(p.count).first, let n = dayNumbers[c] { return n }
        }
        return nil
    }

    /// M月D日 / M月D号 in digits; this year, or the next when the day has passed.
    static func explicitDate(_ t: String, today: EventDay) -> EventDay? {
        guard let re = try? NSRegularExpression(pattern: "([0-9]{1,2})月([0-9]{1,2})[日号]"),
              let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
              let mr = Range(m.range(at: 1), in: t), let dr = Range(m.range(at: 2), in: t),
              let month = Int(t[mr]), let day = Int(t[dr]) else { return nil }
        if let d = EventDay(year: today.year, month: month, day: day), d >= today { return d }
        return EventDay(year: today.year + 1, month: month, day: day)
    }
}
