import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// The navigation flow stand-in: records each call's arguments and closes what it is told by reporting off.
private final class FlowSpy: ToolExecutor, Sendable {
    let args = Mutex<[JSONValue]>([])
    let status: String
    let act: @Sendable () async -> Void
    init(status: String, act: @escaping @Sendable () async -> Void) {
        self.status = status
        self.act = act
    }
    func execute(_ call: ToolCall) async -> ToolResult {
        args.withLock { $0.append(call.arguments) }
        await act()
        return .success(["status": .string(status)])
    }
}

@Suite("T-031zg F-09b §22 every panel she can close has a 「×」 the driver taps")
struct PanelCloseTapTests {
    @Test("T-031zg F-09b §22 row 1: each panel's 「×」 closes it through exit_navigation_mode's one close path; other panels unchanged; the tap is recorded first")
    func row1() async {
        #expect(PanelCloseTap.panels == [.destinationList, .routePicking, .tripScreen, .tripDetail, .tripPlans, .musicCard])
        for panel in PanelCloseTap.panels {
            let screen = ScreenStateStore(ScreenState(on: [.navigation, panel]))
            let closed = Mutex<[ScreenPanel]>([])
            let status = panel == .tripScreen ? "trip_cards_hidden"
                : panel == .destinationList ? "list_closed_guidance_kept" : "navigation_selection_cancelled"
            let flow = FlowSpy(status: status) { await screen.report(panel, on: false) }
            let exit = ScreenConfirmedExecutor(flow, screen: screen, clock: ManualClock(), close: { p in
                closed.withLock { $0.append(p) }
                await screen.report(p, on: false)
            })
            let taps = Mutex<[String]>([])
            let r = await PanelCloseTap.tap(panel, exit: exit, record: { p in taps.withLock { $0.append("panel close tap \(p.rawValue)") } })
            #expect(r.ok, "\(panel) \(r)")
            let now = await screen.current
            #expect(!now.isOn(panel) && now.isOn(.navigation), "\(panel)")
            #expect(taps.withLock { $0 } == ["panel close tap \(panel.rawValue)"])
            if ScreenConfirmedExecutor.ownClose[panel] != nil {
                #expect(closed.withLock { $0 } == [panel] && flow.args.withLock { $0 }.isEmpty, "\(panel)")
            } else {
                // §22 item 2: the navigation flow's own close for that panel (named, so guidance is never ended by it).
                #expect(closed.withLock { $0 }.isEmpty && flow.args.withLock { $0 } == [.object(["panel": .string(panel.rawValue)])], "\(panel)")
            }
        }
        #expect(PanelCloseTap.identifier(.tripScreen) == "tripScreen-close" && PanelCloseTap.label(.routePicking) == "关掉路线选择")
    }

    @Test("T-031zg F-09b §22 row 2: destinationList and routePicking 「×」 = 「不去了」: the flow's cancel, list gone, nothing sent to the model")
    func row2() async {
        for panel in [ScreenPanel.destinationList, .routePicking] {
            let screen = ScreenStateStore(ScreenState(on: [panel]))
            let flow = FlowSpy(status: "navigation_selection_cancelled") { await screen.report(panel, on: false) }
            let exit = ScreenConfirmedExecutor(flow, screen: screen, clock: ManualClock())
            let tapped = await PanelCloseTap.tap(panel, exit: exit)
            let voiceScreen = ScreenStateStore(ScreenState(on: [panel]))
            let voiceFlow = FlowSpy(status: "navigation_selection_cancelled") { await voiceScreen.report(panel, on: false) }
            let said = await ScreenConfirmedExecutor(voiceFlow, screen: voiceScreen, clock: ManualClock())
                .execute(ToolCall(id: CallID("c1")!, name: "exit_navigation_mode", arguments: [:]))
            #expect(tapped.data["status"] == said.data["status"] && tapped.data["status"] == "navigation_selection_cancelled")
            #expect(flow.args.withLock { $0 } == [.object(["panel": .string(panel.rawValue)])] && voiceFlow.args.withLock { $0 } == [.object([:])])
            #expect(await !screen.current.isOn(panel))
        }
    }
}
