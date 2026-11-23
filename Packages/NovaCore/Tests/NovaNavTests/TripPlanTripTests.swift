import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §62 (T-040zo): the voice model hands the request to a planner model (`plan_trip`); the planner writes the plan
/// in its own shape; code looks every stop up with its own city, counts, and sends the numbers back every round; the
/// planner revises; code stops at done (from round 2) or after round 3 and saves.

/// A planner model with scripted answers, one per call; it records what it was sent.
private final class FakePlannerModel: TripPlannerModel, @unchecked Sendable {
    enum Answer { case text(String), fail(Int), hang }
    let answers: Mutex<[Answer]>
    let calls = Mutex<[[TripPlannerMessage]]>([])
    let systems = Mutex<[String]>([])
    init(_ answers: [Answer]) { self.answers = Mutex(answers) }
    var model: String { "fake-planner" }
    func complete(system: String, messages: [TripPlannerMessage]) async throws -> String {
        calls.withLock { $0.append(messages) }
        systems.withLock { $0.append(system) }
        let next = answers.withLock { a -> Answer in a.isEmpty ? .fail(500) : a.removeFirst() }
        switch next {
        case .text(let t): return t
        case .fail(let status): throw TripPlannerModelError.http(status)
        case .hang:
            try await Task.sleep(for: .seconds(3600))
            throw CancellationError()
        }
    }
    var count: Int { calls.withLock { $0.count } }
}

/// 高德 stand-in that records each (name, city) asked and answers by `city|name`, else by name.
private final class PlannerCitySearch: PlaceSearch, @unchecked Sendable {
    let table: [String: Place]
    let asked = Mutex<[String]>([])
    init(_ table: [String: Place]) { self.table = table }
    func text(_ keywords: String, city: String?) async throws -> [Place] {
        asked.withLock { $0.append("\(city ?? "-")|\(keywords)") }
        return (table["\(city ?? "-")|\(keywords)"] ?? table[keywords]).map { [$0] } ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

private func gz(_ name: String, _ lat: Double, district: String = "越秀区") -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: 113.3, datum: .gcj02),
          distanceMeters: nil, city: "广州市", district: district)
}

private let guangzhou: [String: Place] = [
    "广州|广州塔": gz("广州塔", 23.10, district: "海珠区"),
    "广州|陈家祠": gz("陈家祠", 23.13, district: "荔湾区"),
    "广州|沙面岛": gz("沙面岛", 23.11, district: "荔湾区"),
    "广州|越秀公园": gz("越秀公园", 23.14),
    "广州|北京路": gz("北京路", 23.12),
    "广州|九龙湖旅游度假村": gz("九龙湖旅游度假村", 23.45, district: "花都区"),
    "广州|长隆野生动物世界": gz("长隆野生动物世界", 23.00, district: "番禺区"),
    "广州|花园酒店": gz("花园酒店", 23.13),
]

private struct PlanTripRig {
    let planner: TripPlanner
    let model: FakePlannerModel
    let search: PlannerCitySearch
    let lines = TripLines()
    let board: WorkProgressBoard
    let clock = ManualClock()
    init(_ answers: [FakePlannerModel.Answer], table: [String: Place] = guangzhou, times: TripTimes? = nil) async {
        let lines = self.lines
        let clock = self.clock
        let search = PlannerCitySearch(table)
        self.search = search
        let model = FakePlannerModel(answers)
        self.model = model
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { GeoCoordinate(latitude: 23.1, longitude: 113.3, datum: .gcj02) },
                              clock: clock, onLine: { lines.append($0) }, times: times, plannerModel: model)
        board = WorkProgressBoard(clock: clock)
        await planner.setWork(board)
        await planner.connectCards()
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

/// One planner answer in §62 item 2's shape: days of sight names (all in 广州), stays by day, done, note.
private func answer(_ days: [[String]], stays: [String?] = [], done: Bool, note: String = "", minutes: [String: Int] = [:]) -> FakePlannerModel.Answer {
    let d: [JSONValue] = days.enumerated().map { i, names in
        let stay: JSONValue = (i < stays.count ? stays[i] : nil).map { .object(["name": .string($0), "city": "广州"]) } ?? .null
        return .object(["sights": .array(names.map { n in
            .object(["name": .string(n), "city": "广州", "minutes": .int(Int64(minutes[n] ?? 120))])
        }), "stay": stay])
    }
    return .text(TripPlanJSON.text(.object(["days": .array(d), "done": .bool(done), "note": .string(note)])))
}

private let asked: JSONValue = ["text": "帮我安排广州两天，要去陈家祠", "must": ["陈家祠"], "days": 2, "city": "广州"]
private func newPlan() -> ToolCall { rawTrip("plan_trip", ["asked": asked]) }

@Suite("T-040zo F-15b §62 the voice model hands the request to a planner model; code counts, the planner reviews")
struct TripPlanTripTests {
    @Test("T-040zo F-15b row 279: new plan, fake planner: round 1 done=false, round 2 done=true: each stop looked up with its own city; one counts message per round in item 4's form; round 2's plan saved; result fields and item 6's next")
    func row279() async {
        let rig = await PlanTripRig([
            answer([["广州塔", "陈家祠"], ["沙面岛"]], stays: ["花园酒店"], done: false),
            answer([["广州塔", "陈家祠", "越秀公园"], ["沙面岛", "北京路"]], stays: ["花园酒店"], done: true, note: "都安排上了"),
        ])
        let r = await rig.run(newPlan())
        #expect(r.ok && r.data["saved"] == true, "\(r)")
        #expect(r.data["rounds"] == .int(2) && r.data["note"] == "都安排上了")
        #expect(r.data["next"]?.stringValue == TripPlannerShape.savedNext)
        #expect(r.data["asked"]?["text"] == "帮我安排广州两天，要去陈家祠")
        #expect(r.data["plan_text"]?.stringValue == "第1天：广州塔、陈家祠、越秀公园、住花园酒店\n第2天：住花园酒店、沙面岛、北京路")
        #expect(r.data["plan"] != nil && r.data["not_placed"] == nil)
        // Every lookup with the stop's own city (never a province), each name once.
        let asked = rig.search.asked.withLock { $0 }
        #expect(asked.allSatisfy { $0.hasPrefix("广州|") }, "\(asked)")
        #expect(Set(asked).count == asked.count)
        // Round 2 got the request, round 1's plan and one counts message in item 4's form.
        let calls = rig.model.calls.withLock { $0 }
        #expect(calls.count == 2 && calls[1].count == 3)
        #expect(calls[0][0].content.hasPrefix("司机说：「帮我安排广州两天，要去陈家祠」"))
        let counts = calls[1][2].content
        #expect(calls[1][2].role == .user && calls[1][1].role == .assistant)
        let countLines = counts.components(separatedBy: "\n")
        #expect(countLines.count == 3 && countLines[2] == TripPlannerShape.countsClose, "\(counts)")
        #expect(countLines[0].hasPrefix("第1天：2个景点；景点240分＋开车0分（各段[未知,未知]）＝240分，预算480分。"), "\(counts)")
        #expect(countLines[0].contains("广州塔=地图:广州塔·广州市海珠区，停120分") && countLines[0].contains("住花园酒店=地图:花园酒店·广州市越秀区"))
        #expect(countLines[1].hasPrefix("第2天：1个景点；"))
        #expect(rig.model.systems.withLock { $0 }.allSatisfy { $0 == TripPlannerShape.system })
        // The saved plan is round 2's; the driver's request is kept with it.
        let plan = await rig.planner.currentPlan
        #expect(plan.days.map { $0.stops.map(\.place.name) } == [["广州塔", "陈家祠", "越秀公园", "花园酒店"], ["花园酒店", "沙面岛", "北京路"]])
        #expect(plan.asked?.must == ["陈家祠"] && plan.city == "广州")
    }

    @Test("T-040zo F-15b row 279 (driving): the counts carry §48's driving minutes per leg and the day total; the stay-as-sight leg is 0; no 计算开车时间 step on the row")
    func row279Driving() async {
        let times = TripTimes(service: FakeDrivingTimes(byLine), clock: ManualClock(), retryDelay: .milliseconds(1))
        let rig = await PlanTripRig([
            answer([["广州塔", "陈家祠"], ["九龙湖旅游度假村"]], stays: ["九龙湖旅游度假村"], done: false, minutes: ["九龙湖旅游度假村": 300]),
            answer([["广州塔", "陈家祠"], ["九龙湖旅游度假村"]], stays: ["九龙湖旅游度假村"], done: true, minutes: ["九龙湖旅游度假村": 300]),
        ], times: times)
        let r = await rig.run(newPlan())
        #expect(r.ok, "\(r)")
        let counts = rig.model.calls.withLock { $0 }[1][2].content
        // 广州塔 23.10 → 陈家祠 23.13 = 300 s = 5 min; 陈家祠 → 九龙湖 23.45 = 3200 s ≈ 53 min.
        #expect(counts.hasPrefix("第1天：2个景点；景点240分＋开车58分（各段[5,53]）＝298分，预算480分。"), "\(counts)")
        #expect(counts.contains("第2天：1个景点；景点300分＋开车0分（各段[0]）＝300分"), "\(counts)")
        let titles: [String] = rig.board.panel?.steps.map(\.title) ?? []
        let timesShown = titles.contains(WorkProgress.tripTimes)
        #expect(!timesShown && titles.count == 6, "\(titles)")
    }

    @Test("T-040zo F-15b row 280: never done: stops after round 3 and saves round 3's plan; done in round 1: one counts round still sent; no verdict or advice word in any counts message")
    func row280() async {
        let never = await PlanTripRig([
            answer([["广州塔"], ["陈家祠"]], stays: ["花园酒店"], done: false),
            answer([["广州塔", "越秀公园"], ["陈家祠"]], stays: ["花园酒店"], done: false),
            answer([["广州塔", "越秀公园"], ["陈家祠", "沙面岛"]], stays: ["花园酒店"], done: false),
            answer([["北京路"], ["北京路"]], done: true),
        ])
        let r = await never.run(newPlan())
        #expect(r.ok && r.data["rounds"] == .int(3) && never.model.count == 3, "\(r)")
        #expect(await never.planner.currentPlan.allStops.map(\.stop.place.name).contains("沙面岛"))
        let early = await PlanTripRig([
            answer([["广州塔"], ["陈家祠"]], stays: ["花园酒店"], done: true),
            answer([["广州塔", "越秀公园"], ["陈家祠"]], stays: ["花园酒店"], done: true),
        ])
        let e = await early.run(newPlan())
        #expect(e.ok && e.data["rounds"] == .int(2) && early.model.count == 2, "\(e)")
        #expect(await early.planner.currentPlan.allStops.map(\.stop.place.name).contains("越秀公园"))
        // Each rig's last call carries every counts message it was sent.
        let lastNever: [TripPlannerMessage] = never.model.calls.withLock { $0 }.last ?? []
        let lastEarly: [TripPlannerMessage] = early.model.calls.withLock { $0 }.last ?? []
        let counts: [String] = (lastNever + lastEarly).filter { $0.role == .user && $0.content.hasPrefix("第1天") }.map(\.content)
        #expect(counts.count == 3)
        for c in counts {
            for w in TripPlannerShape.adviceWords + ["合理", "不合理", "太赶", "建议"] { #expect(!c.contains(w), "\(w) in \(c)") }
        }
        #expect(never.line("trip planner round=").count == 3 && early.line("trip planner round=").count == 2)
    }

    @Test("T-040zo F-15b row 281: day 2 has sight 九龙湖旅游度假村 and stay 九龙湖旅游度假村: one place, looked up once; that night's hotel is it; day 3 starts there; no other hotel that night")
    func row281() async {
        let rig = await PlanTripRig([
            answer([["广州塔", "陈家祠"], ["九龙湖旅游度假村"], ["沙面岛"]], stays: ["花园酒店", "九龙湖旅游度假村"], done: false,
                   minutes: ["九龙湖旅游度假村": 480]),
            answer([["广州塔", "陈家祠"], ["九龙湖旅游度假村"], ["沙面岛"]], stays: ["花园酒店", "九龙湖旅游度假村"], done: true,
                   minutes: ["九龙湖旅游度假村": 480]),
        ])
        let r = await rig.run(rawTrip("plan_trip", ["asked": ["text": "广州三天，把九龙湖旅游度假村放进去", "must": ["九龙湖旅游度假村"], "days": 3, "city": "广州"]]))
        #expect(r.ok, "\(r)")
        #expect(rig.search.asked.withLock { $0 }.filter { $0.hasSuffix("|九龙湖旅游度假村") }.count == 1)
        let text = r.data["plan_text"]?.stringValue ?? ""
        #expect(text.contains("第2天：住花园酒店、九龙湖旅游度假村、住九龙湖旅游度假村"), "\(text)")
        let plan = await rig.planner.currentPlan
        let day2 = plan.days[1].stops, day3 = plan.days[2].stops
        #expect(day2.last?.role == .hotel && day2.last?.place.id == "九龙湖旅游度假村")
        #expect(day3.first?.role == .hotel && day3.first?.place.id == "九龙湖旅游度假村")
        #expect(day2.filter { $0.role == .hotel }.map(\.place.id) == ["花园酒店", "九龙湖旅游度假村"])
        // The counts give the resort its whole day: one sight of 480 minutes, slept in.
        let counts = rig.model.calls.withLock { $0 }[1][2].content
        #expect(counts.contains("第2天：1个景点；景点480分") && counts.contains("住九龙湖旅游度假村=地图:九龙湖旅游度假村·广州市花都区"), "\(counts)")
    }

    @Test("T-040zo F-15b row 282: planner HTTP error; timeout; not JSON twice: saved=false, PLANNER_FAILED, cards unchanged, item 7's next; no other planner; record failed reason=")
    func row282() async {
        // HTTP error, after a plan is on the cards.
        let http = await PlanTripRig([answer([["广州塔"]], done: true), answer([["广州塔"]], done: true), .fail(503)])
        _ = await http.run(newPlan())
        let before = await http.planner.currentPlan
        let r = await http.run(rawTrip("plan_trip", ["change": "第一天加上陈家祠"]))
        #expect(!r.ok && r.code == .plannerFailed && r.data["saved"] == false, "\(r)")
        #expect(r.data["next"]?.stringValue == TripPlannerShape.failedNext)
        #expect(await http.planner.currentPlan == before)
        #expect(http.line("trip planner failed reason=http").count == 1 && http.model.count == 3)
        // Not JSON twice in a round.
        let json = await PlanTripRig([.text("好的，我来规划"), .text("```\n不是JSON\n```")])
        let j = await json.run(newPlan())
        #expect(j.code == .plannerFailed && json.model.count == 2 && json.line("trip planner failed reason=json").count == 1)
        #expect(await json.planner.currentPlan.isEmpty)
        // Not JSON once, then a plan: the round goes on.
        let once = await PlanTripRig([.text("嗯"), answer([["广州塔"]], done: true), answer([["广州塔"]], done: true)])
        #expect(await once.run(newPlan()).ok)
        // Timeout at 30 s.
        let slow = await PlanTripRig([.hang])
        let task = Task { await slow.run(newPlan()) }
        while slow.model.count == 0 || slow.clock.pendingSleepers == 0 { await Task.yield() }
        slow.clock.advance(by: .seconds(30))
        let t = await task.value
        #expect(t.code == .plannerFailed && slow.line("trip planner failed reason=timeout").count == 1, "\(t)")
        // The panel says it was not saved.
        #expect(slow.board.panel?.line == WorkProgress.tripNotSaved("规划没做成"))
    }

    @Test("T-040zo F-15b row 283: plan_trip with change 第二天去掉沙面 on an open plan: the planner gets the plan in item 2's shape with lookup facts, the saved asked and the change words; saved; removed lists 沙面岛; asked kept")
    func row283() async {
        let rig = await PlanTripRig([
            answer([["广州塔", "陈家祠"], ["沙面岛", "北京路"]], stays: ["花园酒店"], done: true),
            answer([["广州塔", "陈家祠"], ["沙面岛", "北京路"]], stays: ["花园酒店"], done: true),
            answer([["广州塔", "陈家祠"], ["北京路"]], stays: ["花园酒店"], done: true),
            answer([["广州塔", "陈家祠"], ["北京路"]], stays: ["花园酒店"], done: true),
        ])
        #expect(await rig.run(newPlan()).ok)
        let r = await rig.run(rawTrip("plan_trip", ["change": "第二天去掉沙面"]))
        #expect(r.ok && r.data["saved"] == true, "\(r)")
        let first = rig.model.calls.withLock { $0 }[2][0].content
        #expect(first.hasPrefix("现在的行程：{\"days\":[{\"sights\":[{"), "\(first)")
        #expect(first.contains("\"地图\":\"沙面岛·广州市荔湾区\"") && first.contains("\"stay\":{\"city\":\"广州市\",\"name\":\"花园酒店\""))
        #expect(first.contains("asked: {\"city\":\"广州\"") && first.hasSuffix("司机要改：「第二天去掉沙面」"))
        #expect(r.data["removed"] == ["沙面岛"])
        let plan = await rig.planner.currentPlan
        #expect(plan.asked?.text == "帮我安排广州两天，要去陈家祠")
        #expect(!plan.allStops.map(\.stop.place.name).contains("沙面岛"))
        // A change with no plan open is NO_TRIP_LIST; nothing asked.
        let empty = await PlanTripRig([])
        #expect(await empty.run(rawTrip("plan_trip", ["change": "去掉沙面"])).code == .noTripList && empty.model.count == 0)
    }

    @Test("T-040zo F-15b row 285: catalog: plan_trip declared NON_BLOCKING; set_trip_plan absent; check_trip_plan kept; asked and change validated; major agent version")
    func row285() {
        #expect(AsyncTool(name: "plan_trip") == .planTrip && AsyncTool.planTrip.isTrip && AsyncTool(name: "set_trip_plan") == nil)
        #expect(ToolCatalog.spec("set_trip_plan") == nil && ToolCatalog.spec("check_trip_plan") != nil)
        let schema = ToolCatalog.spec("plan_trip")?.declaration.parametersJSONSchema
        #expect(schema?["properties"]?["asked"]?["type"] == "object" && schema?["properties"]?["change"]?["type"] == "string")
        #expect(schema?["properties"]?["days"] == nil)
        #expect(TripPlanner.tools == ["plan_trip", "check_trip_plan", "trip_next", "trip_plans"])
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["asked": asked])) == nil)
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["change": "第二天去掉沙面"])) == nil)
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["change": "去掉沙面", "asked": asked])) == nil)
        #expect(ToolCatalog.validate(rawTrip("plan_trip")) == .invalidFields)
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["days": [[["name": "x"]]]])) == .invalidFields)
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["asked": ["must": ["x"]]])) == .invalidFields)
        #expect(ToolCatalog.validate(rawTrip("plan_trip", ["change": "  "])) == .invalidFields)
        // Her text: no working line of her own (item 12), the handoff sentence instead.
        #expect(ToolCatalog.planTripDescription.contains(ToolCatalog.planTripHandoff))
        #expect(!ToolCatalog.planTripDescription.contains("先只说一句"))
        // The panel registry: plan_trip opens and acts on the trip screen.
        #expect(PanelRegistry.entry(.tripScreen).opens.contains("plan_trip"))
        #expect(!PanelRegistry.entry(.tripScreen).acts.contains("set_trip_plan"))
    }

    @Test("T-040zo F-15b row 288: the record has trip planner round=… model= per round and the planner and counts texts (local record)")
    func row288() async {
        let rig = await PlanTripRig([answer([["广州塔"]], done: false), answer([["广州塔", "陈家祠"]], done: true)])
        _ = await rig.run(newPlan())
        let rounds = rig.line("trip planner round=")
        #expect(rounds.count == 2 && rounds.allSatisfy { $0.contains(" model=fake-planner") })
        #expect(rounds[0].contains(" done=no days=1 stops=1 ") && rounds[1].contains(" done=yes days=1 stops=2 "))
        #expect(rig.line("trip planner text plan=").count == 2 && rig.line("trip planner text counts=第1天：").count == 2)
        #expect(rig.line("trip planner saved rounds=2 ").count == 1)
    }

    @Test("T-040zo F-15b rows 289-290 (core): the spinner row: 已交给规划助手 at once, its text following each step, the result line last; it stays when the trip screen closes; search tools show 正在查：…")
    func row289() async {
        let rig = await PlanTripRig([answer([["广州塔"]], done: false), answer([["广州塔", "陈家祠"]], done: true)])
        let r = await rig.run(newPlan())
        #expect(r.ok)
        let panel = rig.board.panel
        #expect(panel?.kind == .handoff && panel?.spinning == false && panel?.line == WorkProgress.tripUpdated)
        #expect(panel?.steps.map(\.title) == ["已交给规划助手", "正在规划行程", "正在核对路线（第1轮）", "正在修改行程（第2轮）",
                                             "正在核对路线（第2轮）", "行程已更新"])
        // A running row: shown at once (no 1 s wait), spinning, with the current step.
        let board = WorkProgressBoard(clock: rig.clock)
        board.start(.handoff, step: WorkProgress.handedOver, immediate: true)
        #expect(board.panel?.line == "已交给规划助手" && board.panel?.spinning == true)
        // Row 290: the trip screen closing does not take it away.
        board.tripScreen(on: false)
        #expect(board.panel?.line == "已交给规划助手")
        board.step(WorkProgress.tripCounting(1))
        #expect(board.panel?.line == "正在核对路线（第1轮）")
        // A search shows the same row with 正在查：<query>.
        board.start(.search, step: WorkProgress.lookingUp("广州天气"), immediate: true)
        #expect(board.panel?.line == "正在查：广州天气" && board.panel?.spinning == true)
        // The handoff lines the app says (item 12).
        #expect(TripPlannerShape.handoffLine(rawTrip("plan_trip", ["asked": asked])) == "好，我交给规划助手了，大概半分钟，好了告诉你。")
        #expect(TripPlannerShape.handoffLine(rawTrip("plan_trip", ["change": "去掉沙面"])) == "好，我交给规划助手改行程，好了告诉你。")
    }

    @Test("T-040zo F-15b §62 items 2-3: the planner's shape parses (fenced too); the system text is item 3's plus the not-found line; a not-found named place is listed with its range")
    func shape() async {
        let parsed = TripPlannerShape.parse("```json\n{\"days\":[{\"sights\":[{\"name\":\"广州塔\",\"city\":\"广州\",\"minutes\":90.4}],\"stay\":null}],\"done\":true,\"note\":\"x\"}\n```")
        #expect(parsed == TripPlannerShape.Plan(days: [.init(sights: [.init(name: "广州塔", city: "广州", minutes: 90)])], done: true, note: "x"))
        #expect(TripPlannerShape.parse("{\"plan\":1}") == nil && TripPlannerShape.parse("不是") == nil)
        #expect(TripPlannerShape.system.hasPrefix("你是行程规划师。司机的要求由语音助手转给你，你只输出 JSON，不要其他文字。"))
        #expect(TripPlannerShape.system.hasSuffix("- 司机点名的地点没找到，不要换掉或去掉，留着，在 note 里说没找到。"))
        let rig = await PlanTripRig([answer([["广州塔", "九龙湖公主酒店"]], done: false), answer([["广州塔", "九龙湖公主酒店"]], done: true, note: "九龙湖公主酒店没找到")])
        let r = await rig.run(newPlan())
        #expect(r.ok && r.data["not_placed"] == [["name": "九龙湖公主酒店", "searched": "广州"]], "\(r)")
        #expect(r.data["plan_text"]?.stringValue == "第1天：广州塔、九龙湖公主酒店（没找到）")
        #expect(rig.model.calls.withLock { $0 }[1][2].content.contains("九龙湖公主酒店=地图没找到（在广州找）"))
    }
}
