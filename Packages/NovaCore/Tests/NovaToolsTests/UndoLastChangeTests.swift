import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// Suspends after its temperature write until released, so a parallel call of the same turn runs in between.
final class GatedVehicle: VehicleControlPort, @unchecked Sendable {
    let inner = FakeVehicle()
    let gate = Mutex<(entered: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
    var backendLabel: String { "gated" }
    var entered: Bool { gate.withLock { $0.entered } }
    func release() { gate.withLock { g in defer { g.waiter = nil }; return g.waiter }?.resume() }
    func setCabinTemperature(_ celsius: Double) async -> VehicleActionResult<ClimateState> {
        let r = await inner.setCabinTemperature(celsius)
        // Only the first write pauses (the undo's own write must not).
        guard !entered else { return r }
        await withCheckedContinuation { c in gate.withLock { $0 = (true, c) } }
        return r
    }
    func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState> { await inner.setHvacPower(on) }
    func changeCabinTemperature(_ d: Double) async -> VehicleActionResult<ClimateState> { await inner.changeCabinTemperature(d) }
    func setFanLevel(_ l: Int) async -> VehicleActionResult<ClimateState> { await inner.setFanLevel(l) }
    func changeFanLevel(_ d: Int) async -> VehicleActionResult<ClimateState> { await inner.changeFanLevel(d) }
    func climateState() async -> ClimateState { await inner.climateState() }
    func setWindows(_ w: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState> { await inner.setWindows(w, openPercent: openPercent) }
    func changeWindows(_ w: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState> { await inner.changeWindows(w, deltaPercent: deltaPercent) }
    func setSeatHeight(_ s: SeatID, level: Int) async -> VehicleActionResult<CabinState> { await inner.setSeatHeight(s, level: level) }
    func changeSeatHeight(_ s: SeatID, delta: Int) async -> VehicleActionResult<CabinState> { await inner.changeSeatHeight(s, delta: delta) }
    func cabinState() async -> CabinState { await inner.cabinState() }
}

final class UndoStepClock: NovaClock, @unchecked Sendable {
    private let t = Mutex(NovaInstant.zero)
    var now: NovaInstant { t.withLock { $0 } }
    func advance(_ d: NovaDuration) { t.withLock { $0 = $0 + d } }
    func sleep(until deadline: NovaInstant) async throws {}
}

private func vcall(_ name: String, _ args: [String: JSONValue] = [:], id: String = "c1") -> ToolCall {
    ToolCall(id: CallID(id)!, name: name, arguments: .object(args))
}

/// F-09b §4 (T-031j): undo in one sentence.
@Suite("T-031j F-09b §4 undo_last_change")
struct UndoLastChangeTests {
    final class Lines: Sendable { let all = Mutex<[String]>([]) }

    struct Rig {
        let fake = FakeVehicle()
        let clock = UndoStepClock()
        let store: ChangeSetStore
        let port: PolicedVehiclePort
        let tools: ChangeSetRecorder
        let undo: UndoLastChangeTool
        let lines = Lines()

        init(speed: Double? = nil) {
            store = ChangeSetStore(clock: clock)
            port = PolicedVehiclePort(fake, speedKmh: { speed })
            tools = ChangeSetRecorder(inner: VehicleToolExecutor(port: port), port: port, store: store)
            let lines = self.lines
            undo = UndoLastChangeTool(port: port, store: store) { line in lines.all.withLock { $0.append(line) } }
        }

        func run(_ call: ToolCall, turn: UInt64?) async -> ToolResult {
            await ToolTurn.$current.withValue(turn) { await tools.execute(call) }
        }
    }

    @Test("T-031j F-09b row 3: one model turn sets temperature and opens a window; undo restores both through the policy; claims backed; a second undo is NOTHING_TO_UNDO")
    func row3() async {
        let rig = Rig()
        let t = await rig.run(vcall("control_climate", ["action": "set_temperature", "value": .int(20)]), turn: 1)
        let w = await rig.run(vcall("control_window", ["action": "set", "window": "driver", "value": .int(50)], id: "c2"), turn: 1)
        #expect(t.ok && w.ok)
        #expect(await rig.fake.climateState().targetTemperatureCelsius == 20)
        let r = await rig.undo.execute(vcall("undo_last_change", id: "u1"))
        #expect(r.ok)
        #expect(await rig.fake.climateState().targetTemperatureCelsius == ClimateState.default.targetTemperatureCelsius)
        #expect(await rig.fake.cabinState().windows[.frontLeft] == 0)
        guard case .object(let restored)? = r.data["restored"] else { Issue.record("restored"); return }
        #expect(restored["climate"] != nil && restored["windows"] != nil)
        #expect(r.data["restored_count"] == .int(2))
        let again = await rig.undo.execute(vcall("undo_last_change", id: "u2"))
        #expect(again.code == .nothingToUndo)
        #expect(rig.lines.all.withLock { $0 } == ["undo ok=yes restored=2", "undo ok=no restored=0"])
    }

    @Test("T-031j F-09b §4 item 2: a later turn's change set replaces the earlier one; get_state and a failed call record nothing")
    func oneSetKept() async {
        let rig = Rig()
        _ = await rig.run(vcall("control_climate", ["action": "set_temperature", "value": .int(20)]), turn: 1)
        _ = await rig.run(vcall("control_climate", ["action": "get_state"], id: "c2"), turn: 2)
        _ = await rig.run(vcall("control_climate", ["action": "set_fan", "value": .int(5)], id: "c3"), turn: 3)
        let r = await rig.undo.execute(vcall("undo_last_change", id: "u1"))
        #expect(r.ok)
        // Only turn 3's fan change is undone; turn 1's temperature stays.
        #expect(await rig.fake.climateState().fanLevel == ClimateState.default.fanLevel)
        #expect(await rig.fake.climateState().targetTemperatureCelsius == 20)
        // A blocked call (window 50% at 120 km/h) keeps nothing to undo.
        let fast = Rig(speed: 120)
        let blocked = await fast.run(vcall("control_window", ["action": "set", "value": .int(50)]), turn: 1)
        #expect(blocked.code == .vehicleBlocked)
        #expect(await fast.undo.execute(vcall("undo_last_change")).code == .nothingToUndo)
    }

    @Test("T-031j F-09b row 4: undo 6 minutes after the change; undo after a tap on the fan: NOTHING_TO_UNDO both times")
    func row4() async {
        let rig = Rig()
        _ = await rig.run(vcall("control_climate", ["action": "set_temperature", "value": .int(20)]), turn: 1)
        rig.clock.advance(.seconds(6 * 60))
        #expect(await rig.undo.execute(vcall("undo_last_change")).code == .nothingToUndo)
        #expect(await rig.fake.climateState().targetTemperatureCelsius == 20)
        _ = await rig.run(vcall("control_climate", ["action": "set_fan", "value": .int(5)], id: "c2"), turn: 2)
        // A tap on a comfort control clears the kept set.
        rig.store.clear()
        #expect(await rig.undo.execute(vcall("undo_last_change", id: "u2")).code == .nothingToUndo)
        #expect(await rig.fake.climateState().fanLevel == 5)
    }

    @Test("T-031j F-09b row 2: the undo goes through VehicleActionPolicy (a window reopened above the speed limit is not restored)")
    func throughPolicy() async {
        let fake = FakeVehicle()
        _ = await fake.setWindows([.frontLeft], openPercent: 80)
        let clock = UndoStepClock()
        let store = ChangeSetStore(clock: clock)
        let speed = Mutex<Double?>(nil)
        let port = PolicedVehiclePort(fake, speedKmh: { speed.withLock { $0 } })
        let tools = ChangeSetRecorder(inner: VehicleToolExecutor(port: port), port: port, store: store)
        _ = await ToolTurn.$current.withValue(1) {
            await tools.execute(vcall("control_window", ["action": "close", "window": "driver"]))
        }
        speed.withLock { $0 = 120 }
        let r = await UndoLastChangeTool(port: port, store: store).execute(vcall("undo_last_change"))
        #expect(r.code == .vehicleExecutionFailed)
        #expect(await fake.cabinState().windows[.frontLeft] == 0)
    }

    @Test("T-031j F-09b §4 item 2: parallel calls of one turn keep the state from before the turn")
    func parallelTurn() async {
        let rig = Rig()
        async let a = rig.run(vcall("control_climate", ["action": "set_temperature", "value": .int(20)]), turn: 7)
        async let b = rig.run(vcall("control_window", ["action": "set", "window": "driver", "value": .int(50)], id: "c2"), turn: 7)
        async let f = rig.run(vcall("control_climate", ["action": "set_fan", "value": .int(5)], id: "c3"), turn: 7)
        _ = await (a, b, f)
        #expect(await rig.undo.execute(vcall("undo_last_change")).data["restored_count"] == .int(3))
        #expect(await rig.fake.climateState() == ClimateState.default)
        #expect(await rig.fake.cabinState().windows[.frontLeft] == 0)
    }

    @Test("T-031j F-09b §4 item 2: the same turn number on a new connection is a new set; an expired set is replaced")
    func reconnect() async {
        let rig = Rig()
        let e1 = ToolTurn.newEpoch(), e2 = ToolTurn.newEpoch()
        #expect(ToolTurn.key(epoch: e1, turn: 1) != ToolTurn.key(epoch: e2, turn: 1))
        _ = await rig.run(vcall("control_climate", ["action": "set_temperature", "value": .int(20)]), turn: ToolTurn.key(epoch: e1, turn: 1))
        _ = await rig.run(vcall("control_window", ["action": "set", "window": "driver", "value": .int(50)], id: "c2"),
                          turn: ToolTurn.key(epoch: e2, turn: 1))
        #expect(await rig.undo.execute(vcall("undo_last_change")).ok)
        #expect(await rig.fake.climateState().targetTemperatureCelsius == 20)
        #expect(await rig.fake.cabinState().windows[.frontLeft] == 0)
        // Same key, but the kept set expired: the new change starts a fresh set.
        _ = await rig.run(vcall("control_climate", ["action": "set_fan", "value": .int(5)]), turn: 9)
        rig.clock.advance(.seconds(6 * 60))
        _ = await rig.run(vcall("control_climate", ["action": "set_fan", "value": .int(6)], id: "c2"), turn: 9)
        #expect(await rig.undo.execute(vcall("undo_last_change", id: "u2")).ok)
        #expect(await rig.fake.climateState().fanLevel == 5)
    }

    @Test("T-031j F-09b §4 item 2: a window call that runs while the temperature call is still finishing does not lose the climate")
    func interleaved() async {
        let car = GatedVehicle()
        let store = ChangeSetStore(clock: UndoStepClock())
        let port = PolicedVehiclePort(car, speedKmh: { nil })
        let tools = ChangeSetRecorder(inner: VehicleToolExecutor(port: port), port: port, store: store)
        let a = Task { await ToolTurn.$current.withValue(5) { await tools.execute(vcall("control_climate", ["action": "set_temperature", "value": .int(20)])) } }
        // Bounded: a write that never reaches the car fails the test instead of hanging it.
        for _ in 0..<2000 where !car.entered { try? await Task.sleep(for: .milliseconds(1)) }
        guard car.entered else { Issue.record("temperature write never reached the car"); a.cancel(); return }
        let bDone = Mutex(false)
        let b = Task {
            let r = await ToolTurn.$current.withValue(5) { await tools.execute(vcall("control_window", ["action": "set", "window": "driver", "value": .int(50)], id: "c2")) }
            bDone.withLock { $0 = true }
            return r
        }
        // Without the lock the window call finishes (and records) while the temperature call is paused;
        // with it, it waits, and this wait runs out.
        for _ in 0..<200 where !bDone.withLock({ $0 }) { try? await Task.sleep(for: .milliseconds(1)) }
        car.release()
        _ = await (a.value, b.value)
        #expect(await UndoLastChangeTool(port: port, store: store).execute(vcall("undo_last_change")).ok)
        #expect(await car.climateState().targetTemperatureCelsius == ClimateState.default.targetTemperatureCelsius)
        #expect(await car.cabinState().windows[.frontLeft] == 0)
    }
}
