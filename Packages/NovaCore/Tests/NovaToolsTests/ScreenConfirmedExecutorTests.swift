import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// A tool that answers ok (or the given result) and, when set, reports a screen change as it acts.
private final class ActingTool: ToolExecutor, Sendable {
    let calls = Mutex(0)
    let result: ToolResult
    let act: @Sendable () async -> Void
    init(result: ToolResult = .success(["status": "done"]), act: @escaping @Sendable () async -> Void = {}) {
        self.result = result
        self.act = act
    }
    func execute(_ call: ToolCall) async -> ToolResult {
        calls.withLock { $0 += 1 }
        await act()
        return result
    }
}

/// F-09b §16 item 6 (T-031z): tools answer done only when the screen shows the change.
@Suite("F-09b §16 tools answer from the screen state")
struct ScreenConfirmedExecutorTests {
    static func call(_ name: String, _ args: JSONValue = [:]) -> ToolCall {
        ToolCall(id: CallID("c1")!, name: name, arguments: args)
    }

    /// Runs `call` and lets the confirm window run out on the manual clock.
    static func timedOut(_ tool: ScreenConfirmedExecutor, _ call: ToolCall, clock: ManualClock) async -> ToolResult {
        let task = Task { await tool.execute(call) }
        for _ in 0..<2000 where clock.pendingSleepers == 0 { await Task.yield() }
        clock.advance(by: ScreenTuning().screenConfirm)
        return await task.value
    }

    @Test("T-031z row 4: play with musicVolume 0 is not done and nothing plays")
    func volumeZero() async {
        let screen = ScreenStateStore(ScreenState(musicVolume: 0))
        let inner = ActingTool()
        let tool = ScreenConfirmedExecutor(inner, screen: screen, clock: ManualClock())
        let result = await tool.execute(Self.call("control_music", ["action": "play"]))
        #expect(!result.ok && result.code == .mediaVolumeZero)
        #expect(result.data["facts"]?["musicVolume"] == .int(0))
        #expect(inner.calls.withLock { $0 } == 0)
    }

    @Test("T-031z row 4: the node plays but no sound is measured: not done, music off")
    func notHeard() async {
        let clock = ManualClock()
        let screen = ScreenStateStore(ScreenState(musicVolume: 6))
        let tool = ScreenConfirmedExecutor(ActingTool(), screen: screen, clock: clock)
        let result = await Self.timedOut(tool, Self.call("play_music", ["query": "x"]), clock: clock)
        #expect(!result.ok && result.code == .musicNotHeard)
        #expect(result.data["facts"]?["music"] == .string("off"))
        #expect(await !screen.current.music)
    }

    @Test("T-031z row 4: sound measured: done")
    func heard() async {
        let screen = ScreenStateStore(ScreenState(musicVolume: 6))
        let tool = ScreenConfirmedExecutor(ActingTool(act: { await screen.reportMusic(heard: true) }), screen: screen,
                                           clock: ManualClock())
        let result = await tool.execute(Self.call("control_music", ["action": "play"]))
        #expect(result.ok)
        #expect(result.data["next"] == nil)  // no fixed 「音乐放起来了」
    }

    @Test("T-031z row 5: close with the key still on after screenConfirm: not done, still_on")
    func stillOn() async {
        let clock = ManualClock()
        let screen = ScreenStateStore(ScreenState(on: [.routePicking]))
        let tool = ScreenConfirmedExecutor(ActingTool(result: .success(["status": "navigation_selection_cancelled"])),
                                           screen: screen, clock: clock)
        let result = await Self.timedOut(tool, Self.call("exit_navigation_mode"), clock: clock)
        #expect(!result.ok && result.code == .stillOnScreen)
        #expect(result.data["facts"]?["still_on"] == .string("routePicking"))
    }

    @Test("T-031z item 6: the view reports off: done; 「没有在导航」 only with every navigation key off")
    func closed() async {
        let screen = ScreenStateStore(ScreenState(on: [.destinationList]))
        let tool = ScreenConfirmedExecutor(ActingTool(act: { await screen.report(.destinationList, on: false) }),
                                           screen: screen, clock: ManualClock())
        #expect(await tool.execute(Self.call("exit_navigation_mode")).ok)
        let shown = ScreenStateStore(ScreenState(on: [.navigation]))
        let none = ScreenConfirmedExecutor(ActingTool(result: .success(["status": "no_navigation_active"])),
                                           screen: shown, clock: ManualClock())
        let result = await none.execute(Self.call("exit_navigation_mode"))
        #expect(!result.ok && result.code == .stillOnScreen)
        let empty = ScreenConfirmedExecutor(ActingTool(result: .success(["status": "no_navigation_active"])),
                                            screen: ScreenStateStore(), clock: ManualClock())
        #expect(await empty.execute(Self.call("exit_navigation_mode")).ok)
        // A list closed over kept guidance waits for the list only; stopping guidance does not wait for the trip cards.
        let over = ScreenStateStore(ScreenState(on: [.destinationList, .navigation]))
        let kept = ScreenConfirmedExecutor(ActingTool(result: .success(["status": "list_closed_guidance_kept"]),
                                                      act: { await over.report(.destinationList, on: false) }),
                                           screen: over, clock: ManualClock())
        #expect(await kept.execute(Self.call("exit_navigation_mode")).ok)
        let trip = ScreenStateStore(ScreenState(on: [.navigation, .tripScreen]))
        let stopped = ScreenConfirmedExecutor(ActingTool(result: .success(["status": "navigation_stopped"]),
                                                         act: { await trip.report(.navigation, on: false) }),
                                              screen: trip, clock: ManualClock())
        #expect(await stopped.execute(Self.call("exit_navigation_mode")).ok)
        // Other tools pass through untouched.
        #expect(await empty.execute(Self.call("control_music", ["action": "stop"])).ok)
    }
}
