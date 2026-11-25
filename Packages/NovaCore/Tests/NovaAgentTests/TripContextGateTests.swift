import Synchronization
import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §65 (T-040zr): a trip from an earlier conversation is not in her context until it is used.

private final class ScriptedTripTool: ToolExecutor {
    let calls = Mutex<[String]>([])
    func execute(_ call: ToolCall) async -> ToolResult {
        calls.withLock { $0.append(call.name) }
        // The trip tools answer from the saved plan whether the line is on or off.
        return .success(["status": "trip_next", "plan": ["days": []]])
    }
}

private func savedPlan() -> TripPlan {
    var list = TripList()
    list.replace([(asked: "珠海渔女", place: Place(id: "p1", name: "珠海渔女", address: nil,
                                               coordinate: GeoCoordinate(latitude: 22.27, longitude: 113.59, datum: .gcj02),
                                               distanceMeters: nil), distanceMeters: nil)])
    var plan = TripPlan()
    plan.replaceAll(withDays: [list])
    return plan
}

private func snapshot(_ gate: TripContextGate, _ plan: TripPlan) -> ContextSnapshot {
    ContextSnapshot(place: nil, onHighway: nil, localTime: "11月25日 星期三 16:42", tripPlan: gate.noteLine(plan))
}

private final class Lines: Sendable {
    let all = Mutex<[String]>([])
    func add(_ line: String) { all.withLock { $0.append(line) } }
    var list: [String] { all.withLock { $0 } }
}

private func wrap(_ gate: TripContextGate, _ lines: Lines, tripScreen: Bool = false) -> TripContextExecutor {
    TripContextExecutor(ScriptedTripTool(), gate: gate, onTripScreen: { tripScreen }, onLine: { lines.add($0) })
}

private func call(_ name: String, _ args: JSONValue = [:]) -> ToolCall { ToolCall(id: CallID("c1")!, name: name, arguments: args) }

@Suite("T-040zr F-15b §65 a trip from an earlier conversation is not in her context until it is used")
struct TripContextGateTests {
    @Test("T-040zr F-15b §65 row 303: a plan saved; a new conversation starts: the first note has no trip line, fields without trip")
    func row303() {
        let gate = TripContextGate()
        gate.reset()
        let plan = savedPlan()
        #expect(!plan.isEmpty)
        let first = snapshot(gate, plan)
        #expect(first.tripPlan == nil)
        #expect(!first.fields.contains(.trip))
        #expect(!first.note.contains("行程："))
    }

    @Test("T-040zr F-15b §65 row 304: then a plan_trip result: the next note carries the trip line; record trip context on reason=plan_trip")
    func row304() async {
        let gate = TripContextGate()
        let lines = Lines()
        _ = await wrap(gate, lines).execute(call("plan_trip", ["asked": ["text": "珠海两天"]]))
        let next = snapshot(gate, savedPlan())
        #expect(next.fields.contains(.trip))
        #expect(next.tripPlan == TripPlanJSON.noteLine(savedPlan()))
        #expect(lines.list == ["trip context on reason=plan_trip"])
        // Once on, no second line.
        _ = await wrap(gate, lines).execute(call("set_trip_plan"))
        #expect(lines.list.count == 1)
    }

    @Test("T-040zr F-15b §65 row 305: then trip_next with no plan_trip before: trip_next runs from the saved plan; the next note carries the line, reason=tool:trip_next")
    func row305() async {
        let gate = TripContextGate()
        let lines = Lines()
        let inner = ScriptedTripTool()
        let wrapped = TripContextExecutor(inner, gate: gate, onTripScreen: { false }, onLine: { lines.add($0) })
        #expect(snapshot(gate, savedPlan()).tripPlan == nil)
        let r = await wrapped.execute(call("trip_next"))
        #expect(r.ok && inner.calls.withLock { $0 } == ["trip_next"])
        #expect(snapshot(gate, savedPlan()).fields.contains(.trip))
        #expect(lines.list == ["trip context on reason=tool:trip_next"])
    }

    @Test("T-040zr F-15b §65 row 306: trip line on; the conversation ends and a new one starts: off again")
    func row306() {
        let gate = TripContextGate()
        #expect(gate.turnOn(.touch) == "trip context on reason=touch")
        #expect(snapshot(gate, savedPlan()).fields.contains(.trip))
        gate.reset()
        #expect(!snapshot(gate, savedPlan()).fields.contains(.trip))
    }

    @Test("T-040zr F-15b §65 item 2: the other uses: trip_plans open, exit on the trip screen, a result with plan_kept; other tools leave it off")
    func item2Reasons() {
        let ok = ToolResult.success([:])
        #expect(TripContextGate.reason(call("trip_plans", ["action": "open"]), ok, onTripScreen: false) == .tool("trip_plans"))
        #expect(TripContextGate.reason(call("trip_plans", ["action": "list"]), ok, onTripScreen: false) == nil)
        #expect(TripContextGate.reason(call("exit_navigation_mode"), ok, onTripScreen: true) == .tool("exit_navigation_mode"))
        #expect(TripContextGate.reason(call("exit_navigation_mode"), ok, onTripScreen: false) == nil)
        #expect(TripContextGate.reason(call("navigate_to"), TripPlanner.tripHiddenResult, onTripScreen: false) == .tool("navigate_to"))
        #expect(TripContextGate.reason(call("set_climate"), ok, onTripScreen: false) == nil)
    }
}
