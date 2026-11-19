import NovaKit
import Synchronization
import Testing

@Suite("T-040w F-15b §50 item 6 steps on screen")
struct WorkProgressTests {
    private func t(_ ms: Int64) -> NovaInstant { NovaInstant(milliseconds: ms) }

    @Test("T-040w row 149: trip steps finishing at 0.4 s show nothing and log nothing")
    func row149Quick() {
        var w = WorkProgress()
        w.start(.trip, at: t(0))
        w.step(WorkProgress.tripFind, at: t(0))
        w.step(WorkProgress.tripCheck, at: t(200))
        #expect(w.panel(at: t(300)) == nil)
        #expect(w.clear(at: t(400)) == nil)
        #expect(w.panel(at: t(1_500)) == nil)
    }

    @Test("T-040w row 149: 6 s of steps with a failed 检查地点位置: panel after 1 s with the line, cleared by the cards")
    func row149Slow() {
        var w = WorkProgress()
        w.start(.trip, at: t(0))
        w.step(WorkProgress.tripFind, at: t(0))
        #expect(w.panel(at: t(999)) == nil)
        #expect(w.panel(at: t(1_000))?.steps.map(\.title) == [WorkProgress.tripFind])
        w.step(WorkProgress.tripCheck, at: t(2_000))
        w.fail(WorkProgress.outOfArea(1), at: t(3_000))
        let failed = w.panel(at: t(3_500))
        #expect(failed?.failure == "1 个地方在范围外，正在换")
        #expect(failed?.steps.map(\.state) == [.done, .failed])
        #expect(w.clear(at: t(6_000)) == "work show=trip steps=2 failed=1 ms=6000")
        #expect(w.panel(at: t(6_000)) == nil)
    }

    @Test("T-040w: a failure line goes with the next step, or 3 s after the end")
    func failureKept() {
        var w = WorkProgress()
        w.start(.trip, at: t(0))
        w.step(WorkProgress.tripCheck, at: t(0))
        w.fail(WorkProgress.outOfArea(2), at: t(1_200))
        w.step(WorkProgress.tripTimes, at: t(1_500))
        #expect(w.panel(at: t(1_600))?.failure == nil)
        #expect(w.panel(at: t(1_600))?.steps.map(\.state) == [.failed, .running])
        w.fail("没有路线", at: t(2_000))
        #expect(w.end(at: t(2_500)) == "work show=trip steps=2 failed=2 ms=2500")
        #expect(w.panel(at: t(5_400))?.failure == "没有路线")
        #expect(w.panel(at: t(5_500)) == nil)
        // The same title as the running step adds nothing.
        var again = WorkProgress()
        again.start(.trip, at: t(0))
        again.step(WorkProgress.tripTimes, at: t(0))
        again.step(WorkProgress.tripTimes, at: t(100))
        #expect(again.panel(at: t(1_000))?.steps.count == 1)
    }

    @Test("T-040w row 150: query_live_info weather taking 3 s shows 正在查天气… from 1 s to the answer")
    func row150() {
        let clock = ManualClock()
        let lines = Mutex<[String]>([])
        let board = WorkProgressBoard(clock: clock) { line in lines.withLock { $0.append(line) } }
        board.start(.search, step: WorkProgress.searchTitle(tool: "query_live_info", kind: "weather"))
        clock.advance(by: .milliseconds(900))
        #expect(board.panel == nil)
        clock.advance(by: .milliseconds(100))
        #expect(board.panel?.steps.map(\.title) == ["正在查天气…"])
        clock.advance(by: .seconds(2))
        #expect(board.panel?.kind == .search)
        board.clear(.trip)
        #expect(board.panel != nil)
        board.clear()
        #expect(board.panel == nil)
        #expect(lines.withLock { $0 } == ["work show=search steps=1 failed=0 ms=3000"])
        #expect(WorkProgress.searchTitle(tool: "web_search", kind: nil) == "正在搜索…")
        #expect(WorkProgress.searchTitle(tool: "query_live_info", kind: "route_traffic") == "正在查…")
    }
}
