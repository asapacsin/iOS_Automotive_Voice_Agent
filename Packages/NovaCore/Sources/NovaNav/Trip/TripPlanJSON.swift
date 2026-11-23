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
                    "id": .string(s.id), "name": .string(s.place.name), "role": .string(s.role.rawValue),
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
    public static func planText(_ plan: TripPlan) -> String {
        plan.days.enumerated().map { d, day in
            let names = day.stops.map { s in
                (s.role == .hotel ? "住" : "") + s.place.name + (s.placed ? "" : "（没找到）")
            }
            return "第\(d + 1)天：" + (names.isEmpty ? "（空）" : names.joined(separator: "、"))
        }.joined(separator: "\n")
    }
}
