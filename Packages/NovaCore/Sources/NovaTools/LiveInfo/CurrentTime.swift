import Foundation
import NovaKit

/// F-18 §14 (T-046b): `query_live_info(kind=current_time)` from the phone clock and time zone, read at each call and
/// never cached. Gregorian calendar and Chinese wording whatever the phone's language, clock or calendar setting.
public enum CurrentTime {
    static let weekdays = ["星期日", "星期一", "星期二", "星期三", "星期四", "星期五", "星期六"]

    public static func result(now: Date, zone: TimeZone, arguments: JSONValue = ["kind": "current_time"]) -> ToolResult {
        if case .object(let fields) = arguments, fields.keys.contains(where: { $0 != "kind" }) {
            return .failure(.invalidArgument, advice: "查时间不需要其他参数。")
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
            "next": .string("只按 time 和 date 回答，一句话，比如「现在是晚上八点零八分」。"),
        ])
    }

    /// 凌晨 0–5, 早上 5–8, 上午 8–11, 中午 11–13, 下午 13–18, 晚上 18–24. The 8 o'clock hour is 早上, as acceptance row 2
    /// reads it (08:08 早上).
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
