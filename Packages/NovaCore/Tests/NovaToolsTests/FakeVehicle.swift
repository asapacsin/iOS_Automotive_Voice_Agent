import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// In-memory vehicle with per-operation failure injection (shared by the vehicle tests).
final class FakeVehicle: VehicleControlPort {
    struct State {
        var climate = ClimateState.default
        var cabin = CabinState.default
        var failing: Set<String> = []
        var calls: [String] = []
    }
    let state = Mutex(State())
    init(failing: Set<String> = []) { state.withLock { $0.failing = failing } }

    var backendLabel: String { "fake" }
    var calls: [String] { state.withLock { $0.calls } }

    private func climateOp(_ op: String, _ change: (inout ClimateState) -> Void) -> VehicleActionResult<ClimateState> {
        state.withLock { s in
            s.calls.append(op)
            if s.failing.contains(op) { return .failure("\(op) failed") }
            change(&s.climate)
            return .success(s.climate, limitReached: false)
        }
    }

    private func cabinOp(_ op: String, _ change: (inout CabinState) -> Void) -> VehicleActionResult<CabinState> {
        state.withLock { s in
            s.calls.append(op)
            if s.failing.contains(op) { return .failure("\(op) failed") }
            change(&s.cabin)
            return .success(s.cabin, limitReached: false)
        }
    }

    func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState> { climateOp("power") { $0.powerOn = on } }
    func setCabinTemperature(_ celsius: Double) async -> VehicleActionResult<ClimateState> {
        climateOp("temperature") { $0.targetTemperatureCelsius = celsius }
    }
    func changeCabinTemperature(_ deltaCelsius: Double) async -> VehicleActionResult<ClimateState> {
        climateOp("temperature") { $0.targetTemperatureCelsius += deltaCelsius }
    }
    func setFanLevel(_ level: Int) async -> VehicleActionResult<ClimateState> { climateOp("fan") { $0.fanLevel = level } }
    func changeFanLevel(_ delta: Int) async -> VehicleActionResult<ClimateState> { climateOp("fan") { $0.fanLevel += delta } }
    func climateState() async -> ClimateState { state.withLock { $0.climate } }
    func setWindows(_ windows: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState> {
        cabinOp("windows") { c in for w in windows { c.windows[w] = openPercent } }
    }
    func changeWindows(_ windows: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState> {
        cabinOp("windows") { c in for w in windows { c.windows[w] = (c.windows[w] ?? 0) + deltaPercent } }
    }
    func setSeatHeight(_ seat: SeatID, level: Int) async -> VehicleActionResult<CabinState> {
        cabinOp("seat") { $0.seatHeights[seat] = level }
    }
    func changeSeatHeight(_ seat: SeatID, delta: Int) async -> VehicleActionResult<CabinState> {
        cabinOp("seat") { $0.seatHeights[seat] = ($0.seatHeights[seat] ?? 5) + delta }
    }
    func cabinState() async -> CabinState { state.withLock { $0.cabin } }
}

final class FakeMusic: MusicPort {
    let starts: Bool
    let playing = Mutex(false)
    init(starts: Bool = true) { self.starts = starts }
    func playBundled() async -> Bool {
        playing.withLock { $0 = starts }
        return starts
    }
    func stop() async { playing.withLock { $0 = false } }
    var isPlaying: Bool { get async { playing.withLock { $0 } } }
}
