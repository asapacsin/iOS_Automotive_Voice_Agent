import Foundation
import NovaKit

/// F-18 §44 items 1, 7-9 (T-046zg, PoC 2026-11-25: 7 real values kept, 6 planted errors caught; items 7-9 26/26): an
/// event's venue, dates, start time and ticket note are kept only when its source text states them. Code only, no model.
public enum EventSourceCheck {
    /// One piece of source text: a result's `title` + `content`, or a page's text with its `<title>`.
    public struct Text: Sendable, Hashable {
        public let title: String
        public let body: String
        public init(title: String, body: String) {
            self.title = title
            self.body = body
        }
    }

    /// A search result's text.
    public static func result(title: String, content: String) -> Text { Text(title: title, body: title + " " + content) }

    /// A page's text: `<title>`, and the body with scripts, styles and tags removed, entities decoded, spaces collapsed.
    public static func page(_ html: String) -> Text {
        let title = first(#"<title[^>]*>([\s\S]*?)</title>"#, in: html).map(clean) ?? ""
        var body = replace(#"<(script|style|noscript)\b[^>]*>[\s\S]*?</\1>"#, in: html, with: " ")
        body = replace(#"<[^>]+>"#, in: body, with: " ")
        return Text(title: title, body: clean(body))
    }

    static func clean(_ s: String) -> String {
        var t = s
        for (k, v) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: k, with: v)
        }
        return replace(#"\s+"#, in: t, with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: Item 1a, venue

    /// Item 1a: `venue` split at 「；」「;」「、」「/」.
    public static func venueParts(_ venue: String) -> [String] {
        venue.split(whereSeparator: { "；;、/".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Item 1a: the parts the text has right after a place word (then optionally 「广东」/「广东省」 and one of the call's
    /// cities, with or without 「市」); the others dropped.
    public static func venue(_ venue: String, in texts: [Text], cities: [String]) -> [String] {
        let cityGroup = cities.isEmpty ? "" : "(?:(?:" + cities.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|") + ")市?)?"
        return venueParts(venue).filter { part in
            let pattern = #"(?:地点|地址|场地|场馆|会场|举办地|在|于|at|venue)[\s：:]{0,3}(?:广东省|广东)?"# + cityGroup
                + NSRegularExpression.escapedPattern(for: part)
            return texts.contains { has(pattern, in: $0.body) }
        }
    }

    // MARK: Items 1b and 7, dates

    static let englishMonths = ["January", "February", "March", "April", "May", "June", "July", "August", "September",
                                "October", "November", "December"]

    /// Item 1b: the forms of one day: 「M月D日」 「M月D号」 「M.D」 「M/D」 「MM-DD」 「YYYY.MM.DD」 「<English month> D」.
    static func dayPattern(_ d: EventDay) -> String {
        let m = d.month, dd = d.day
        let mm = String(format: "%02d", m), d2 = String(format: "%02d", dd)
        return [
            #"(?<!\d)0?\#(m)月0?\#(dd)[日号]"#,
            #"(?<![\d.])\#(m)\.\#(dd)(?![\d.])"#,
            #"(?<![\d/])\#(m)/\#(dd)(?![\d/])"#,
            #"(?<!\d)\#(mm)-\#(d2)(?!\d)"#,
            #"\#(d.year)\.\#(mm)\.\#(d2)(?!\d)"#,
            #"\b\#(englishMonths[m - 1])\s+\#(dd)(?!\d)"#,
        ].map { "(?:\($0))" }.joined(separator: "|")
    }

    /// Items 1b and 7: kept when one text has the start day with the start's year within 20 characters before it (or
    /// in the title), and, when the end differs, the end day in one of the forms or, in the same month, 「D日」/「D号」
    /// after one of `-–—~～至到` within 20 characters after the start day.
    public static func dates(start: EventDay, end: EventDay, in texts: [Text]) -> Bool {
        let year = String(start.year)
        for t in texts {
            let body = t.body as NSString
            for m in ranges(dayPattern(start), in: t.body) {
                let before = body.substring(with: NSRange(location: max(0, m.location - 20), length: m.location - max(0, m.location - 20)))
                let matched = body.substring(with: m)
                guard before.contains(year) || matched.hasPrefix(year) || t.title.contains(year) else { continue }
                if end == start { return true }
                if has(dayPattern(end), in: t.body) { return true }
                if end.year == start.year, end.month == start.month {
                    let after = body.substring(with: NSRange(location: m.location + m.length,
                                                             length: min(20, body.length - m.location - m.length)))
                    if has(#"[-–—~～至到]\s*0?\#(end.day)[日号]"#, in: after) { return true }
                }
            }
        }
        return false
    }

    // MARK: Item 8, start time

    /// Item 8: `HH:MM` kept when a text has it as 「H:MM」 「HH:MM」 「H点」 「H点MM」, or for 12:00 and later
    /// 「下午h时」 「晚上h时」 「下午h点」 「晚上h点」 「hpm」 「h p.m.」 (h = hour − 12); else nil.
    public static func time(_ hhmm: String, in texts: [Text]) -> String? {
        let p = hhmm.split(separator: ":").compactMap { Int($0) }
        guard p.count == 2, (0...23).contains(p[0]), (0...59).contains(p[1]) else { return nil }
        let h = p[0], m = p[1], mm = String(format: "%02d", m)
        var forms = [#"(?<!\d)0?\#(h):\#(mm)(?!\d)"#, m == 0 ? #"(?<!\d)\#(h)点(?!\d)"# : #"(?<!\d)\#(h)点\#(mm)(?!\d)"#]
        if h >= 12, m == 0 {
            let h12 = h - 12
            forms += [#"(?:下午|晚上)\#(h12)[时点](?!\d)"#, #"(?<!\d)\#(h12)pm\b"#, #"(?<!\d)\#(h12) p\.m\."#]
        }
        let pattern = forms.map { "(?:\($0))" }.joined(separator: "|")
        return texts.contains { has(pattern, in: $0.body) } ? String(format: "%02d:%02d", h, m) : nil
    }

    // MARK: Item 9, ticket note

    /// Item 9: the notes from the text within 30 characters before to 300 after each mention of the start day, in this
    /// order: 售罄, 免费, 需预约, 需购票, then 报名已截止 / 报名截止M月D日 / 需报名. Empty: nothing shown.
    public static func ticket(start: EventDay, in texts: [Text], today: EventDay) -> [String] {
        var windows: [String] = []
        for t in texts {
            let body = t.body as NSString
            for m in ranges(dayPattern(start), in: t.body) {
                let a = max(0, m.location - 30), b = min(body.length, m.location + m.length + 300)
                windows.append(body.substring(with: NSRange(location: a, length: b - a)))
            }
        }
        func any(_ words: [String]) -> Bool { windows.contains { w in words.contains { w.range(of: $0, options: .caseInsensitive) != nil } } }
        var notes: [String] = []
        if any(["售罄", "sold out"]) { notes.append("售罄") }
        if any(["无需门票", "免费参与", "免费入场", "免费参观"]) { notes.append("免费") }
        if any(["预约"]) { notes.append("需预约") }
        if any(["票价", "门票价钱", "购票", "开票", "公开发售"]) { notes.append("需购票") }
        if let close = windows.lazy.compactMap({ registrationClose($0, year: today.year) }).first {
            notes.append(close < today ? "报名已截止" : "报名截止\(close.month)月\(close.day)日")
        } else if any(["报名", "registration"]) {
            notes.append("需报名")
        }
        return notes
    }

    /// Item 9: 「报名」/`registration`, then within 40 characters 「截止」/`close`, then within 30 more a date (「M月D日」 or
    /// `on <English month> D`); the date in `year`.
    static func registrationClose(_ w: String, year: Int) -> EventDay? {
        let months = englishMonths.joined(separator: "|")
        let pattern = #"(?:报名|registration)[\s\S]{0,40}?(?:截止|close)[\s\S]{0,30}?(?:(\d{1,2})月(\d{1,2})日|on\s+("#
            + months + #")\s+(\d{1,2})(?!\d))"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: w, range: NSRange(location: 0, length: (w as NSString).length)) else { return nil }
        let s = w as NSString
        func g(_ i: Int) -> String? { m.range(at: i).location == NSNotFound ? nil : s.substring(with: m.range(at: i)) }
        if let mo = g(1).flatMap(Int.init), let d = g(2).flatMap(Int.init) { return EventDay(year: year, month: mo, day: d) }
        if let name = g(3), let mo = englishMonths.firstIndex(where: { $0.lowercased() == name.lowercased() }),
           let d = g(4).flatMap(Int.init) {
            return EventDay(year: year, month: mo + 1, day: d)
        }
        return nil
    }

    // MARK: Regex helpers

    static func ranges(_ pattern: String, in text: String) -> [NSRange] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
    }

    static func has(_ pattern: String, in text: String) -> Bool { !ranges(pattern, in: text).isEmpty }

    static func first(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (text as NSString).substring(with: m.range(at: 1))
    }

    static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: template)
    }
}
