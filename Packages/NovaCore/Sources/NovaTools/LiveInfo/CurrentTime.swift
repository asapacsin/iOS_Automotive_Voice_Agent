import Foundation
import NovaKit

/// F-18 §14 (T-046b): `query_live_info(kind=current_time)` from the phone clock and time zone, read at each call and
/// never cached. Gregorian calendar and Chinese wording whatever the phone's language, clock or calendar setting.
public enum CurrentTime {
    static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    /// F-18 §25 item 2.
    public static let zoneAdvice = "time_zone 要用 IANA 时区名，比如 Asia/Tokyo。"
    /// §25 item 3: with `time_zone`.
    public static let zoneNext = "只按 time 和 date 回答，一句话，说出是哪里的时间。"

    /// §25 items 1-3 (T-046n): optional `time_zone`, an exact `TimeZone.knownTimeZoneIdentifiers` entry (copied from
    /// `mcp-server-time`'s `timezone`); without it, the phone's zone.
    public static func result(now: Date, zone phoneZone: TimeZone, arguments: JSONValue = ["kind": "current_time"]) -> ToolResult {
        var zone = phoneZone
        var named = false
        if case .object(let fields) = arguments {
            if fields.keys.contains(where: { $0 != "kind" && $0 != "time_zone" }) {
                return .failure(.invalidArgument, advice: "查时间不需要其他参数。")
            }
            if let value = fields["time_zone"] {
                guard case .string(let id) = value, TimeZone.knownTimeZoneIdentifiers.contains(id),
                      let given = TimeZone(identifier: id) else {
                    return .failure(.invalidArgument, advice: zoneAdvice)
                }
                zone = given
                named = true
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: now)
        let hour = c.hour ?? 0, minute = c.minute ?? 0
        let offset = zone.secondsFromGMT(for: now)
        let sign = offset < 0 ? "-" : "+"
        let utcOffset = String(format: "%@%02d:%02d", sign, abs(offset) / 3600, abs(offset) % 3600 / 60)
        return .success([
            "time": .string(String(format: "%02d:%02d", hour, minute)),
            "period": .string(period(hour)),
            "date": .string("\(c.year ?? 0)年\(c.month ?? 0)月\(c.day ?? 0)日"),
            "weekday": .string(weekdays[((c.weekday ?? 1) - 1) % 7]),
            "timeZone": .string(zone.identifier),
            "utcOffset": .string(utcOffset),
            "next": .string(named ? zoneNext : "只按 time 和 date 回答，一句话，比如「现在是晚上八点零八分」。"),
        ])
    }

    /// 凌晨 0–5, 早上 5–9, 上午 9–11, 中午 11–13, 下午 13–18, 晚上 18–24 (end hour excluded). The 8 o'clock hour is 早上,
    /// as acceptance row 2 reads it (08:08 早上).
    static func period(_ hour: Int) -> String {
        switch hour {
        case 0..<5: "凌晨"
        case 5..<9: "早上"
        case 9..<11: "上午"
        case 11..<13: "中午"
        case 13..<18: "下午"
        default: "晚上"
        }
    }
}

/// F-18 §25 item 7 (T-046n): a `web_search` query that asks the current time, date or weekday. Ours, not from a
/// source (the owner may remove it). Pure.
public enum CurrentTimeQuery {
    public static let advice = "现在的时间和日期不用搜索：调用 query_live_info（kind=current_time），别的地方填 time_zone。"

    static let anyOf = ["几点了", "当地时间", "当前时间", "北京时间"]
    static let afterNow = ["几点", "时间"]
    static let afterToday = ["几号", "星期几", "礼拜几", "周几"]
    static let afterJidian = ["关门", "开门", "营业", "开始", "结束", "出发", "到", "下班", "上班", "闭馆", "开放", "起飞", "发车"]
    static let beforeShijian = ["营业", "开放", "办公", "上班", "飞行", "行驶", "等待", "排队"]

    public static func matches(_ query: String) -> Bool {
        let q = Array(query)
        if excluded(q) { return false }
        if anyOf.contains(where: query.contains) { return true }
        return follows(q, "现在", within: 8, by: afterNow) || follows(q, "今天", within: 4, by: afterToday)
    }

    /// 几点 directly followed by an excluded word, or 时间 directly after one.
    static func excluded(_ q: [Character]) -> Bool {
        for i in q.indices {
            if has(q, "几点", at: i), afterJidian.contains(where: { has(q, $0, at: i + 2) }) { return true }
            if has(q, "时间", at: i), beforeShijian.contains(where: { i >= $0.count && has(q, $0, at: i - $0.count) }) { return true }
        }
        return false
    }

    /// `first`, then one of `words` starting at most `within` characters after it.
    static func follows(_ q: [Character], _ first: String, within: Int, by words: [String]) -> Bool {
        for i in q.indices where has(q, first, at: i) {
            let start = i + first.count
            for gap in 0...within where words.contains(where: { has(q, $0, at: start + gap) }) { return true }
        }
        return false
    }

    static func has(_ q: [Character], _ word: String, at i: Int) -> Bool {
        let w = Array(word)
        guard i >= 0, i + w.count <= q.count else { return false }
        return Array(q[i..<(i + w.count)]) == w
    }
}

/// F-18 §26 item 9 (ours, not from a source; the owner may remove it): a weather forecast within 10 days (§31 item 4) never goes
/// to search. Blocked when the query has a weather word and either the §19 target is from the phone's today to 9
/// days later, or there is no target and none of the month, week, season or usual-weather words.
public enum WeatherForecastQuery {
    public static let advice = "10天内的天气预报不用搜索：调用 query_live_info（kind=weather），国外地点用英文名并填 country。"
    static let weatherWords = ["天气", "气温", "温度", "下雨", "下雪", "降雨", "降水", "预报", "几度", "多少度"]
    static let otherDayWords = ["月", "年", "周", "星期", "礼拜", "号", "季", "平均", "一般", "往年", "去年", "历史"]

    public static func matches(_ query: String, now: Date, zone: TimeZone) -> Bool {
        guard weatherWords.contains(where: query.contains) else { return false }
        let resolved = SearchDate.resolve(query, now: now, zone: zone)
        if let target = resolved.target {
            let last = SearchDate.adding(9, to: resolved.today, zone: zone)
            return !(target < resolved.today) && !(last < target)
        }
        return !otherDayWords.contains(where: query.contains)
    }
}
