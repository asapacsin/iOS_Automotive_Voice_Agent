import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-18 §26 (T-046o): weather for any place and any day in the next 16 days. Pure: argument checks, the 高德 name
/// check, the source and day choice, the WMO words and the result. The network sits behind NovaPorts.
public enum ForecastWeather {
    /// Item 10: the credit 设置 shows (Open-Meteo's data is CC BY 4.0).
    public static let credit = "天气数据：Open-Meteo.com（CC BY 4.0）"

    // MARK: Item 1: arguments

    public static let argumentAdvice = "日期用 yyyy-MM-dd（只填 day 或 date 其中一个）；国外地点 country 填两个大写字母，例如 NO。"

    public struct Arguments: Sendable, Hashable {
        public let `where`: String
        public let day: String?
        public let date: SearchDate.Day?
        public let country: String?
    }

    /// nil when item 1 makes the call `INVALID_ARGUMENT` (with `argumentAdvice`).
    public static func arguments(_ args: JSONValue) -> Arguments? {
        let target = args["where"]?.stringValue ?? "here"
        let day = args["day"]?.stringValue
        let dateText = args["date"]?.stringValue
        let country = args["country"]?.stringValue
        if day != nil && dateText != nil { return nil }
        var date: SearchDate.Day?
        if let dateText {
            guard let parsed = isoDay(dateText) else { return nil }
            date = parsed
        }
        if let country {
            guard country.unicodeScalars.count == 2, country.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
            if ["here", "destination", ""].contains(target) { return nil }
        }
        return Arguments(where: target, day: day, date: date, country: country)
    }

    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// A real `yyyy-MM-dd` day, or nil.
    public static func isoDay(_ text: String) -> SearchDate.Day? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = gregorian.date(from: DateComponents(year: y, month: m, day: d)) else { return nil }
        let back = gregorian.dateComponents([.year, .month, .day], from: date)
        guard back.year == y, back.month == m, back.day == d else { return nil }
        return SearchDate.Day(year: y, month: m, day: d)
    }

    /// Whole days from `a` to `b`.
    public static func days(from a: SearchDate.Day, to b: SearchDate.Day) -> Int {
        let start = gregorian.date(from: DateComponents(year: a.year, month: a.month, day: a.day))!
        let end = gregorian.date(from: DateComponents(year: b.year, month: b.month, day: b.day))!
        return gregorian.dateComponents([.day], from: start, to: end).day ?? 0
    }

    static func adding(_ n: Int, to day: SearchDate.Day) -> SearchDate.Day {
        let start = gregorian.date(from: DateComponents(year: day.year, month: day.month, day: day.day))!
        let c = gregorian.dateComponents([.year, .month, .day], from: gregorian.date(byAdding: .day, value: n, to: start)!)
        return SearchDate.Day(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Item 6: 星期一…星期日 of a `yyyy-MM-dd` day.
    public static func weekday(_ iso: String) -> String? {
        guard let d = isoDay(iso),
              let date = gregorian.date(from: DateComponents(year: d.year, month: d.month, day: d.day)) else { return nil }
        let names = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]
        return names[gregorian.component(.weekday, from: date) - 1]
    }

    // MARK: Item 2: finding the place

    /// `country` nil, CN, HK or MO: 高德.
    public static func usesAmap(country: String?) -> Bool { country == nil || ["CN", "HK", "MO"].contains(country!) }

    public static let amapNotFoundAdvice = "高德没有找到这个地点。如果是国外的地方，用英文名并填 country 再调用一次，例如 where=Oslo, country=NO。"
    public static let notFoundAdvice = "没有找到这个地点。请用一句话如实说没找到，问一下是哪里。"

    /// Item 2 name check (ours): 省, 市, 区, 县, 镇 removed from `where`; every remaining character must appear in
    /// `formatted_address`.
    public static func nameMatches(_ name: String, formatted: String?) -> Bool {
        guard let formatted else { return false }
        return name.filter { !"省市区县镇".contains($0) }.allSatisfy { formatted.contains($0) }
    }

    /// Item 2: the largest `population` (missing is 0); on a tie, the first.
    public static func pick(_ places: [LookedUpPlace]) -> LookedUpPlace? {
        var best: LookedUpPlace?
        for p in places where best == nil || (p.population ?? 0) > (best!.population ?? 0) { best = p }
        return best
    }

    // MARK: Item 4: the forecast call

    /// Coordinates rounded to 2 decimals before sending (about 1 km).
    public static func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    // MARK: Item 5: which day

    public static let pastAdvice = "过去的天气查不到，请如实说明。"
    public static func notOutAdvice(last: SearchDate.Day) -> String {
        "预报只到\(last.month)月\(last.day)日，这一天的预报还没出来。请如实说还没有预报，不要用 web_search 查这一天的预报。可以说这个时候一般的气温，并说明不是预报。"
    }

    public enum Pick: Sendable, Hashable {
        case day(DailyForecastDay)
        case past
        case notOut(last: SearchDate.Day)
        case missing
    }

    /// `day`: offset 0–3 from `time[0]` (the place's own today). `date`: the entry whose `time` equals it.
    public static func pick(_ days: [DailyForecastDay], day: String?, date: SearchDate.Day?) -> Pick {
        guard let first = days.first.flatMap({ isoDay($0.time) }), let last = days.last.flatMap({ isoDay($0.time) }) else {
            return .missing
        }
        let wanted = date ?? adding(day.flatMap { WeatherDay.names.firstIndex(of: $0) } ?? 0, to: first)
        if wanted < first { return .past }
        if last < wanted { return .notOut(last: last) }
        guard let entry = days.first(where: { $0.time == wanted.iso }) else { return .missing }
        return .day(entry)
    }

    // MARK: Item 6: the result

    /// §27 item 4: for both sources.
    public static let next = "只按 weather 里的数据用一两句话回答，说出地点和几月几号星期几；问现在几度时说现在的气温（now 里的 temperature_c，高德结果的 temperature_c），不要编造。"

    /// §27 item 3: `now` only when the answered day is `daily.time[0]` (the place's today) and `current` is there.
    public static func now(_ c: CurrentWeather?, answered: DailyForecastDay, days: [DailyForecastDay]) -> JSONValue? {
        guard let c, answered.time == days.first?.time else { return nil }
        func whole(_ v: Double?) -> JSONValue { v.map { .int(Int64($0.rounded())) } ?? .null }
        func number(_ v: Double?) -> JSONValue { v.map { $0 == $0.rounded() ? .int(Int64($0)) : .double($0) } ?? .null }
        let clock = c.time.split(separator: "T").last.map(String.init) ?? c.time
        return .object([
            "temperature_c": whole(c.temperature), "feels_like_c": whole(c.feelsLike), "humidity": whole(c.humidity),
            "weather": .string(words(c.weatherCode)), "wind_kmh": number(c.windKmh), "time": .string(clock),
        ])
    }

    public static func summary(_ d: DailyForecastDay, place: String, country: String?, now: JSONValue? = nil) -> JSONValue {
        func whole(_ v: Double?) -> JSONValue { v.map { .int(Int64($0.rounded())) } ?? .null }
        func number(_ v: Double?) -> JSONValue { v.map { $0 == $0.rounded() ? .int(Int64($0)) : .double($0) } ?? .null }
        var o: [String: JSONValue] = [
            "place": .string(place), "date": .string(d.time), "weekday": .string(weekday(d.time) ?? ""),
            "weather": .string(words(d.weatherCode)), "temp_high": whole(d.tempMax), "temp_low": whole(d.tempMin),
            "rain_chance": number(d.rainChance), "rain_mm": number(d.rainMm), "wind_max_kmh": number(d.windMaxKmh),
            "source": "open-meteo",
        ]
        if let country { o["country"] = .string(country) }
        if let now { o["now"] = now }
        return .object(o)
    }

    // MARK: Item 7: WMO words

    public static let wmo: [Int: String] = [
        0: "晴", 1: "大致晴", 2: "局部多云", 3: "阴", 45: "雾", 48: "雾凇", 51: "小毛毛雨", 53: "毛毛雨", 55: "大毛毛雨",
        56: "冻毛毛雨", 57: "冻毛毛雨", 61: "小雨", 63: "中雨", 65: "大雨", 66: "冻雨", 67: "冻雨", 71: "小雪", 73: "中雪",
        75: "大雪", 77: "雪粒", 80: "小阵雨", 81: "阵雨", 82: "强阵雨", 85: "小阵雪", 86: "大阵雪", 95: "雷阵雨",
        96: "雷阵雨伴有冰雹", 99: "雷阵雨伴有冰雹",
    ]
    public static func words(_ code: Int?) -> String { code.flatMap { wmo[$0] } ?? "未知" }
}

/// F-18 §26 item 11: what `RuntimeLog` gets: `weather source=<amap|open-meteo> ok=<yes|no> reason=<…>`. No place
/// names, dates or coordinates (I-8).
public struct WeatherSourceLog: Sendable, Hashable {
    public let source: String
    public let ok: Bool
    public let reason: String
    public var line: String { "weather source=\(source) ok=\(ok ? "yes" : "no") reason=\(reason)" }
}
