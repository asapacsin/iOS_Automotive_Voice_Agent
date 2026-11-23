import NovaKit
@testable import NovaAgent
import NovaTools
import NovaPorts
import Synchronization
import Testing

/// An executor that waits until `release(name)`, then answers `result`.
private final class HeldExecutor: ToolExecutor, @unchecked Sendable {
    let result: ToolResult
    private let waiting = Mutex<[CheckedContinuation<Void, Never>]>([])
    init(_ result: ToolResult = ToolResult(ok: true, code: nil, data: [:], advice: nil)) { self.result = result }
    func execute(_ call: ToolCall) async -> ToolResult {
        await withCheckedContinuation { c in waiting.withLock { $0.append(c) } }
        return result
    }
    var held: Int { waiting.withLock { $0.count } }
    func release() { for c in waiting.withLock({ w -> [CheckedContinuation<Void, Never>] in defer { w = [] }; return w }) { c.resume() } }
}

private struct Instant: ToolExecutor {
    func execute(_ call: ToolCall) async -> ToolResult { ToolDispatcher.failure(.invalidFields) }
}

private func call(_ id: String, _ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(id: CallID(id)!, name: name, arguments: .object(args))
}

private func waitFor(_ cond: @escaping () -> Bool) async {
    for _ in 0..<2000 where !cond() { try? await Task.sleep(for: .milliseconds(1)) }
}

@Suite("T-004k F-04 §15 background work is always on screen")
struct BackgroundWorkTests {
    @Test("T-004k F-04 §15 row 10: a running web_search shows 正在搜索… from the call to its result, whoever talks; off at the result")
    func row10() async {
        let search = HeldExecutor()
        let changes = Mutex<[Bool]>([])
        let runner = ToolRunner(executors: ["web_search": search])
        runner.background.onChange { w in changes.withLock { $0.append(w.on) } }
        let done = Mutex(false)
        runner.start(call("c1", "web_search", ["query": "x"])) { _ in done.withLock { $0 = true } }
        #expect(runner.background.current.caption == "正在搜索…")
        await waitFor { search.held == 1 }
        // The caption does not depend on speech or session state: nothing but the result turns it off.
        #expect(runner.background.current.on)
        search.release()
        await waitFor { done.withLock { $0 } }
        #expect(runner.background.current.caption == nil && !runner.background.current.on)
        #expect(changes.withLock { $0 } == [true, false])
    }

    @Test("T-004k F-04 §15 row 11: set_trip_plan refused at once: on at the call, off at the refusal")
    func row11() async {
        let runner = ToolRunner(executors: ["set_trip_plan": Instant()])
        let seen = Mutex<[String?]>([])
        runner.background.onChange { w in seen.withLock { $0.append(w.caption) } }
        let done = Mutex(false)
        runner.start(call("c1", "set_trip_plan")) { _ in done.withLock { $0 = true } }
        await waitFor { done.withLock { $0 } }
        #expect(seen.withLock { $0 } == ["正在改行程…", nil])
    }

    @Test("T-004k F-04 §15 row 12: search and trip write together: 正在改行程… 等 2 项, then the remaining one's text, then off")
    func row12() async {
        let search = HeldExecutor()
        let trip = HeldExecutor()
        let runner = ToolRunner(executors: ["web_search": search, "set_trip_plan": trip])
        runner.start(call("s", "web_search")) { _ in }
        runner.start(call("t", "set_trip_plan")) { _ in }
        #expect(runner.background.current.caption == "正在改行程… 等 2 项")
        await waitFor { trip.held == 1 && search.held == 1 }
        trip.release()
        await waitFor { runner.background.current.calls.count == 1 }
        #expect(runner.background.current.caption == "正在搜索…")
        search.release()
        await waitFor { !runner.background.current.on }
        #expect(runner.background.current.caption == nil)
        // Item 1 texts.
        #expect(BackgroundWork.text(tool: "query_live_info", kind: "weather") == "正在查天气…")
        #expect(BackgroundWork.text(tool: "query_live_info", kind: "route_traffic") == "正在查…")
        #expect(BackgroundWork.text(tool: "navigate_to", kind: nil) == "正在处理…")
    }

    @Test("T-004k F-04 §15 row 13: session end (or reconnect, or a cancel) with a call running: caption off; panel backgroundWork off in the record")
    func row13() async {
        let search = HeldExecutor()
        let runner = ToolRunner(executors: ["web_search": search])
        runner.start(call("a", "web_search")) { _ in }
        runner.start(call("b", "web_search")) { _ in }
        runner.cancel(CallID("a")!)
        #expect(runner.background.current.calls.map(\.id) == [CallID("b")!])
        runner.clearBackground()
        #expect(!runner.background.current.on)
        await waitFor { search.held == 2 || search.held == 1 }
        search.release()
        // The screen key and its record line: the caption view reports off like every panel.
        var s = ScreenState(on: [.backgroundWork])
        s.report(.backgroundWork, on: false)
        #expect(s.panelLine(.backgroundWork, on: false) == "panel backgroundWork off top=none")
        #expect(s.recordLine.contains("working=off backgroundWork=off settings=off"))
    }
}
