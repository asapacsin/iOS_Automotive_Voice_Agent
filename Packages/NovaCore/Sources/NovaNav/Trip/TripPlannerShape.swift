import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §62 (T-040zo): the planner model's plan shape, its prompt texts and the counts message code sends back every
/// round. Pure: no network, no clock. The loop that uses them is `TripPlanner.planTrip`.
public enum TripPlannerShape {
    public struct Sight: Sendable, Hashable {
        public var name: String
        /// The real city of the place (never a province); nil when the planner left it out.
        public var city: String?
        public var minutes: Int?
        public init(name: String, city: String? = nil, minutes: Int? = nil) {
            self.name = name
            self.city = city
            self.minutes = minutes
        }
    }

    public struct Stay: Sendable, Hashable {
        public var name: String
        public var city: String?
        public init(name: String, city: String? = nil) {
            self.name = name
            self.city = city
        }
    }

    public struct Day: Sendable, Hashable {
        public var sights: [Sight]
        /// That night's place; nil on the last day.
        public var stay: Stay?
        public init(sights: [Sight], stay: Stay? = nil) {
            self.sights = sights
            self.stay = stay
        }
    }

    /// §62 item 2: `{"days": [{"sights": [{name, city, minutes}], "stay": {name, city} | null}], "done", "note"}`.
    public struct Plan: Sendable, Hashable {
        public var days: [Day]
        public var done: Bool
        public var note: String
        public init(days: [Day], done: Bool, note: String = "") {
            self.days = days
            self.done = done
            self.note = note
        }

        /// The stop count (sights and stays) for the record line.
        public var stopCount: Int { days.reduce(0) { $0 + $1.sights.count + ($1.stay == nil ? 0 : 1) } }

        public var json: JSONValue {
            .object([
                "days": .array(days.map { d in
                    .object([
                        "sights": .array(d.sights.map { s in
                            var o: [String: JSONValue] = ["name": .string(s.name)]
                            if let c = s.city { o["city"] = .string(c) }
                            if let m = s.minutes { o["minutes"] = .int(Int64(m)) }
                            return .object(o)
                        }),
                        "stay": d.stay.map { s in
                            var o: [String: JSONValue] = ["name": .string(s.name)]
                            if let c = s.city { o["city"] = .string(c) }
                            return .object(o)
                        } ?? .null,
                    ])
                }),
                "done": .bool(done),
                "note": .string(note),
            ])
        }
    }

    // MARK: Parsing

    /// The planner's answer: one JSON object in item 2's shape (a ```json fence around it is taken off). nil when it
    /// is not JSON or has no `days` array (§62 item 7: "not JSON").
    public static func parse(_ text: String) -> Plan? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = String(body.drop { $0 != "\n" }.dropFirst())
            if let end = body.range(of: "```", options: .backwards) { body = String(body[..<end.lowerBound]) }
        }
        guard let data = body.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value, case .array(let days)? = value["days"] else { return nil }
        func string(_ v: JSONValue?) -> String? {
            guard let s = v?.stringValue.map(TranscriptText.normalize), !s.isEmpty else { return nil }
            return s
        }
        let parsed: [Day] = days.compactMap { day -> Day? in
            guard case .object = day else { return nil }
            var sights: [Sight] = []
            if case .array(let list)? = day["sights"] {
                for s in list {
                    guard let name = string(s["name"]) else { continue }
                    let minutes: Int? = switch s["minutes"] {
                    case .int(let m)?: TripStop.clampMinutes(Int(m))
                    case .double(let m)? where m.isFinite: TripStop.clampMinutes(Int(m.rounded()))
                    default: nil
                    }
                    sights.append(Sight(name: name, city: string(s["city"]), minutes: minutes))
                }
            }
            let stay = string(day["stay"]?["name"]).map { Stay(name: $0, city: string(day["stay"]?["city"])) }
            return Day(sights: sights, stay: stay)
        }
        return Plan(days: Array(parsed.prefix(TripPlan.maxDays)), done: value["done"]?.boolValue ?? false,
                    note: value["note"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }

    // MARK: Prompt texts (§62 item 3)

    /// §62 item 3: the planner's system text as used in the PoC, plus §61 item 3a's line for a named place not found.
    public static let system = """
    你是行程规划师。司机的要求由语音助手转给你，你只输出 JSON，不要其他文字。JSON 格式：{"days": [ {"sights": [{"name": "地点全名", "city": "所在城市", "minutes": 停留分钟}], "stay": {"name": "当晚住的地方全名", "city": "城市"} 或 null } ], "done": true/false, "note": "给司机的一句话：没做到的要说"}
    要求：
    - 天数按司机说的；司机点名的地点必须放进去。
    - 每天一般 3 到 4 个景点，景点时间加开车时间一天 6 到 8 小时；整天的地方（主题乐园、度假村玩一整天）可以单独一天。
    - 每晚写 stay；度假村、酒店式景区本身能住，就直接住那里，不要再加别的酒店。最后一天 stay 写 null。
    - 地点写能在地图上搜到的全名，city 写它真正所在的城市。
    - 每次你会收到程序核对的数字（地图找到的地点、开车时间、每天总时间）。按这些数字自己判断合不合理，不合理就改好整份再输出，done=false；都合理了输出最终行程，done=true。
    - 司机点名的地点没找到，不要换掉或去掉，留着，在 note 里说没找到。
    """

    /// §62 item 3: a new plan's user message: 「司机说：「<asked.text>」」 with `asked` as JSON.
    public static func newRequest(_ asked: TripAsked) -> String {
        "司机说：「\(asked.text)」\nasked: " + TripPlanJSON.text(asked.json)
    }

    /// §62 items 2-3: a change: the current plan in item 2's shape (with each stop's lookup facts), `asked` and
    /// 「司机要改：「<change>」」.
    public static func changeRequest(plan: JSONValue, asked: TripAsked?, change: String) -> String {
        var lines = ["现在的行程：" + TripPlanJSON.text(plan)]
        if let asked { lines.append("asked: " + TripPlanJSON.text(asked.json)) }
        lines.append("司机要改：「\(change)」")
        return lines.joined(separator: "\n")
    }

    /// §62 item 2: a saved plan in the planner's shape: each day's sights (every stop that is not a night's hotel, a
    /// start or an end) and its stay (the day's closing hotel; the last day none), each with `地图`, the lookup fact:
    /// 「<found name>·<city><district>」 or 「没找到」.
    public static func shape(_ plan: TripPlan) -> JSONValue {
        func fact(_ s: TripStop) -> JSONValue {
            guard s.placed else { return "没找到" }
            return .string(s.place.name + "·" + (s.place.city ?? "") + (s.place.district ?? ""))
        }
        func city(_ s: TripStop) -> JSONValue { (s.place.city ?? plan.city).map(JSONValue.string) ?? .null }
        let count = plan.days.count
        return .object(["days": .array(plan.days.enumerated().map { d, day in
            let stops = day.stops
            let closing = d < count - 1 ? stops.last.flatMap { $0.role == .hotel ? $0 : nil } : nil
            var sights: [JSONValue] = []
            for (i, s) in stops.enumerated() {
                if s.role == .hotel, i == 0 || (closing != nil && i == stops.count - 1) {
                    // §63 (T-040zp): a hotel merged with its sight is shown to the planner in its own shape again.
                    if s.visitMinutes > 0 {
                        sights.append(.object(["name": .string(s.asked.isEmpty ? s.place.name : s.asked), "city": city(s),
                                               "minutes": .int(Int64(s.visitMinutes)), "地图": fact(s)]))
                    }
                    continue
                }
                if s.role == .start || s.role == .end { continue }
                sights.append(.object(["name": .string(s.asked.isEmpty ? s.place.name : s.asked), "city": city(s),
                                       "minutes": .int(Int64(s.visitMinutes)), "地图": fact(s)]))
            }
            let stay: JSONValue = closing.map {
                .object(["name": .string($0.asked.isEmpty ? $0.place.name : $0.asked), "city": city($0), "地图": fact($0)])
            } ?? .null
            return .object(["sights": .array(sights), "stay": stay])
        })])
    }

    // MARK: Counts (§62 item 4)

    /// One stop as code found it.
    public struct StopCount: Sendable, Hashable {
        public var name: String
        public var found: Place?
        public var minutes: Int
        public var isStay: Bool
        /// Where the lookup searched (for a miss).
        public var range: String
        public init(name: String, found: Place?, minutes: Int, isStay: Bool, range: String) {
            self.name = name
            self.found = found
            self.minutes = minutes
            self.isStay = isStay
            self.range = range
        }
    }

    /// One day's numbers: driving per leg in minutes (nil: unknown, a stop not found or no time).
    public struct DayCount: Sendable, Hashable {
        public var stops: [StopCount]
        public var legs: [Int?]
        public var budget: Int
        public init(stops: [StopCount], legs: [Int?], budget: Int) {
            self.stops = stops
            self.legs = legs
            self.budget = budget
        }
        /// §63 item 2: a stay merged with its sight (minutes > 0) is also that sight.
        public var sights: Int { stops.filter { !$0.isStay || $0.minutes > 0 }.count }
        /// §63 item 2: a stay merged with its sight counts that sight's minutes once.
        public var sightMinutes: Int { stops.reduce(0) { $0 + $1.minutes } }
        public var driving: Int { legs.reduce(0) { $0 + ($1 ?? 0) } }
        public var total: Int { sightMinutes + driving }
    }

    /// §62 item 4: the closing line of every counts message.
    public static let countsClose = "（只有数字，怎么改你决定。）"

    /// §62 item 4: one line per day, then `countsClose`. Numbers and lookup facts only: no thresholds, no verdict,
    /// no advice words.
    public static func countsText(_ days: [DayCount]) -> String {
        var lines: [String] = []
        for (d, day) in days.enumerated() {
            let legs = day.legs.map { $0.map(String.init) ?? "未知" }.joined(separator: ",")
            var line = "第\(d + 1)天：\(day.sights)个景点；景点\(day.sightMinutes)分＋开车\(day.driving)分（各段[\(legs)]）＝\(day.total)分，预算\(day.budget)分。"
            line += day.stops.map { s in
                let head = (s.isStay ? "住" : "") + s.name
                guard let p = s.found else { return head + "=地图没找到（在\(s.range)找）" }
                let at = head + "=地图:" + p.name + "·" + (p.city ?? "") + (p.district ?? "")
                return s.isStay && s.minutes == 0 ? at : at + "，停\(s.minutes)分"
            }.joined(separator: "；")
            lines.append(line)
        }
        lines.append(countsClose)
        return lines.joined(separator: "\n")
    }

    /// §62 item 4 with §61 item 2: words the counts never carry (advice or a verdict).
    public static let adviceWords = ["换", "去掉", "加", "挪", "太满", "考虑"]

    // MARK: Results (§62 items 6-7)

    /// §62 item 6: the `next` of a saved `plan_trip` result, exactly as §62 gives it.
    public static let savedNext = "行程已经存上了。照 plan_text 跟司机说，一两句：每天去哪、住哪。note 里没做到的要说，问司机怎么办。plan 里没有的不要说有。"
    /// §62 item 7: the `next` of `PLANNER_FAILED`, exactly as §62 gives it.
    public static let failedNext = "规划没做成，跟司机说现在规划不了，等一下再试。不要说网络有问题。"

    /// §62 item 12: the handoff line the app says itself at every `plan_trip` dispatch (`ToolCatalog`, so the agent
    /// core says it without the trip module).
    public static func handoffLine(_ call: ToolCall) -> String { ToolCatalog.planTripHandoffLine(call) }

    /// §62 item 5: at most this many planner rounds.
    public static let maxRounds = 3
}
