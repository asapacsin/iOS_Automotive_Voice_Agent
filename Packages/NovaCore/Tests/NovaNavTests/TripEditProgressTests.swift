import NovaKit
@testable import NovaNav
import NovaPorts
@testable import NovaTools
import Synchronization
import Testing

@Suite("T-040zk F-15b §58 item 5 progress on screen for every trip write")
struct TripEditProgressTests {
    @Test("T-040zk F-15b row 257: an edit shows 正在改行程 / 正在找<名字>; ok: 已加入<名字> 3 s with the card; refused: 没保存：<line> (§61 item 5) with the cards unchanged")
    func row257() async {
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]))
        let clock = ManualClock()
        let board = WorkProgressBoard(clock: clock)
        await rig.planner.setWork(board)
        _ = await settle(rig, await rig.run(planCall(["places": names(["古文化街", "五大道", "天津之眼", "瓷房子"])])))
        let kept: [JSONValue] = await rig.planner.currentPlan.days[0].stops.map { ["id": .string($0.id)] }
        // The edit: the kept stops plus a new name, looked up slowly.
        let edit = Task { await rig.run(trip("set_trip_plan", ["days": .array([.array(kept + [["name": "南开大学"]])])])) }
        for _ in 0..<2000 where rig.search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        clock.advance(by: .milliseconds(1_200))
        let titles = board.panel?.steps.map(\.title) ?? []
        #expect(titles.first == "正在改行程" && titles.last == "正在找南开大学", "\(titles)")
        rig.search.release()
        let r = await edit.value
        #expect(r.ok && r.data["saved"] == true, "\(r)")
        #expect(board.panel?.steps.last?.title == "已加入南开大学" && board.panel?.steps.last?.state == .done)
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.place.name).contains("南开大学"))
        clock.advance(by: .milliseconds(2_900))
        #expect(board.panel != nil)
        clock.advance(by: .milliseconds(200))
        #expect(board.panel == nil)
        // A refused edit: the cards stay as they were; the first problem shows at once, for 5 s.
        let before = await rig.planner.currentPlan
        let bad = await rig.run(trip("set_trip_plan", ["days": .array([.array([["id": kept[0]["id"]!, "role": "museum"]])])]))
        #expect(bad.code == .invalidFields)
        #expect(await rig.planner.currentPlan == before)
        let last = board.panel?.steps.last
        #expect(last?.title == "没保存：第1天第1个地点：role 只能是 start、sight、hotel、end、rental_pickup、rental_return" && last?.state == .failed,
                "\(String(describing: board.panel))")
        clock.advance(by: .milliseconds(4_900))
        #expect(board.panel != nil)
        clock.advance(by: .milliseconds(200))
        #expect(board.panel == nil)
        let lines = rig.lines.withLock { $0 }
        #expect(lines.contains("work step=trip_edit state=running") && lines.contains("work step=trip_edit state=saved")
                && lines.contains("work step=trip_edit state=refused"))
        // The dispatcher lets such a call through to its executor (which refuses it the same way, above).
        var d = ToolDispatcher()
        let call = trip("set_trip_plan", ["days": .array([.array([["id": "s1", "role": "museum"]])])])
        guard case .execute = d.decide(call, context: GuardContext(turn: 1)) else { Issue.record("refused"); return }
    }
}
