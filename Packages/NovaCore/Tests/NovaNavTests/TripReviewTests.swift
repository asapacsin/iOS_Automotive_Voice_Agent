import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §61 (T-040zn): `set_trip_plan` saves and reports; `check_trip_plan` counts; the driver's request (`asked`) is
/// saved with the plan; she reviews her own plan. A planner on the Tianjin table with a driver-turn counter.
private struct ReviewRig {
    let planner: TripPlanner
    let lines = TripLines()
    let turn = TurnCount()
    let board: WorkProgressBoard
    let clock = ManualClock()
    init() async {
        let lines = self.lines
        let clock = self.clock
        let search = TripSearch(tianjin)
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        let turn = self.turn
        planner = TripPlanner(search: search, navigation: nav, origin: { GeoCoordinate(latitude: 39.1, longitude: 117.2, datum: .gcj02) },
                              clock: clock, onLine: { lines.append($0) }, driverTurns: { turn.value.withLock { $0 } })
        board = WorkProgressBoard(clock: clock)
        await planner.setWork(board)
        await planner.connectCards()
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func driverSpeaks() { turn.value.withLock { $0 += 1 } }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

private final class TurnCount: Sendable { let value = Mutex(1) }

private func named(_ n: String, role: String? = nil, minutes: Int? = nil) -> JSONValue {
    var o: [String: JSONValue] = ["name": .string(n)]
    if let role { o["role"] = .string(role) }
    if let minutes { o["minutes"] = .int(Int64(minutes)) }
    return .object(o)
}
private func ids(_ planner: TripPlanner) async -> [String: String] {
    var out: [String: String] = [:]
    for s in await planner.currentPlan.allStops { out[s.stop.place.name] = s.stop.id }
    return out
}
private func byID(_ id: String?) -> JSONValue { ["id": .string(id ?? "")] }
private func days(_ d: [[JSONValue]]) -> JSONValue { .array(d.map { .array($0) }) }
private func strings(_ v: JSONValue?) -> [String] {
    guard case .array(let a)? = v else { return [] }
    return a.compactMap(\.stringValue)
}
private let asked: JSONValue = ["text": "天津两天，要去古文化街", "must": ["古文化街"], "days": 2, "city": "天津", "notes": ["别太累"]]

/// §61 item 6: words that decide for her or claim the trip is done; none of the texts code writes may hold them.
private let doneWords = ["改好", "规划好", "安排好", "完成", "成功"]
private let adviceWords = ["换", "去掉", "加", "挪", "太满", "考虑"]

@Suite("T-040zn F-15b §61 the model checks its own plan; code counts, never judges")
struct TripReviewTests {
    @Test("T-040zn F-15b row 268: a saved plan that would fail every old check: saved=true, no issues, no trip_needs_fix, next is item 3a's text; no trip text claims done")
    func row268() async {
        let rig = await ReviewRig()
        // Day 1 over-full (6 long sights), day 2 empty, a not-found name, no hotel for night 1.
        let r = await rig.run(rawTrip("set_trip_plan", [
            "days": days([["古文化街", "五大道", "天津之眼", "瓷房子", "意式风情区", "九龙湖公主酒店"].map { named($0, minutes: 300) }, []]),
            "city": "天津", "asked": asked,
        ]))
        #expect(r.ok && r.data["saved"] == true && r.data["status"] == "trip_list", "\(r)")
        #expect(r.data["issues"] == nil && r.data["round"] == nil && r.data["facts"]?["ready"] == nil)
        #expect(r.data["next"]?.stringValue == TripPlanner.reviewNext)
        let notPlaced = strings(r.data["facts"]?["not_placed"])
        #expect(notPlaced.contains("九龙湖公主酒店"))
        #expect(r.data["facts"]?["not_placed_range"] == "天津")
        #expect(rig.line("trip check round=").isEmpty)
        // Fixture over every text code writes for a trip result and the trip panel (the review `next` and the catalog
        // sentence are §61's own texts and ask her to fix her plan, so they are not claims and are not in it).
        let texts = [WorkProgress.tripUpdated, WorkProgress.tripNotSaved("x"), WorkProgress.tripChecking, WorkProgress.tripEdit,
                     WorkProgress.tripAdded(["x"]), TripPlanner.stopRevisingNext, TripPlanner.askedMissing,
                     r.data["plan_text"]?.stringValue ?? "", r.data["status"]?.stringValue ?? ""]
        for t in texts { #expect(!doneWords.contains { t.contains($0) }, "\(t)") }
    }

    @Test("T-040zn F-15b row 269: a refused set_trip_plan (PLAN_CHECK): saved=false, ok=false; panel 没保存：<line>")
    func row269() async {
        let rig = await ReviewRig()
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[named("古文化街"), named("五大道")]]), "city": "天津", "asked": asked]))
        let id = await ids(rig.planner)
        let r = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), ["id": .string(id["五大道"]!), "role": "start"]]])]))
        #expect(!r.ok && r.code == .planCheck && r.data["saved"] == false, "\(r)")
        let last = rig.board.panel?.steps.last
        #expect(last?.title == "没保存：出发点（start）最多一个，而且要是第一天第一个" && last?.state == .failed, "\(String(describing: rig.board.panel))")
        #expect(rig.line("work step=trip_edit state=refused").count == 1)
        #expect(rig.line("trip set ").last?.contains(" saved=no ") == true)
    }

    @Test("T-040zn F-15b row 270: check_trip_plan on a 2-day plan, then a draft: per-day numbers, not_found with the range; the draft is not saved; no advice words")
    func row270() async {
        let rig = await ReviewRig()
        _ = await rig.run(rawTrip("set_trip_plan", [
            "days": days([[named("古文化街", minutes: 90), named("五大道", minutes: 120), named("某酒店", role: "hotel")],
                          [named("某酒店", role: "hotel"), named("天津之眼", minutes: 60)]]),
            "city": "天津", "asked": asked,
        ]))
        let plan = await rig.planner.currentPlan
        let c = await rig.run(rawTrip("check_trip_plan"))
        #expect(c.ok && c.data["status"] == "trip_check" && c.data["draft"] == false, "\(c)")
        guard case .array(let perDay)? = c.data["days"] else { Issue.record("no days"); return }
        #expect(perDay.count == 2)
        for (d, day) in plan.days.enumerated() {
            let v = perDay[d]
            #expect(v["total_minutes"] == .int(Int64(TripPlanner.dayMinutes(day))))
            #expect(v["sight_minutes"] == .int(Int64(day.stops.reduce(0) { $0 + $1.visitMinutes })))
            #expect(v["budget_minutes"] == .int(Int64(plan.budgetMinutes ?? TripFitter.Pace.normal.budgetMinutes)))
        }
        #expect(perDay[0]["hotel"] == "某酒店" || perDay[0]["hotel"] == .null)
        // 某酒店 is not in the table: not found, with the range searched; its legs are not counted.
        #expect(c.data["not_found"] == .array([["name": "某酒店", "searched": "天津"]]), "\(c)")
        #expect(strings(c.data["unknown_driving"]).contains("第1天：五大道→某酒店"))
        // A draft: looked up, counted, never saved; the cards are unchanged.
        let id = await ids(rig.planner)
        let draft = await rig.run(rawTrip("check_trip_plan", ["days": days([[byID(id["古文化街"]), named("瓷房子", minutes: 45)]])]))
        #expect(draft.ok && draft.data["draft"] == true, "\(draft)")
        if case .array(let dd)? = draft.data["days"] { #expect(dd.count == 1 && "\(dd[0])".contains("瓷房子")) }
        #expect(await rig.planner.currentPlan == plan)
        // Numbers only: no verdict or advice anywhere in the result.
        for r in [c, draft] {
            let text = TripPlanJSON.text(.object(r.data.filter { $0.key != "plan" }))
            #expect(!adviceWords.contains { text.contains($0) } && !doneWords.contains { text.contains($0) }, "\(text)")
        }
        #expect(rig.line("trip check-call draft=no days=2 not_found=1 unknown_driving=").count == 1, "\(rig.lines.withLock { $0 })")
        #expect(rig.line("trip check-call draft=yes days=1 not_found=0 unknown_driving=0 ms=").count == 1)
        // Validation: only `days`.
        #expect(ToolCatalog.validate(rawTrip("check_trip_plan", ["x": 1])) == .invalidFields)
        #expect(ToolCatalog.validate(rawTrip("check_trip_plan")) == nil)
        #expect(ToolCatalog.checkTripPlanDescription.hasPrefix("核对行程：") && ToolCatalog.spec("check_trip_plan") != nil)
    }

    @Test("T-040zn F-15b row 271: one driver request, three writes, X dropped in write 2: write 3's removed lists X; new driver words start removed empty")
    func row271() async {
        let rig = await ReviewRig()
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[named("古文化街"), named("五大道"), named("天津之眼")]]), "city": "天津", "asked": asked]))
        rig.driverSpeaks()
        let id = await ids(rig.planner)
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), byID(id["五大道"]), byID(id["天津之眼"]), named("瓷房子")]])]))
        let w2 = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), byID(id["天津之眼"])]])]))
        #expect(strings(w2.data["facts"]?["removed"]) == ["五大道"], "\(w2)")
        // Write 3 drops nothing more; X (五大道) is still named.
        let w3 = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), byID(id["天津之眼"])]])]))
        #expect(strings(w3.data["facts"]?["removed"]) == ["五大道"], "\(w3)")
        rig.driverSpeaks()
        let w4 = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), byID(id["天津之眼"])]])]))
        #expect(w4.data["facts"]?["removed"] == nil, "\(w4)")
    }

    @Test("T-040zn F-15b row 272: record lines: trip_edit state=saved|refused, trip set saved=, trip check-call, trip asked")
    func row272() async {
        let rig = await ReviewRig()
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[named("古文化街"), named("五大道")]]), "city": "天津", "asked": asked]))
        let id = await ids(rig.planner)
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"])]])]))
        _ = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), ["id": .string(id["古文化街"]!), "role": "end"], byID("s99")]])]))
        _ = await rig.run(rawTrip("check_trip_plan"))
        let lines = rig.lines.withLock { $0 }
        #expect(lines.contains("work step=trip_edit state=saved") && lines.contains("work step=trip_edit state=refused"), "\(lines)")
        #expect(!lines.contains { $0.contains("state=done") || $0.contains("state=failed") || $0.contains("needs_fix") })
        let sets = rig.line("trip set ")
        #expect(sets.count == 3 && sets.allSatisfy { !$0.contains("check=") && !$0.contains("issues=") && !$0.contains("round=") })
        #expect(sets.filter { $0.contains(" saved=yes ") }.count == 2 && sets.filter { $0.contains(" saved=no ") }.count == 1)
        #expect(rig.line("trip asked must=1 days=2 notes=1").count == 1)
        #expect(rig.line("trip check-call draft=no days=1 ").count == 1)
        #expect(lines.contains("work step=trip_check state=running"))
    }

    @Test("T-040zn F-15b row 275: plan_text one line per day, names in order, 「（没找到）」 on unplaced stops; next is the review text; from the 3rd save in one request, stop revising")
    func row275() async {
        let rig = await ReviewRig()
        let r = await rig.run(rawTrip("set_trip_plan", [
            "days": days([[named("古文化街"), named("五大道"), named("某酒店", role: "hotel")], [named("某酒店", role: "hotel"), named("天津之眼")], []]),
            "city": "天津", "asked": asked,
        ]))
        #expect(r.data["plan_text"] == "第1天：古文化街、五大道、住某酒店（没找到）\n第2天：住某酒店（没找到）、天津之眼\n第3天：（空）", "\(r)")
        #expect(r.data["next"]?.stringValue == TripPlanner.reviewNext)
        #expect(r.data["plan"] != nil)
        let id = await ids(rig.planner)
        let same: ToolCall = rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"]), byID(id["五大道"])]])])
        let second = await rig.run(same)
        #expect(second.data["next"]?.stringValue == TripPlanner.reviewNext)
        let third = await rig.run(same)
        #expect(third.data["next"]?.stringValue == TripPlanner.stopRevisingNext, "\(third)")
        rig.driverSpeaks()
        let fresh = await rig.run(same)
        #expect(fresh.data["next"]?.stringValue == TripPlanner.reviewNext)
    }

    @Test("T-040zn F-15b row 277: new plan without asked refused (PLAN_CHECK naming asked); a change keeps it; a change with asked replaces it; in every result, the 现在 note and saved plans")
    func row277() async {
        let rig = await ReviewRig()
        let first = await rig.run(rawTrip("set_trip_plan", ["days": days([[named("古文化街")]]), "city": "天津"]))
        #expect(!first.ok && first.code == .planCheck, "\(first)")
        let problems = strings(first.data["facts"]?["problems"])
        #expect(problems.contains(TripPlanner.askedMissing))
        #expect(await rig.planner.currentPlan.isEmpty)
        let made = await rig.run(rawTrip("set_trip_plan", ["days": days([[named("古文化街"), named("五大道")]]), "city": "天津", "asked": asked]))
        #expect(made.ok && made.data["asked"] == TripAsked(asked)?.json, "\(made)")
        let id = await ids(rig.planner)
        let kept = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"])]])]))
        #expect(kept.ok && kept.data["asked"]?["text"] == "天津两天，要去古文化街")
        let newer: JSONValue = ["text": "天津两天，要去古文化街和咖啡馆", "must": ["古文化街", "咖啡馆"]]
        let replaced = await rig.run(rawTrip("set_trip_plan", ["days": days([[byID(id["古文化街"])]]), "asked": newer]))
        #expect(replaced.data["asked"]?["must"] == ["古文化街", "咖啡馆"], "\(replaced)")
        // In every trip result (check_trip_plan too), at the top of the plan and in the 现在 note.
        let check = await rig.run(rawTrip("check_trip_plan"))
        #expect(check.data["asked"]?["text"] == "天津两天，要去古文化街和咖啡馆")
        let plan = await rig.planner.currentPlan
        #expect(TripPlanJSON.value(plan)["asked"]?["text"] == "天津两天，要去古文化街和咖啡馆")
        #expect(TripPlanJSON.noteLine(plan)?.contains("\"asked\":{") == true)
        // Saved and reopened (我的行程, and the current-plan file).
        #expect(TripPlanFile.current(from: TripPlanFile.current(plan))?.asked == plan.asked)
        var saved = SavedTripPlans()
        _ = saved.save(plan, as: "天津", at: Date(timeIntervalSince1970: 0))
        #expect(SavedTripPlans(data: saved.data())?.entries.first?.plan.asked == plan.asked)
        var other = TripPlan()
        other.load(plan)
        #expect(other.asked == plan.asked)
        // Validation: asked without text is a shape problem; the schema declares it.
        #expect(ToolCatalog.validate(rawTrip("set_trip_plan", ["days": days([[named("x")]]), "city": "天津", "asked": ["must": ["x"]]])) == .invalidFields)
        #expect(ToolCatalog.spec("set_trip_plan")?.declaration.parametersJSONSchema["properties"]?["asked"]?["type"] == "object")
    }
}
