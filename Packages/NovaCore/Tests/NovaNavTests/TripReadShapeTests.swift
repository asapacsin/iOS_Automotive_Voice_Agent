import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}

private func days(_ d: [[JSONValue]], _ extra: [String: JSONValue] = [:]) -> ToolCall {
    trip("set_trip_plan", ["days": .array(d.map { .array($0) })].merging(extra) { $1 })
}

/// A rig whose plan has sights A–F (one day, 札幌), and their ids.
private func sightsRig() async -> (TripRig, [String: String]) {
    let rig = await TripRig(search: TripSearch(sapporoTable))
    _ = await rig.run(days([["A", "B", "C", "D", "E", "F"].map { ["name": .string($0)] }], ["city": "札幌"]))
    var ids: [String: String] = [:]
    for s in await rig.planner.currentPlan.allStops { ids[s.stop.place.name] = s.stop.id }
    return (rig, ids)
}

/// The refusal the call gets (from its executor since §58 item 5; the same `ToolDispatcher.refusal`), nil when it may run.
private func refusal(_ call: ToolCall) -> ToolResult? {
    ToolCatalog.validate(call).map { ToolDispatcher.refusal(call, $0) }
}

@Suite("T-040zi F-15b §56 what a trip result shows, set_trip_plan accepts; a refusal says what is wrong")
struct TripReadShapeTests {
    @Test("T-040zi F-15b row 237: the plan of a trip result sent back unchanged (every stop with all its shown fields): saved, kept = every stop, no lookup, no INVALID_FIELDS")
    func row237() async {
        let (rig, _) = await sightsRig()
        let shown = await rig.run(trip("trip_plans", ["action": "list"]))
        guard case .object(let plan)? = shown.data["plan"] else { Issue.record("no plan in \(shown)"); return }
        // The whole plan object as the result shows it, every stop with id, name, role, placed, picked_by, minutes.
        #expect(plan.keys.contains("days"))
        let asked = rig.search.asked.withLock { $0 }.count
        let call = ToolCall(id: CallID("t1")!, name: "set_trip_plan", arguments: .object(plan))
        #expect(ToolCatalog.validate(call) == nil)
        let r = await rig.run(call)
        #expect(r.ok && r.code != .invalidFields, "\(r)")
        #expect(r.data["facts"]?["kept"] == .int(6) && r.data["facts"]?["new"] == .int(0))
        #expect(rig.search.asked.withLock { $0 }.count == asked)
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.name) == ["A", "B", "C", "D", "E", "F"])
    }

    @Test("T-040zi F-15b row 238: the record's call (20261123-095148: id stops with name, minutes, role; pace relaxed): accepted, places kept by id, the hotel stops' role applied")
    func row238() async {
        let (rig, ids) = await sightsRig()
        let asked = rig.search.asked.withLock { $0 }.count
        func s(_ n: String, _ role: String, _ minutes: Int) -> JSONValue {
            ["id": .string(ids[n]!), "name": .string(n), "minutes": .int(Int64(minutes)), "role": .string(role)]
        }
        let call = days([[s("A", "sight", 90), s("B", "sight", 120), s("C", "hotel", 0)],
                         [s("C", "hotel", 0), s("D", "sight", 60), s("E", "sight", 90), s("F", "sight", 60)]],
                        ["pace": "relaxed"])
        #expect(refusal(call) == nil)
        let r = await rig.run(call)
        #expect(r.ok && r.code == nil, "\(r)")
        #expect(rig.search.asked.withLock { $0 }.count == asked)
        let plan = await rig.planner.currentPlan
        #expect(plan.days.map { $0.stops.map(\.place.name) } == [["A", "B", "C"], ["C", "D", "E", "F"]])
        #expect(plan.days[0].stops[2].role == .hotel && plan.days[1].stops[0].role == .hotel && plan.days[0].stops[2].id == ids["C"])
        #expect(plan.days[0].stops[1].minutes == 120)
    }

    @Test("T-040zi F-15b row 239: stop {id: s5, name: 另一个名字, role: hotel}: the place of s5 kept, not searched; role set to hotel; name ignored")
    func row239() async {
        let (rig, ids) = await sightsRig()
        let asked = rig.search.asked.withLock { $0 }.count
        let e = ids["E"]!
        let hotel: JSONValue = ["id": .string(e), "name": "另一个名字", "role": "hotel"]
        let r = await rig.run(days([[["id": .string(ids["A"]!)], ["id": .string(ids["B"]!)], hotel],
                                    [hotel, ["id": .string(ids["C"]!)], ["id": .string(ids["D"]!)]]]))
        #expect(r.ok, "\(r)")
        #expect(rig.search.asked.withLock { $0 }.count == asked)
        #expect(!rig.search.asked.withLock { $0 }.contains("另一个名字"))
        let stop = await rig.planner.currentPlan.days[0].stops[2]
        #expect(stop.id == e && stop.place.name == "E" && stop.role == .hotel)
    }

    @Test("T-040zi F-15b row 240: stop {id: s5, minutes: 150} and a stop with an unknown key note: minutes applied; note ignored and listed in ignored_fields")
    func row240() async {
        let (rig, ids) = await sightsRig()
        let call = days([[["id": .string(ids["A"]!), "minutes": 150], ["id": .string(ids["B"]!), "note": "早点去"],
                          ["id": .string(ids["C"]!)], ["id": .string(ids["D"]!)]]])
        #expect(refusal(call) == nil)
        let r = await rig.run(call)
        #expect(r.ok, "\(r)")
        #expect(await rig.planner.currentPlan.days[0].stops[0].minutes == 150)
        #expect(strings(r.data["facts"]?["ignored_fields"]) == ["note"])
        #expect(rig.lines.withLock { $0 }.contains { $0.hasPrefix("trip set days=1 stops=4 kept=4 ") && $0.hasSuffix(" ignored=1") })
    }

    @Test("T-040zi F-15b row 241: role museum; a stop with none of id, name, near; a new plan without city: INVALID_FIELDS with one problems line each, naming day, stop and field; never {}")
    func row241() async {
        let museum = days([[["id": "s1"], ["id": "s2"], ["id": "s3", "role": "museum"]], [["id": "s4"]]])
        let none = days([[["name": "A"], ["name": "B"], ["name": "C"], ["role": "sight", "minutes": 60]]], ["city": "札幌"])
        let noCity = days([[["name": "A"], ["name": "B"]]])
        let cases: [(ToolCall, String)] = [
            (museum, "第1天第3个地点：role 只能是 start、sight、hotel、end、rental_pickup、rental_return"),
            (none, "第1天第4个地点：要写 id、name 或者 near"),
            (noCity, "新行程要写 city（城市，跨城市就写省或地区）"),
        ]
        for (call, line) in cases {
            #expect(ToolCatalog.validate(call) == .invalidFields)
            let r = refusal(call)
            #expect(r?.code == .invalidFields && strings(r?.data["problems"]) == [line], "\(String(describing: r))")
            #expect(r?.data["next"]?.stringValue == "先不要跟司机说话，按 problems 改好整份行程，再调用 set_trip_plan。")
            // The executor's backstop says the same.
            let rig = await TripRig(search: TripSearch(sapporoTable))
            let direct = await rig.run(call)
            #expect(direct.code == .invalidFields && strings(direct.data["problems"]) == [line], "\(direct)")
        }
        // Every refusal of the tool carries its lines: near off a hotel, a too-long id, minutes out of range, bad pace.
        let more = days([[["near": "北京路"], ["id": "s1234567890123"], ["id": "s2", "minutes": 721]]], ["pace": "slow"])
        #expect(strings(refusal(more)?.data["problems"]) == ["第1天第1个地点：near 只能用在酒店（role 写 hotel）",
                                                             "第1天第2个地点：id 要是1到12个字", "第1天第3个地点：minutes 要是0到720的整数",
                                                             "pace 只能是 relaxed、normal、packed"])
        #expect(strings(refusal(trip("set_trip_plan", ["days": .array([])]))?.data["problems"]) == ["days 要写1到5天，每天是一组地点"])
    }

    @Test("T-040zi F-15b row 242: the same refused call twice in one driver request: REPEATED_FAILURE with the earlier problems, not run; a changed call runs")
    func row242() {
        var d = ToolDispatcher()
        let bad = days([[["id": "s1", "role": "museum"]]])
        // §58 item 5 (T-040zk): the call runs into its executor, which refuses it; the refusal is noted.
        guard case .execute = d.decide(bad, context: GuardContext(turn: 3)) else { Issue.record("refused"); return }
        let first = refusal(bad)!
        #expect(first.code == .invalidFields)
        d.noteResult(bad, first)
        guard case .refuse(let second) = d.decide(bad, context: GuardContext(turn: 3)) else { Issue.record("ran"); return }
        #expect(second.code == .repeatedFailure && second.data["problems"] == first.data["problems"])
        #expect(second.data["next"]?.stringValue == "这份行程刚才已经被拒绝了，原因在 problems 里。按它改，改不了就告诉司机行程没改成和原因，不要再传同样的内容。")
        #expect(second.data["refused_code"] == "INVALID_FIELDS")
        // A changed call runs normally.
        let fixed = days([[["id": "s1", "role": "sight"]]])
        guard case .execute = d.decide(fixed, context: GuardContext(turn: 3)) else { Issue.record("refused"); return }
        // A PLAN_CHECK result is remembered too; the same plan again is blocked, in the next request it runs again.
        let check = ToolResult(ok: false, code: .planCheck, data: ["facts": ["problems": ["没有这个 id：s1"]]], advice: nil)
        d.noteResult(fixed, check)
        guard case .refuse(let again) = d.decide(fixed, context: GuardContext(turn: 3)) else { Issue.record("ran"); return }
        #expect(again.code == .repeatedFailure && strings(again.data["problems"]) == ["没有这个 id：s1"] && again.data["refused_code"] == "PLAN_CHECK")
        guard case .execute = d.decide(fixed, context: GuardContext(turn: 4)) else { Issue.record("refused next turn"); return }
        guard case .execute = d.decide(bad, context: GuardContext(turn: 4)) else { Issue.record("blocked next turn"); return }
    }

    @Test("T-040zi F-15b row 243: catalog: set_trip_plan text has the §56 item 5 sentence; agent version bumped")
    func row243() {
        #expect(ToolCatalog.setTripPlanDescription.contains("改行程：把结果里的行程照着改，已有的地点保留 id（其他字段可以照抄），新地点写 name。"))
        #expect(!ToolCatalog.setTripPlanDescription.contains("已有的地点只写 id"))
    }
}
