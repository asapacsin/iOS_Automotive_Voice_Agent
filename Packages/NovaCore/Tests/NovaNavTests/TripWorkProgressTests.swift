import NovaKit
@testable import NovaNav
import NovaPorts
import Synchronization
import Testing

@Suite("T-040w F-15b §50 item 6 trip steps from TripPlanner")
struct TripWorkProgressTests {
    @Test("T-040w row 149: a slow make_trip_list shows 检查地点位置 after 1 s; the cards clear it and log work show=trip")
    func slowMake() async {
        let rig = await TripRig(search: TripSearch(tianjin, slow: ["南开大学"]))
        let clock = ManualClock()
        let lines = Mutex<[String]>([])
        let board = WorkProgressBoard(clock: clock) { line in lines.withLock { $0.append(line) } }
        await rig.planner.setWork(board)
        let made = Task { await rig.run(planCall(["places": names(["天津之眼", "南开大学"])])) }
        for _ in 0..<2000 where rig.search.waiting == 0 { try? await Task.sleep(for: .milliseconds(1)) }
        #expect(board.panel == nil)
        clock.advance(by: .milliseconds(1_200))
        #expect(board.panel?.steps.first?.title == WorkProgress.tripCheck)
        rig.search.release()
        #expect(await made.value.ok)
        #expect(board.panel == nil)
        let logged = lines.withLock { $0 }
        #expect(logged.count == 1)
        #expect(logged.first?.hasPrefix("work show=trip steps=") == true)
    }

    @Test("T-040w row 149: a quick make_trip_list shows nothing and logs no work line")
    func quickMake() async {
        let rig = await TripRig()
        let clock = ManualClock()
        let lines = Mutex<[String]>([])
        let board = WorkProgressBoard(clock: clock) { line in lines.withLock { $0.append(line) } }
        await rig.planner.setWork(board)
        #expect(await rig.run(planCall(["places": names(["古文化街", "五大道"])])).ok)
        clock.advance(by: .seconds(2))
        #expect(board.panel == nil)
        #expect(lines.withLock { $0 }.isEmpty)
    }
}
