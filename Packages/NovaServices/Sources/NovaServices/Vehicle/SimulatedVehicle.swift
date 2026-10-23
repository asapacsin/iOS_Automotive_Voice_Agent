import NovaKit
import NovaPorts
import Synchronization

/// Operations a test can make fail (`ClimateOperation`).
public enum ClimateOperation: String, Sendable, Hashable, CaseIterable {
    case power, setTemperature = "set_temperature", changeTemperature = "change_temperature",
         setFan = "set_fan", changeFan = "change_fan"
}

/// Failure kinds a test can inject (`InjectedClimateFailure`).
public enum InjectedClimateFailure: Sendable, Hashable { case unsupported, unavailable, permissionDenied, executionFailure }

/// SIMULATED vehicle (`simulator/SimulatedVehicleControl.kt`). Not vehicle control: an in-memory
/// stand-in that proves voice → tool → port → state → result. A failed operation never changes state.
public final class SimulatedVehicle: VehicleControlPort {
    public let backendLabel = "simulated"

    private struct State {
        var climate: ClimateState
        var cabin: CabinState
        var failNext: InjectedClimateFailure?
        var failAlways: [ClimateOperation: InjectedClimateFailure] = [:]
    }

    private let state: Mutex<State>

    public init(climate: ClimateState = .default, cabin: CabinState = .default) {
        state = Mutex(State(climate: climate, cabin: cabin))
    }

    /// Fails exactly one upcoming climate operation.
    public func failNext(_ failure: InjectedClimateFailure?) { state.withLock { $0.failNext = failure } }
    /// Fails every call to `operation` until cleared with nil.
    public func failAlways(_ operation: ClimateOperation, _ failure: InjectedClimateFailure?) {
        state.withLock { $0.failAlways[operation] = failure }
    }

    /// Benchmark reset: a known state and no pending faults.
    public func reset(climate: ClimateState = .default, cabin: CabinState = .default) {
        state.withLock { $0 = State(climate: climate, cabin: cabin) }
    }

    // MARK: Climate

    public func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState> {
        mutate(.power) { c in .success(ClimateState(powerOn: on, targetTemperatureCelsius: c.targetTemperatureCelsius,
                                                     fanLevel: c.fanLevel), limitReached: false) }
    }

    public func setCabinTemperature(_ celsius: Double) async -> VehicleActionResult<ClimateState> {
        mutate(.setTemperature) { c in
            guard celsius.isFinite, (ClimateLimits.minTemperatureC...ClimateLimits.maxTemperatureC).contains(celsius) else {
                return .invalidArgument("temperature \(celsius) outside \(ClimateLimits.minTemperatureC)..\(ClimateLimits.maxTemperatureC)")
            }
            var next = c
            next.targetTemperatureCelsius = celsius
            return .success(next, limitReached: false)
        }
    }

    public func changeCabinTemperature(_ delta: Double) async -> VehicleActionResult<ClimateState> {
        mutate(.changeTemperature) { c in
            guard delta.isFinite else { return .invalidArgument("temperature delta must be a finite number") }
            let wanted = c.targetTemperatureCelsius + delta
            let bounded = min(max(wanted, ClimateLimits.minTemperatureC), ClimateLimits.maxTemperatureC)
            var next = c
            next.targetTemperatureCelsius = bounded
            return .success(next, limitReached: bounded != wanted)
        }
    }

    public func setFanLevel(_ level: Int) async -> VehicleActionResult<ClimateState> {
        mutate(.setFan) { c in
            guard (ClimateLimits.minFanLevel...ClimateLimits.maxFanLevel).contains(level) else {
                return .invalidArgument("fan level \(level) outside \(ClimateLimits.minFanLevel)..\(ClimateLimits.maxFanLevel)")
            }
            var next = c
            next.fanLevel = level
            return .success(next, limitReached: false)
        }
    }

    public func changeFanLevel(_ delta: Int) async -> VehicleActionResult<ClimateState> {
        mutate(.changeFan) { c in
            let wanted = Int64(c.fanLevel) + Int64(delta)
            let bounded = min(max(wanted, Int64(ClimateLimits.minFanLevel)), Int64(ClimateLimits.maxFanLevel))
            var next = c
            next.fanLevel = Int(bounded)
            return .success(next, limitReached: bounded != wanted)
        }
    }

    public func climateState() async -> ClimateState { state.withLock { $0.climate } }

    private func mutate(_ operation: ClimateOperation,
                        _ block: (ClimateState) -> VehicleActionResult<ClimateState>) -> VehicleActionResult<ClimateState> {
        state.withLock { s in
            let injected = s.failAlways[operation] ?? s.failNext
            if s.failAlways[operation] == nil, injected != nil { s.failNext = nil }
            if let injected {
                let name = operation.rawValue
                switch injected {
                case .unsupported: return .unsupported(name)
                case .unavailable: return .unavailable("simulated: \(name) unavailable")
                case .permissionDenied: return .permissionDenied("simulated: \(name) not permitted")
                case .executionFailure: return .failure("simulated: \(name) execution failed")
                }
            }
            let outcome = block(s.climate)
            if case .success(let next, let limited) = outcome {
                s.climate = next
                return .success(s.climate, limitReached: limited)
            }
            return outcome
        }
    }

    // MARK: Cabin

    public func setWindows(_ windows: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState> {
        mutateCabin { c in
            if windows.isEmpty { return .invalidArgument("no window selected") }
            guard (CabinLimits.windowMin...CabinLimits.windowMax).contains(openPercent) else {
                return .invalidArgument("window percent \(openPercent) outside \(CabinLimits.windowMin)..\(CabinLimits.windowMax)")
            }
            var next = c
            for w in windows { next.windows[w] = openPercent }
            return .success(next, limitReached: false)
        }
    }

    public func changeWindows(_ windows: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState> {
        mutateCabin { c in
            if windows.isEmpty { return .invalidArgument("no window selected") }
            var next = c
            var limited = false
            for w in windows {
                let wanted = Int64(c.windows[w] ?? 0) + Int64(deltaPercent)
                let bounded = min(max(wanted, Int64(CabinLimits.windowMin)), Int64(CabinLimits.windowMax))
                // A window already at the limit in the asked direction is clamped too.
                if bounded != wanted { limited = true }
                next.windows[w] = Int(bounded)
            }
            return .success(next, limitReached: limited)
        }
    }

    public func setSeatHeight(_ seat: SeatID, level: Int) async -> VehicleActionResult<CabinState> {
        mutateCabin { c in
            guard (CabinLimits.seatMin...CabinLimits.seatMax).contains(level) else {
                return .invalidArgument("seat level \(level) outside \(CabinLimits.seatMin)..\(CabinLimits.seatMax)")
            }
            var next = c
            next.seatHeights[seat] = level
            return .success(next, limitReached: false)
        }
    }

    public func changeSeatHeight(_ seat: SeatID, delta: Int) async -> VehicleActionResult<CabinState> {
        mutateCabin { c in
            let wanted = Int64(c.seatHeights[seat] ?? CabinLimits.seatDefault) + Int64(delta)
            let bounded = min(max(wanted, Int64(CabinLimits.seatMin)), Int64(CabinLimits.seatMax))
            var next = c
            next.seatHeights[seat] = Int(bounded)
            return .success(next, limitReached: bounded != wanted)
        }
    }

    public func cabinState() async -> CabinState { state.withLock { $0.cabin } }

    private func mutateCabin(_ block: (CabinState) -> VehicleActionResult<CabinState>) -> VehicleActionResult<CabinState> {
        state.withLock { s in
            let outcome = block(s.cabin)
            if case .success(let next, let limited) = outcome {
                s.cabin = next
                return .success(s.cabin, limitReached: limited)
            }
            return outcome
        }
    }
}
