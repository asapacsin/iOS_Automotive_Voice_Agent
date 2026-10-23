import NovaKit
import NovaPorts

/// A vehicle tool result plus the on-screen chip (`Outcome` / `BodyToolOutcome`). The chip exists only
/// on success; the announcement and payload come from the state read back (I-14).
public struct VehicleToolOutcome: Sendable, Hashable {
    public let result: ToolResult
    public let chip: String?
}

/// Shared parsing and failure vocabulary of the Android vehicle handlers.
enum VehicleArgs {
    static let failureInstruction = "操作没有成功。如实告诉用户没有完成，不要说已经完成。"
    static let announceInstruction = "用 announce 这句话告诉用户做了什么，可以换口气，不要加没做的事"

    /// `arguments["value"]` as Android sees it: the JSON value's string form, parsed back.
    static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .int(let v): Double(v)
        case .double(let v): v
        case .string(let s): Double(s.trimmingCharacters(in: [" "]))
        default: nil
        }
    }

    /// `toWholeNumberOrNull`: finite, integral, within Int32.
    static func whole(_ value: JSONValue?) -> Int? {
        guard let d = double(value), d.isFinite, d == d.rounded(.down),
              d <= Double(Int32.max), d >= Double(Int32.min) else { return nil }
        return Int(d)
    }

    static func failure(_ action: String, _ code: ToolErrorCode, _ detail: String) -> VehicleToolOutcome {
        VehicleToolOutcome(result: .failure(code, data: ["action": .string(action), "detail": .string(detail),
                                                         "instruction": .string(failureInstruction)]), chip: nil)
    }

    static func rejected(_ code: ToolErrorCode, _ detail: String) -> VehicleToolOutcome { failure("invalid", code, detail) }

    static func failure<S>(_ action: String, _ result: VehicleActionResult<S>) -> VehicleToolOutcome {
        switch result {
        case .success: preconditionFailure("success is not a failure")
        case .invalidArgument(let r): failure(action, .invalidArgument, r)
        case .unsupported(let f): failure(action, .vehicleUnsupported, f)
        case .unavailable(let r): failure(action, .vehicleUnavailable, r)
        case .permissionDenied(let r): failure(action, .vehiclePermissionDenied, r)
        case .failure(let r): failure(action, .vehicleExecutionFailed, r)
        }
    }
}

/// `A/vehicle/ClimateToolHandler.kt`.
public struct ClimateToolHandler: Sendable {
    let port: any VehicleControlPort
    public init(port: any VehicleControlPort) { self.port = port }

    public func handle(_ args: [String: JSONValue]) async -> VehicleToolOutcome {
        guard let action = args["action"]?.stringValue else { return VehicleArgs.rejected(.missingAction, "action is required") }
        let value = args["value"]
        let result: VehicleActionResult<ClimateState>
        switch action {
        case "power_on": result = await port.setHvacPower(true)
        case "power_off": result = await port.setHvacPower(false)
        case "set_temperature":
            guard let c = VehicleArgs.double(value) else {
                return VehicleArgs.rejected(.invalidValue, "set_temperature needs a numeric value")
            }
            result = await port.setCabinTemperature(c)
        case "adjust_temperature":
            let delta = value == nil ? ClimateLimits.defaultTemperatureStepC : VehicleArgs.double(value)
            guard let delta else { return VehicleArgs.rejected(.invalidValue, "adjust_temperature value must be numeric") }
            result = await port.changeCabinTemperature(delta)
        case "set_fan":
            guard let level = VehicleArgs.whole(value) else {
                return VehicleArgs.rejected(.invalidValue, "set_fan needs a whole-number value")
            }
            result = await port.setFanLevel(level)
        case "adjust_fan":
            let delta = value == nil ? ClimateLimits.defaultFanStep : VehicleArgs.whole(value)
            guard let delta else { return VehicleArgs.rejected(.invalidValue, "adjust_fan value must be a whole number") }
            result = await port.changeFanLevel(delta)
        case "get_state": result = .success(await port.climateState(), limitReached: false)
        default: return VehicleArgs.rejected(.actionNotAllowed, "unknown action \(action)")
        }
        guard case .success(let state, let limited) = result else { return VehicleArgs.failure(action, result) }
        let data: [String: JSONValue] = [
            "action": .string(action), "power_on": .bool(state.powerOn),
            "temperature_c": .double(state.targetTemperatureCelsius), "fan_level": .int(Int64(state.fanLevel)),
            "temperature_range_c": .string("\(ClimateLimits.minTemperatureC)-\(ClimateLimits.maxTemperatureC)"),
            "fan_range": .string("\(ClimateLimits.minFanLevel)-\(ClimateLimits.maxFanLevel)"),
            "limit_reached": .bool(limited),
        ]
        return VehicleToolOutcome(result: .success(data), chip: Self.chip(state))
    }

    public static func chip(_ s: ClimateState) -> String {
        "✓ 空调\(s.powerOn ? "开" : "关") · \(formatTemperature(s.targetTemperatureCelsius))°C · 风\(s.fanLevel)"
    }

    /// 24.0 → "24", 22.5 → "22.5".
    public static func formatTemperature(_ c: Double) -> String {
        c == c.rounded(.towardZero) ? String(Int64(c)) : String(c)
    }
}

/// `A/vehicle/SeatToolHandler.kt`.
public struct SeatToolHandler: Sendable {
    let port: any VehicleControlPort
    public init(port: any VehicleControlPort) { self.port = port }

    public func handle(_ args: [String: JSONValue]) async -> VehicleToolOutcome {
        guard let action = args["action"]?.stringValue else { return VehicleArgs.rejected(.missingAction, "action is required") }
        let seatArg = args["seat"]?.stringValue ?? "driver"
        guard let seat = SeatID(rawValue: seatArg) else { return VehicleArgs.rejected(.invalidValue, "unknown seat \(seatArg)") }
        var delta: Int?
        let result: VehicleActionResult<CabinState>
        switch action {
        case "set_height":
            guard let level = VehicleArgs.whole(args["value"]) else {
                return VehicleArgs.rejected(.invalidValue, "set_height needs a whole-number level")
            }
            result = await port.setSeatHeight(seat, level: level)
        case "adjust_height":
            guard let step = VehicleArgs.whole(args["value"]) else {
                return VehicleArgs.rejected(.missingValue, "adjust_height needs a signed whole-number step")
            }
            if step == 0 { return VehicleArgs.rejected(.invalidValue, "adjust_height step must not be 0") }
            delta = step
            result = await port.changeSeatHeight(seat, delta: step)
        case "get_state": result = .success(await port.cabinState(), limitReached: false)
        default: return VehicleArgs.rejected(.actionNotAllowed, "unknown action \(action)")
        }
        guard case .success(let state, let limited) = result else { return VehicleArgs.failure(action, result) }
        let level = state.seatHeights[seat] ?? CabinLimits.seatDefault
        let data: [String: JSONValue] = [
            "action": .string(action), "seat": .string(seatArg), "seat_height": .int(Int64(level)),
            "limit_reached": .bool(limited),
            "announce": .string(ActionAnnouncement.seat(action, seat, level, limited, delta)),
            "instruction": .string(VehicleArgs.announceInstruction),
        ]
        return VehicleToolOutcome(result: .success(data), chip: Self.chip(seat, level))
    }

    public static func chip(_ seat: SeatID, _ level: Int) -> String {
        seat == .driver ? "✓ 座椅 \(level)档" : "✓ 副驾座椅 \(level)档"
    }
}

/// `A/vehicle/WindowToolHandler.kt`.
public struct WindowToolHandler: Sendable {
    public static let targets: [String: Set<WindowID>] = [
        "all": Set(WindowID.allCases), "front": [.frontLeft, .frontRight], "rear": [.rearLeft, .rearRight],
        "driver": [.frontLeft], "passenger": [.frontRight], "front_left": [.frontLeft], "front_right": [.frontRight],
        "rear_left": [.rearLeft], "rear_right": [.rearRight],
    ]

    let port: any VehicleControlPort
    public init(port: any VehicleControlPort) { self.port = port }

    public func handle(_ args: [String: JSONValue]) async -> VehicleToolOutcome {
        guard let action = args["action"]?.stringValue else { return VehicleArgs.rejected(.missingAction, "action is required") }
        let windowArg = args["window"]?.stringValue ?? "all"
        guard let targets = Self.targets[windowArg] else {
            return VehicleArgs.rejected(.invalidValue, "unknown window \(windowArg)")
        }
        let value = args["value"]
        var delta: Int?
        let result: VehicleActionResult<CabinState>
        switch action {
        case "open": result = await port.setWindows(targets, openPercent: CabinLimits.windowMax)
        case "close": result = await port.setWindows(targets, openPercent: CabinLimits.windowMin)
        case "set":
            guard let percent = VehicleArgs.whole(value) else {
                return VehicleArgs.rejected(.invalidValue, "set needs a whole-number percent")
            }
            result = await port.setWindows(targets, openPercent: percent)
        case "adjust":
            let step = value == nil ? CabinLimits.defaultWindowStep : VehicleArgs.whole(value)
            guard let step else { return VehicleArgs.rejected(.invalidValue, "adjust value must be a whole number") }
            if step == 0 { return VehicleArgs.rejected(.invalidValue, "adjust value must not be 0") }
            delta = step
            result = await port.changeWindows(targets, deltaPercent: step)
        case "get_state": result = .success(await port.cabinState(), limitReached: false)
        default: return VehicleArgs.rejected(.actionNotAllowed, "unknown action \(action)")
        }
        guard case .success(let state, let limited) = result else { return VehicleArgs.failure(action, result) }
        let windows = JSONValue.object(Dictionary(uniqueKeysWithValues: WindowID.allCases.map {
            ($0.rawValue, JSONValue.int(Int64(state.windows[$0] ?? 0)))
        }))
        let data: [String: JSONValue] = [
            "action": .string(action), "window": .string(windowArg), "windows": windows,
            "limit_reached": .bool(limited),
            "announce": .string(ActionAnnouncement.window(action, targets, state, limited, delta)),
            "instruction": .string(VehicleArgs.announceInstruction),
        ]
        return VehicleToolOutcome(result: .success(data), chip: Self.chip(state))
    }

    /// 「✓ 车窗 50%」 when all agree, 「✓ 车窗 前50% 后0%」 by row, else every window.
    public static func chip(_ state: CabinState) -> String {
        let w = state.windows
        let fl = w[.frontLeft] ?? 0, fr = w[.frontRight] ?? 0, rl = w[.rearLeft] ?? 0, rr = w[.rearRight] ?? 0
        if Set([fl, fr, rl, rr]).count == 1 { return "✓ 车窗 \(fl)%" }
        if fl == fr && rl == rr { return "✓ 车窗 前\(fl)% 后\(rl)%" }
        return "✓ 车窗 左前\(fl)% 右前\(fr)% 左后\(rl)% 右后\(rr)%"
    }
}

/// `A/vehicle/ActionAnnouncement.kt`: the sentence after a body action, built from the state read back.
public enum ActionAnnouncement {
    static let front: Set<WindowID> = [.frontLeft, .frontRight]
    static let rear: Set<WindowID> = [.rearLeft, .rearRight]
    static let all = Set(WindowID.allCases)

    public static func windowName(_ id: WindowID) -> String {
        switch id {
        case .frontLeft: "主驾车窗"
        case .frontRight: "副驾车窗"
        case .rearLeft: "左后车窗"
        case .rearRight: "右后车窗"
        }
    }

    static func groupName(_ targets: Set<WindowID>) -> String? {
        if targets == all { return "车窗都" }
        if targets == front { return "前排车窗" }
        if targets == rear { return "后排车窗" }
        return targets.count == 1 ? windowName(targets.first!) : nil
    }

    public static func window(_ action: String, _ targets: Set<WindowID>, _ state: CabinState, _ limitReached: Bool,
                              _ delta: Int? = nil) -> String {
        if action == "get_state" { return windowState(state) }
        let values = Set(targets.map { state.windows[$0] ?? 0 })
        let name = groupName(targets)
        let atEnd = delta.map { d in values.count == 1 && values.first == (d > 0 ? CabinLimits.windowMax : CabinLimits.windowMin) }
            ?? false
        if limitReached, atEnd, let name {
            let subject = targets == all ? "车窗" : name
            return delta! > 0 ? "\(subject)已经全开了" : "\(subject)已经关到底了"
        }
        if values.count == 1, let name {
            let value = values.first!
            if targets == all {
                switch value {
                case CabinLimits.windowMax: return "车窗都打开了"
                case CabinLimits.windowMin: return "车窗都关好了"
                case 50: return "车窗都开了一半"
                default: return "车窗都开到了\(value)%"
                }
            }
            switch value {
            case CabinLimits.windowMax: return "\(name)全打开了"
            case CabinLimits.windowMin: return "\(name)关好了"
            default: return "\(name)开到了\(value)%"
            }
        }
        return WindowID.allCases.filter(targets.contains)
            .map { perWindow($0, state.windows[$0] ?? 0, "开到了", "关好了") }.joined(separator: "，")
    }

    static func windowState(_ state: CabinState) -> String {
        let values = Set(state.windows.values)
        if values.count == 1 {
            switch values.first! {
            case CabinLimits.windowMin: return "车窗现在都关着"
            case CabinLimits.windowMax: return "车窗现在都全开着"
            case let v: return "车窗现在都开着\(v)%"
            }
        }
        return "现在" + WindowID.allCases.map { perWindow($0, state.windows[$0] ?? 0, "开着", "关着") }.joined(separator: "，")
    }

    static func perWindow(_ id: WindowID, _ value: Int, _ openVerb: String, _ closed: String) -> String {
        value == CabinLimits.windowMin ? "\(windowName(id))\(closed)" : "\(windowName(id))\(openVerb)\(value)%"
    }

    public static func seat(_ action: String, _ seat: SeatID, _ level: Int, _ limitReached: Bool, _ delta: Int? = nil) -> String {
        let name = seat == .driver ? "座椅" : "副驾座椅"
        switch action {
        case "adjust_height":
            let step = delta ?? 0
            if limitReached && step < 0 { return "\(name)已经是最低了" }
            if limitReached { return "\(name)已经是最高了" }
            return step < 0 ? "\(name)降低了\(steps(-step))档，现在是\(level)档" : "\(name)升高了\(steps(step))档，现在是\(level)档"
        case "set_height": return "\(name)调到了\(level)档"
        default: return "\(name)现在是\(level)档"
        }
    }

    static func steps(_ n: Int) -> String { n == 1 ? "一" : String(n) }

    public static func climate(_ action: String, powerOn: Bool, temperatureC: Double, fanLevel: Int) -> String {
        let degrees = ClimateToolHandler.formatTemperature(temperatureC)
        switch action {
        case "power_on": return "空调打开了"
        case "power_off": return "空调关了"
        case "set_temperature", "adjust_temperature": return "温度调到了\(degrees)度"
        case "set_fan", "adjust_fan": return "风量调到了\(fanLevel)档"
        default: return powerOn ? "空调现在\(degrees)度，风\(fanLevel)档" : "空调现在关着"
        }
    }
}

/// Routes the three vehicle tools to their handlers (M1 executors, ios-architecture §8).
public struct VehicleToolExecutor: ToolExecutor {
    let climate: ClimateToolHandler
    let seat: SeatToolHandler
    let window: WindowToolHandler

    public init(port: any VehicleControlPort) {
        climate = ClimateToolHandler(port: port)
        seat = SeatToolHandler(port: port)
        window = WindowToolHandler(port: port)
    }

    public static let tools: Set<String> = ["control_climate", "control_seat", "control_window"]

    public func outcome(_ call: ToolCall) async -> VehicleToolOutcome {
        guard case .object(let args) = call.arguments else { return VehicleArgs.rejected(.malformedJson, "arguments") }
        switch call.name {
        case "control_climate": return await climate.handle(args)
        case "control_seat": return await seat.handle(args)
        case "control_window": return await window.handle(args)
        default: return VehicleArgs.rejected(.unknownTool, call.name)
        }
    }

    public func execute(_ call: ToolCall) async -> ToolResult { await outcome(call).result }
}
