import NovaKit
import NovaPorts

/// One vehicle action as the policy sees it: the intended change, before the port runs it.
public enum VehicleAction: Sendable, Hashable {
    case hvacPower(Bool)
    case setTemperature(Double)
    case changeTemperature(Double)
    case setFan(Int)
    case changeFan(Int)
    case setWindows(Set<WindowID>, percent: Int)
    case changeWindows(Set<WindowID>, delta: Int)
    case setSeat(SeatID, level: Int)
    case changeSeat(SeatID, delta: Int)
}

/// F-12 §14 item 11 (T-031b): code decides whether a vehicle action is allowed, whoever asked for it (the fixed
/// table, the model's own choice, or a direct request). Pure; I-6, I-11.
public enum VehicleActionPolicy {
    /// PROPOSED (F-12 §14 item 11): above this speed a window may open at most `windowMaxAtSpeed` percent.
    public static let windowSpeedKmh = 100.0
    public static let windowMaxAtSpeed = 30

    /// Why an action was blocked. The raw value goes to the model (`blocked`) and to the log; it is never free text.
    public enum Rule: String, Sendable, Hashable, CaseIterable {
        case outOfRange = "out_of_range"
        case windowAtSpeed = "window_at_speed"

        /// The sentence the model reads as `detail`.
        public var detail: String {
            switch self {
            case .outOfRange: "数值超出了允许的范围"
            case .windowAtSpeed: "车速超过\(Int(VehicleActionPolicy.windowSpeedKmh))公里时，车窗最多只能开到\(VehicleActionPolicy.windowMaxAtSpeed)%"
            }
        }
    }

    /// nil when allowed. `speedKmh` nil (unknown) never blocks: the vehicle is simulated and a window is low risk;
    /// an action that is not safe with unknown state needs its own rule and spec.
    public static func check(_ action: VehicleAction, cabin: CabinState, speedKmh: Double?) -> Rule? {
        switch action {
        case .hvacPower, .changeTemperature, .changeFan, .changeSeat:
            // Relative changes are clamped by the port and reported as `limit_reached`.
            return nil
        case .setTemperature(let c):
            return c.isFinite && (ClimateLimits.minTemperatureC...ClimateLimits.maxTemperatureC).contains(c) ? nil : .outOfRange
        case .setFan(let level):
            return (ClimateLimits.minFanLevel...ClimateLimits.maxFanLevel).contains(level) ? nil : .outOfRange
        case .setSeat(_, let level):
            return (CabinLimits.seatMin...CabinLimits.seatMax).contains(level) ? nil : .outOfRange
        case .setWindows(let targets, let percent):
            guard (CabinLimits.windowMin...CabinLimits.windowMax).contains(percent) else { return .outOfRange }
            return windowsTooOpen(targets.map { (cabin.windows[$0] ?? 0, percent) }, speedKmh)
        case .changeWindows(let targets, let delta):
            return windowsTooOpen(targets.map { id in
                let now = cabin.windows[id] ?? 0
                return (now, min(max(now + delta, CabinLimits.windowMin), CabinLimits.windowMax))
            }, speedKmh)
        }
    }

    /// Opening any window above the limit at speed. Closing, or staying where it already is, is always allowed.
    static func windowsTooOpen(_ moves: [(from: Int, to: Int)], _ speedKmh: Double?) -> Rule? {
        guard let speedKmh, speedKmh > windowSpeedKmh else { return nil }
        return moves.contains { $0.to > $0.from && $0.to > windowMaxAtSpeed } ? .windowAtSpeed : nil
    }
}

/// The vehicle port behind the policy: every action from every tool (and any button using the port) passes
/// `VehicleActionPolicy` first, so the table, the model's choice and direct requests share one check.
public struct PolicedVehiclePort: VehicleControlPort {
    let inner: any VehicleControlPort
    /// Current speed in km/h when known and fresh, else nil.
    let speedKmh: @Sendable () async -> Double?

    public init(_ inner: any VehicleControlPort, speedKmh: @escaping @Sendable () async -> Double?) {
        self.inner = inner
        self.speedKmh = speedKmh
    }

    public var backendLabel: String { inner.backendLabel }

    private func rule(_ action: VehicleAction) async -> VehicleActionPolicy.Rule? {
        VehicleActionPolicy.check(action, cabin: await inner.cabinState(), speedKmh: await speedKmh())
    }

    public func setHvacPower(_ on: Bool) async -> VehicleActionResult<ClimateState> {
        if let r = await rule(.hvacPower(on)) { return .blocked(r.rawValue) }
        return await inner.setHvacPower(on)
    }

    public func setCabinTemperature(_ celsius: Double) async -> VehicleActionResult<ClimateState> {
        if let r = await rule(.setTemperature(celsius)) { return .blocked(r.rawValue) }
        return await inner.setCabinTemperature(celsius)
    }

    public func changeCabinTemperature(_ deltaCelsius: Double) async -> VehicleActionResult<ClimateState> {
        if let r = await rule(.changeTemperature(deltaCelsius)) { return .blocked(r.rawValue) }
        return await inner.changeCabinTemperature(deltaCelsius)
    }

    public func setFanLevel(_ level: Int) async -> VehicleActionResult<ClimateState> {
        if let r = await rule(.setFan(level)) { return .blocked(r.rawValue) }
        return await inner.setFanLevel(level)
    }

    public func changeFanLevel(_ delta: Int) async -> VehicleActionResult<ClimateState> {
        if let r = await rule(.changeFan(delta)) { return .blocked(r.rawValue) }
        return await inner.changeFanLevel(delta)
    }

    public func climateState() async -> ClimateState { await inner.climateState() }

    public func setWindows(_ windows: Set<WindowID>, openPercent: Int) async -> VehicleActionResult<CabinState> {
        if let r = await rule(.setWindows(windows, percent: openPercent)) { return .blocked(r.rawValue) }
        return await inner.setWindows(windows, openPercent: openPercent)
    }

    public func changeWindows(_ windows: Set<WindowID>, deltaPercent: Int) async -> VehicleActionResult<CabinState> {
        if let r = await rule(.changeWindows(windows, delta: deltaPercent)) { return .blocked(r.rawValue) }
        return await inner.changeWindows(windows, deltaPercent: deltaPercent)
    }

    public func setSeatHeight(_ seat: SeatID, level: Int) async -> VehicleActionResult<CabinState> {
        if let r = await rule(.setSeat(seat, level: level)) { return .blocked(r.rawValue) }
        return await inner.setSeatHeight(seat, level: level)
    }

    public func changeSeatHeight(_ seat: SeatID, delta: Int) async -> VehicleActionResult<CabinState> {
        if let r = await rule(.changeSeat(seat, delta: delta)) { return .blocked(r.rawValue) }
        return await inner.changeSeatHeight(seat, delta: delta)
    }

    public func cabinState() async -> CabinState { await inner.cabinState() }
}

/// F-12 §14 item 9 (T-031b): `get_vehicle_state`, read-only. Never a coordinate or an address.
public struct VehicleStateTool: ToolExecutor {
    public static let tool = "get_vehicle_state"
    let port: any VehicleControlPort
    let music: (any MusicPort)?
    let navigating: @Sendable () async -> Bool
    let speedKmh: @Sendable () async -> Double?

    public init(port: any VehicleControlPort, music: (any MusicPort)?, navigating: @escaping @Sendable () async -> Bool,
                speedKmh: @escaping @Sendable () async -> Double?) {
        self.port = port
        self.music = music
        self.navigating = navigating
        self.speedKmh = speedKmh
    }

    /// The result's keys; rows 4 checks no location field is among them.
    public static let fields: Set<String> = ["windows", "ac_on", "temperature_c", "fan_level", "music_playing",
                                             "navigating", "speed_kmh"]

    public func execute(_ call: ToolCall) async -> ToolResult {
        let climate = await port.climateState()
        let cabin = await port.cabinState()
        let speed: JSONValue = await speedKmh().map { .int(Int64($0.rounded())) } ?? .null
        return .success([
            "windows": .object(Dictionary(uniqueKeysWithValues: WindowID.allCases.map {
                ($0.rawValue, JSONValue.int(Int64(cabin.windows[$0] ?? 0)))
            })),
            "ac_on": .bool(climate.powerOn),
            "temperature_c": .double(climate.targetTemperatureCelsius),
            "fan_level": .int(Int64(climate.fanLevel)),
            "music_playing": .bool(await music?.isPlaying ?? false),
            "navigating": .bool(await navigating()),
            "speed_kmh": speed,
        ])
    }
}
