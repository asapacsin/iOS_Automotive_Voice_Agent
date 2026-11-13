import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-18 §26 (T-046o): weather for any place and any day in the next 10 days (§31 item 4). Pure: argument checks, the 高德 name
/// check, the source and day choice, the WMO words and the result. The network sits behind NovaPorts.
public enum ForecastWeather {
    /// Item 10, §31 item 8: the credit 设置 shows (Open-Meteo's data is CC BY 4.0).
    public static let credit = "天气数据：和风天气；备用：Open-Meteo.com（CC BY 4.0）"

    // MARK: Item 1: arguments

    public static let argumentAdvice = "日期用 yyyy-MM-dd（只填 day 或 date 其中一个）；国外地点 country 填两个大写字母，例如 NO。part 只能是 morning、afternoon、evening，不能和 day=now 一起用。"

    /// §28: the reading now, a whole day, or the hours of part of a day.
    public enum View: String, Sendable, Hashable { case now, day, hours }

    /// §28 item 1: `part` on the place's own clock, [start, end) hours.
    public static let parts: [String: Range<Int>] = ["morning": 6..<12, "afternoon": 12..<18, "evening": 18..<24]

    public struct Arguments: Sendable, Hashable {
        public let `where`: String
        /// nil or a whole-day name; `now` is `view == .now`.
        public let day: String?
        public let date: SearchDate.Day?
        public let country: String?
        public let part: String?

        public init(where: String, day: String?, date: SearchDate.Day?, country: String?, part: String? = nil) {
            self.where = `where`
            self.day = day
            self.date = date
            self.country = country
            self.part = part
        }

        /// §28 item 1: no `day`, `date` or `part` (or `day=now`) is now; a `part` is hours; anything else a day.
        public var view: View {
            if part != nil { return .hours }
            if date == nil && (day == nil || day == "now") { return .now }
            return .day
        }
    }

    /// nil when item 1 makes the call `INVALID_ARGUMENT` (with `argumentAdvice`).
    public static func arguments(_ args: JSONValue) -> Arguments? {
        let target = args["where"]?.stringValue ?? "here"
        let day = args["day"]?.stringValue
        let dateText = args["date"]?.stringValue
        let country = args["country"]?.stringValue
        let part = args["part"]?.stringValue
        if day != nil && dateText != nil { return nil }
        if let part, parts[part] == nil || day == "now" { return nil }
        var date: SearchDate.Day?
        if let dateText {
            guard let parsed = isoDay(dateText) else { return nil }
            date = parsed
        }
        if let country {
            guard country.unicodeScalars.count == 2, country.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) else { return nil }
            if ["here", "destination", ""].contains(target) { return nil }
        }
        return Arguments(where: target, day: day == "now" ? nil : day, date: date, country: country, part: part)
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

    public static func adding(_ n: Int, to day: SearchDate.Day) -> SearchDate.Day {
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

    /// `country` nil or CN: 高德. §29 item 1 (T-046r): HK and MO go to Open-Meteo.
    public static func usesAmap(country: String?) -> Bool { country == nil || country == "CN" }

    /// §29 item 1: 香港 (adcode 81…) or 澳门 (82…), else nil.
    public static func hongKongOrMacau(adcode: String?) -> String? {
        guard let adcode else { return nil }
        if adcode.hasPrefix("81") { return "香港" }
        if adcode.hasPrefix("82") { return "澳门" }
        return nil
    }

    /// §29 item 1: Open-Meteo `country_code` HK or MO as 香港 or 澳门, else nil.
    public static func hongKongOrMacau(countryCode: String?) -> String? {
        switch countryCode { case "HK": "香港"; case "MO": "澳门"; default: nil }
    }

    /// §29 item 3: true when the name has at least one Han character.
    public static func hasHan(_ name: String) -> Bool {
        name.unicodeScalars.contains { s in
            (0x4E00...0x9FFF).contains(s.value) || (0x3400...0x4DBF).contains(s.value) || (0x20000...0x2A6DF).contains(s.value)
                || (0xF900...0xFAFF).contains(s.value)
        }
    }

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

    /// §26 item 6 (a whole day, §28 item 3).
    public static let next = "只按 weather 里的数据用一两句话回答，说出地点和几月几号星期几，不要编造。"
    /// §28 item 2 (ours).
    public static let nowNext = "先说现在：地点、现在的天气和气温（now）；再用半句说今天的最高和最低气温（today）。一两句话，不说日期，不要编造。"
    /// §28 item 4 (ours).
    public static let hoursNext = "只按 hours 用一两句话回答这段时间：会不会下雨（rain_chance）和气温范围，说出地点和是哪天的上午、下午或晚上，不要编造。"
    public static let partPassedAdvice = "这段时间已经过去了。请如实说明，可以说现在的天气。"

    /// §28 item 2: Open-Meteo's current block as `weather.now`.
    public static func now(_ c: CurrentWeather?) -> JSONValue? {
        guard let c else { return nil }
        func whole(_ v: Double?) -> JSONValue { v.map { .int(Int64($0.rounded())) } ?? .null }
        func number(_ v: Double?) -> JSONValue { v.map { $0 == $0.rounded() ? .int(Int64($0)) : .double($0) } ?? .null }
        let clock = c.time.split(separator: "T").last.map(String.init) ?? c.time
        return .object([
            "temperature_c": whole(c.temperature), "feels_like_c": whole(c.feelsLike), "humidity": whole(c.humidity),
            "weather": .string(c.text ?? words(c.weatherCode)), "wind_kmh": number(c.windKmh),
        ].merging(clock.isEmpty ? [:] : ["time": .string(clock)]) { a, _ in a })
    }

    /// §28 item 2: Open-Meteo's `daily.time[0]` as `weather.today`.
    public static func today(_ d: DailyForecastDay) -> JSONValue {
        func whole(_ v: Double?) -> JSONValue { v.map { .int(Int64($0.rounded())) } ?? .null }
        return .object(["weather": .string(d.dayText ?? words(d.weatherCode)), "temp_high": whole(d.tempMax), "temp_low": whole(d.tempMin)])
    }

    /// §28 item 4: the hours of `part` on `date`; for the place's today, from its current hour on.
    public enum HoursPick: Sendable, Hashable {
        case hours([HourlyForecast])
        case passed
        case past
        case notOut(last: SearchDate.Day)
        case missing
    }

    public static func hours(_ all: [HourlyForecast], part: String, date: SearchDate.Day, placeNow: String?) -> HoursPick {
        guard let window = parts[part], let first = all.first.flatMap({ isoDay(String($0.time.prefix(10))) }),
              let last = all.last.flatMap({ isoDay(String($0.time.prefix(10))) }) else { return .missing }
        if date < first { return .past }
        if last < date { return .notOut(last: last) }
        let today = placeNow.map { String($0.prefix(10)) }
        let currentHour = placeNow.flatMap { Int($0.dropFirst(11).prefix(2)) }
        let picked = all.filter { h in
            guard h.time.hasPrefix(date.iso), let hour = Int(h.time.dropFirst(11).prefix(2)), window.contains(hour) else { return false }
            if today == date.iso, let currentHour, hour < currentHour { return false }
            return true
        }
        if let today, let t = isoDay(today), date < t { return .past }
        return picked.isEmpty ? .passed : .hours(picked)
    }

    public static func hoursJSON(_ hours: [HourlyForecast]) -> JSONValue {
        .array(hours.map { h in
            .object([
                "time": .string(String(h.time.dropFirst(11).prefix(5))), "weather": .string(h.text ?? words(h.weatherCode)),
                "temp_c": h.temperature.map { .int(Int64($0.rounded())) } ?? .null,
                "rain_chance": h.rainChance.map { .int(Int64($0.rounded())) } ?? .null,
            ])
        })
    }

    /// `yyyy-MM-ddTHH:mm` on the place's clock from the phone's instant and the place's UTC offset.
    public static func placeClock(_ now: Date, utcOffsetSeconds: Int) -> String {
        let c = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: now.addingTimeInterval(Double(utcOffsetSeconds)))
        return String(format: "%04d-%02d-%02dT%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
    }

    public static func summary(_ d: DailyForecastDay, place: String, country: String?, now: JSONValue? = nil,
                               source: String = "open-meteo") -> JSONValue {
        func whole(_ v: Double?) -> JSONValue { v.map { .int(Int64($0.rounded())) } ?? .null }
        func number(_ v: Double?) -> JSONValue { v.map { $0 == $0.rounded() ? .int(Int64($0)) : .double($0) } ?? .null }
        var o: [String: JSONValue] = [
            "place": .string(place), "date": .string(d.time), "weekday": .string(weekday(d.time) ?? ""),
            "weather": .string(d.dayText ?? words(d.weatherCode)), "temp_high": whole(d.tempMax), "temp_low": whole(d.tempMin),
            "rain_chance": number(d.rainChance), "rain_mm": number(d.rainMm), "wind_max_kmh": number(d.windMaxKmh),
            "source": .string(source),
        ]
        // §31 item 3: 和风 gives day and night words.
        if let day = d.dayText { o["weather_day"] = .string(day) }
        if let night = d.nightText { o["weather_night"] = .string(night) }
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

/// F-18 §26 item 11, §30 item 5: what `RuntimeLog` and the record get:
/// `weather source=<amap|open-meteo> ok=<yes|no> reason=<…> view= lookup= attempts= ms=`. No place names, dates,
/// coordinates or weather numbers (I-8).
public struct WeatherSourceLog: Sendable, Hashable {
    public let source: String
    public let ok: Bool
    public let reason: String
    /// §28 item 7: `now`, `day` or `hours`.
    public let view: String
    /// §29 item 4: how the place was found, `amap` or `open-meteo`.
    public let lookup: String
    /// §30 item 5: attempts of the last request (Open-Meteo 1 or 2, 高德 1) and the weather call's total ms.
    public let attempts: Int
    public let ms: Int

    public init(source: String, ok: Bool, reason: String, view: String = "day", lookup: String = "amap",
                attempts: Int = 1, ms: Int = 0) {
        self.attempts = attempts
        self.ms = ms
        self.source = source
        self.ok = ok
        self.reason = reason
        self.view = view
        self.lookup = lookup
    }

    public var line: String {
        "weather source=\(source) ok=\(ok ? "yes" : "no") reason=\(reason) view=\(view) lookup=\(lookup) attempts=\(attempts) ms=\(ms)"
    }
}
