import Foundation
import NovaKit

/// F-15b §52 item 2 (T-040zb): the whole plan as the model reads it, in every trip tool result and in the trip line
/// of the state note: `{"days":[[{"id","name","role","placed","picked_by","minutes"}…]…]}`, every day. A visited or
/// skipped stop also carries `mark`. A plan longer than `maxCharacters` keeps all ids, names and roles and drops
/// `minutes` first. Pure.
public enum TripPlanJSON {
    public static let maxCharacters = 2_000

    public static func value(_ plan: TripPlan) -> JSONValue {
        let full = build(plan, minutes: true)
        if text(full).count <= maxCharacters { return full }
        return build(plan, minutes: false)
    }

    /// The compact text of a value (sorted keys), as it is counted against `maxCharacters`.
    public static func text(_ value: JSONValue) -> String {
        guard let data = try? JSONValue.canonicalEncoder().encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// The state note's trip line: `行程：{…}`; nil when the plan has no stop.
    public static func noteLine(_ plan: TripPlan) -> String? {
        plan.isEmpty ? nil : "行程：" + text(value(plan))
    }

    private static func build(_ plan: TripPlan, minutes: Bool) -> JSONValue {
        // F-15b §61 item 3 (T-040zn): the driver's request at the top of the plan, as she wrote it.
        var top: [String: JSONValue] = [:]
        if let asked = plan.asked { top["asked"] = asked.json }
        return .object(top.merging(["days": .array(plan.days.map { day in
            .array(day.stops.map { s in
                var o: [String: JSONValue] = [
                    // F-15b §67 item 4 (T-040zt): 「<name>（<place name>）」 when they differ, else 「<name>」.
                    "id": .string(s.id), "name": .string(s.label), "role": .string(s.role.rawValue),
                    "placed": .bool(s.placed), "picked_by": .string(s.pickedBy.rawValue),
                ]
                if minutes { o["minutes"] = .int(Int64(s.visitMinutes)) }
                if let mark = s.mark { o["mark"] = .string(mark.rawValue) }
                return .object(o)
            })
        })]) { a, _ in a })
    }

    /// F-15b §61 item 3a (T-040zn): the plan as she wrote it, one line per day, the stop names in order, 「（没找到）」 on
    /// a stop not placed: 「第1天：A、B、住C（没找到）」. A day with no stop says 「（空）」.
    /// §63 item 4: 「<m>分钟」 under an hour, else hours (「2小时」, 「1.5小时」).
    static func stayTime(_ m: Int) -> String {
        guard m >= 60 else { return "\(m)分钟" }
        let h = (Double(m) / 60 * 2).rounded() / 2
        return h == h.rounded() ? "\(Int(h))小时" : "\(h)小时"
    }

    public static func planText(_ plan: TripPlan) -> String {
        plan.days.enumerated().map { d, day in
            let names = day.stops.map { s in
                // F-15b §66 item 6 (T-040zs): an event with no venue was not looked up; its label says 「场馆未找到」.
                let missing = s.placed || !s.mapLookup ? "" : "（没找到）"
                // §63 item 4: a hotel merged with its sight is written once, with the time there.
                if s.role == .hotel, s.visitMinutes > 0 {
                    return s.label + missing + "（玩约\(stayTime(s.visitMinutes))，住这里）"
                }
                // F-15b §64 item 6 (T-040zq): an event stop is 「<venue>（<title>）」; §67 item 4 (T-040zt): the stop is
                // 「<name>（<place name>）」, so an event named as the stop is not written twice.
                let event = s.event.flatMap { $0.title == s.title ? nil : "（\($0.title)）" } ?? ""
                return (s.role == .hotel ? "住" : "") + s.label + missing + event
            }
            // §64 item 1: with a start date, 「第1天 · 11月25日 周三」.
            return TripDayLabel.text(day: d, asked: plan.asked) + "：" + (names.isEmpty ? "（空）" : names.joined(separator: "、"))
        }.joined(separator: "\n")
    }
}
