import NovaKit
import NovaPorts
import Synchronization

/// The model turn a tool call belongs to, set by the tool runner around `execute` (nil: not known, e.g. the comfort
/// test, where every call of a case is one set).
public enum ToolTurn {
    @TaskLocal public static var current: UInt64?
}

/// F-09b §4 item 2 (T-031j): the cabin state from before the last comfort change set. Every vehicle action that was
/// ok in one model turn is one set. Only one set is kept, for 5 minutes; a tap on a comfort control clears it.
/// In memory only.
public final class ChangeSetStore: Sendable {
    public static let keep = NovaDuration.seconds(300)

    public struct Kept: Sendable, Hashable {
        public let climate: ClimateState
        public let cabin: CabinState
        public let at: NovaInstant
        let turn: UInt64?
    }

    private let kept = Mutex<Kept?>(nil)
    private let clock: any NovaClock

    public init(clock: any NovaClock) { self.clock = clock }

    /// An ok vehicle action of `turn`; `climate`/`cabin`: the state just before it. The first action of a turn
    /// starts a new set (dropping the older one); later ones of the same turn join it.
    public func changed(before climate: ClimateState, _ cabin: CabinState, turn: UInt64?) {
        let now = clock.now
        kept.withLock { k in
            if let k, k.turn == turn { return }
            k = Kept(climate: climate, cabin: cabin, at: now, turn: turn)
        }
    }

    /// F-09b §4 item 2: a tap on a comfort control, or a reset.
    public func clear() { kept.withLock { $0 = nil } }

    /// The set to undo, removed; nil when there is none or it is older than 5 minutes.
    public func take() -> Kept? {
        let now = clock.now
        return kept.withLock { k in
            defer { k = nil }
            guard let set = k, now - set.at <= Self.keep else { return nil }
            return set
        }
    }
}

/// Records each ok change of the wrapped vehicle tools into the store (a `get_state` changes nothing).
public struct ChangeSetRecorder: ToolExecutor {
    let inner: any ToolExecutor
    let port: any VehicleControlPort
    let store: ChangeSetStore

    public init(inner: any ToolExecutor, port: any VehicleControlPort, store: ChangeSetStore) {
        self.inner = inner
        self.port = port
        self.store = store
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let climate = await port.climateState()
        let cabin = await port.cabinState()
        let result = await inner.execute(call)
        let reads = call.arguments["action"]?.stringValue == "get_state"
        guard result.ok, !reads else { return result }
        let afterClimate = await port.climateState()
        let afterCabin = await port.cabinState()
        if climate != afterClimate || cabin != afterCabin {
            store.changed(before: climate, cabin, turn: ToolTurn.current)
        }
        return result
    }
}

/// F-09b §4 (T-031j): `undo_last_change`. Restores the kept set through the same (policed) port; the result names
/// the restored values. Nothing kept, or older than 5 minutes: `NOTHING_TO_UNDO`.
public struct UndoLastChangeTool: ToolExecutor {
    public static let tool = "undo_last_change"
    let port: any VehicleControlPort
    let store: ChangeSetStore
    /// §8: `undo ok=<yes|no> restored=<n>`; codes and numbers only (I-8).
    let onLine: @Sendable (String) -> Void

    public init(port: any VehicleControlPort, store: ChangeSetStore, onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.port = port
        self.store = store
        self.onLine = onLine
    }

    public static func line(ok: Bool, restored: Int) -> String { "undo ok=\(ok ? "yes" : "no") restored=\(restored)" }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let set = store.take() else {
            onLine(Self.line(ok: false, restored: 0))
            return ToolDispatcher.failure(.nothingToUndo)
        }
        var restored: [String: JSONValue] = [:]
        var failed: [String] = []
        var count = 0
        func ok<S>(_ r: VehicleActionResult<S>) -> Bool { if case .success = r { true } else { false } }

        // Climate: power on first, the values, power off last, so each step runs on the state it needs.
        let before = await port.climateState()
        let target = set.climate
        var climate: [String: JSONValue] = [:]
        if target.powerOn, !before.powerOn {
            if ok(await port.setHvacPower(true)) { climate["power_on"] = .bool(true); count += 1 } else { failed.append("power_on") }
        }
        if target.targetTemperatureCelsius != before.targetTemperatureCelsius {
            if ok(await port.setCabinTemperature(target.targetTemperatureCelsius)) {
                climate["temperature_c"] = .double(target.targetTemperatureCelsius); count += 1
            } else { failed.append("temperature_c") }
        }
        if target.fanLevel != before.fanLevel {
            if ok(await port.setFanLevel(target.fanLevel)) { climate["fan_level"] = .int(Int64(target.fanLevel)); count += 1 }
            else { failed.append("fan_level") }
        }
        if !target.powerOn, before.powerOn {
            if ok(await port.setHvacPower(false)) { climate["power_on"] = .bool(false); count += 1 } else { failed.append("power_on") }
        }
        if !climate.isEmpty { restored["climate"] = .object(climate) }

        let cabin = await port.cabinState()
        var windows: [String: JSONValue] = [:]
        for id in WindowID.allCases {
            let want = set.cabin.windows[id] ?? CabinLimits.windowMin
            guard (cabin.windows[id] ?? CabinLimits.windowMin) != want else { continue }
            if ok(await port.setWindows([id], openPercent: want)) { windows[id.rawValue] = .int(Int64(want)); count += 1 }
            else { failed.append(id.rawValue) }
        }
        if !windows.isEmpty { restored["windows"] = .object(windows) }
        var seats: [String: JSONValue] = [:]
        for id in SeatID.allCases {
            let want = set.cabin.seatHeights[id] ?? CabinLimits.seatDefault
            guard (cabin.seatHeights[id] ?? CabinLimits.seatDefault) != want else { continue }
            if ok(await port.setSeatHeight(id, level: want)) { seats[id.rawValue] = .int(Int64(want)); count += 1 }
            else { failed.append("seat_" + id.rawValue) }
        }
        if !seats.isEmpty { restored["seat"] = .object(seats) }

        if count == 0, !failed.isEmpty {
            onLine(Self.line(ok: false, restored: 0))
            return ToolDispatcher.failure(.vehicleExecutionFailed)
        }
        onLine(Self.line(ok: true, restored: count))
        var data: [String: JSONValue] = ["restored": .object(restored), "restored_count": .int(Int64(count))]
        if !failed.isEmpty { data["not_restored"] = .array(failed.map { .string($0) }) }
        return .success(data)
    }
}
