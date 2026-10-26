import NovaKit
import NovaPorts
import Synchronization

/// One vehicle (or music) action inside a comfort scenario (F-12 §2).
public enum ScenarioStep: Sendable, Hashable {
    case acOn
    case fanUp
    case temperatureDown2
    case windows(Set<WindowID>, percent: Int)
    case musicPlay

    /// The name used in `done` / `not_done` and in the failure instruction.
    var label: String {
        switch self {
        case .acOn: "打开空调"
        case .fanUp: "风量调大一档"
        case .temperatureDown2: "温度降低2度"
        case .windows(let targets, let percent):
            if percent == CabinLimits.windowMin {
                "关车窗"
            } else if targets == ActionAnnouncement.all {
                "车窗开到\(percent)%"
            } else {
                "\(ActionAnnouncement.groupName(targets) ?? "车窗")开到\(percent)%"
            }
        case .musicPlay: "播放音乐"
        }
    }
}

/// `run_scenario` (F-12): runs the scenario's steps in order through the same vehicle port as the
/// other vehicle tools and announces only what the state read back shows (I-14). A failed step makes
/// the result ok=false with an instruction naming what did and did not happen (ActionClaimGuard).
public final class ScenarioToolHandler: ToolExecutor {
    public static let tool = "run_scenario"
    static let front: Set<WindowID> = [.frontLeft, .frontRight]
    static let all = Set(WindowID.allCases)

    let port: any VehicleControlPort
    let music: (any MusicPort)?
    /// True after `mosquito` opened the windows, until `mosquito_done` closes them.
    /// PROPOSED: Android's exact notion of "recent" (any expiry) is not in the spec; no expiry here.
    private let mosquitoWindowsOpen = Mutex(false)

    public init(port: any VehicleControlPort, music: (any MusicPort)? = nil) {
        self.port = port
        self.music = music
    }

    /// The step table of F-12 §2. `mosquito` depends on whether a previous `mosquito` opened the windows.
    static func steps(_ name: String, mosquitoActive: Bool) -> [ScenarioStep]? {
        switch name {
        case "mosquito":
            // 有蚊子 → windows half open; 蚊子还没走 → AC on, fan +1 (windows untouched).
            mosquitoActive ? [.acOn, .fanUp] : [.windows(all, percent: 50)]
        case "mosquito_done": [.windows(all, percent: CabinLimits.windowMin)]
        case "stuffy": [.acOn, .fanUp, .windows(front, percent: 20)]
        case "drowsy": [.acOn, .temperatureDown2, .windows(front, percent: 20), .musicPlay]
        default: nil
        }
    }

    public func execute(_ call: ToolCall) async -> ToolResult { await outcome(call).result }

    public func outcome(_ call: ToolCall) async -> VehicleToolOutcome {
        guard case .object(let args) = call.arguments else { return VehicleArgs.rejected(.malformedJson, "arguments") }
        guard let name = args["name"]?.stringValue else { return VehicleArgs.rejected(.missingValue, "name is required") }
        let active = mosquitoWindowsOpen.withLock { $0 }
        if name == "mosquito_done" && !active {
            return VehicleToolOutcome(result: .failure(.noRecentMosquito, advice: ToolFailureAdvice.forCode(.noRecentMosquito),
                                                       data: ["scenario": .string(name)]), chip: nil)
        }
        guard let steps = Self.steps(name, mosquitoActive: active) else {
            return VehicleArgs.rejected(.invalidValue, "unknown scenario \(name)")
        }
        // PROPOSED: later steps still run after a failed one, so each step is reported on its own;
        // the spec only says "steps executed in order".
        var done: [ScenarioStep] = []
        var failed: [(ScenarioStep, ToolErrorCode, String)] = []
        for step in steps {
            if let failure = await run(step) { failed.append((step, failure.0, failure.1)) } else { done.append(step) }
        }
        updateMosquitoFlag(name, done: done)
        return await report(name, done: done, failed: failed)
    }

    private func updateMosquitoFlag(_ name: String, done: [ScenarioStep]) {
        let windowsMoved = done.contains { if case .windows = $0 { true } else { false } }
        guard windowsMoved else { return }
        if name == "mosquito" { mosquitoWindowsOpen.withLock { $0 = true } }
        if name == "mosquito_done" { mosquitoWindowsOpen.withLock { $0 = false } }
    }

    /// nil on success, else the failure code and detail.
    private func run(_ step: ScenarioStep) async -> (ToolErrorCode, String)? {
        switch step {
        case .acOn: return Self.failure(await port.setHvacPower(true))
        case .fanUp: return Self.failure(await port.changeFanLevel(ClimateLimits.defaultFanStep))
        case .temperatureDown2: return Self.failure(await port.changeCabinTemperature(-2))
        case .windows(let targets, let percent): return Self.failure(await port.setWindows(targets, openPercent: percent))
        case .musicPlay:
            guard let music else { return (.vehicleUnsupported, "no music player") }
            return await music.playBundled() ? nil : (.vehicleExecutionFailed, "music did not start")
        }
    }

    static func failure<S>(_ result: VehicleActionResult<S>) -> (ToolErrorCode, String)? {
        switch result {
        case .success: nil
        case .invalidArgument(let r): (.invalidArgument, r)
        case .unsupported(let f): (.vehicleUnsupported, f)
        case .unavailable(let r): (.vehicleUnavailable, r)
        case .permissionDenied(let r): (.vehiclePermissionDenied, r)
        case .failure(let r): (.vehicleExecutionFailed, r)
        }
    }

    private func report(_ name: String, done: [ScenarioStep], failed: [(ScenarioStep, ToolErrorCode, String)]) async
        -> VehicleToolOutcome {
        let climate = await port.climateState()
        let cabin = await port.cabinState()
        let playing = await music?.isPlaying ?? false
        var sentences = done.compactMap { Self.announce($0, climate, cabin, playing) }
        if name == "drowsy" { sentences.append("累了的话找个服务区休息一下吧") }
        let announce = sentences.joined(separator: "，")
        var data: [String: JSONValue] = [
            "scenario": .string(name),
            "done": .array(done.map { .string($0.label) }),
            "not_done": .array(failed.map { .string($0.0.label) }),
            "power_on": .bool(climate.powerOn), "temperature_c": .double(climate.targetTemperatureCelsius),
            "fan_level": .int(Int64(climate.fanLevel)),
            "windows": .object(Dictionary(uniqueKeysWithValues: WindowID.allCases.map {
                ($0.rawValue, JSONValue.int(Int64(cabin.windows[$0] ?? 0)))
            })),
        ]
        if name == "drowsy" { data["suggest_rest_stop"] = .bool(true) }
        guard let first = failed.first else {
            data["status"] = .string("done")
            data["announce"] = .string(announce)
            data["instruction"] = .string(VehicleArgs.announceInstruction)
            let chip = ClimateToolHandler.chip(climate) + " · " + String(WindowToolHandler.chip(cabin).dropFirst(2))
            return VehicleToolOutcome(result: .success(data), chip: chip)
        }
        data["status"] = .string(done.isEmpty ? "failed" : "partial")
        data["detail"] = .string(failed.map { "\($0.0.label): \($0.2)" }.joined(separator: "; "))
        if !announce.isEmpty { data["announce"] = .string(announce) }
        data["instruction"] = .string(Self.failureInstruction(done: done, failed: failed.map(\.0)))
        return VehicleToolOutcome(result: .failure(first.1, data: data), chip: nil)
    }

    static func failureInstruction(done: [ScenarioStep], failed: [ScenarioStep]) -> String {
        let didDo = done.isEmpty ? "什么都没做成" : "做成了：" + done.map(\.label).joined(separator: "、")
        let notDone = "没做成：" + failed.map(\.label).joined(separator: "、")
        return "场景只完成了一部分。\(didDo)。\(notDone)。"
            + "如实告诉用户哪些做了、哪些没做，不要说整个场景都完成了。"
    }

    /// The sentence for one finished step, from the state read back (I-14); nil if the read-back disagrees.
    static func announce(_ step: ScenarioStep, _ climate: ClimateState, _ cabin: CabinState, _ playing: Bool) -> String? {
        switch step {
        case .acOn:
            return climate.powerOn ? "空调打开了" : nil
        case .fanUp, .temperatureDown2:
            return ActionAnnouncement.climate(step == .fanUp ? "adjust_fan" : "adjust_temperature", powerOn: climate.powerOn,
                                              temperatureC: climate.targetTemperatureCelsius, fanLevel: climate.fanLevel)
        case .windows(let targets, _):
            return ActionAnnouncement.window("set", targets, cabin, false)
        case .musicPlay:
            return playing ? "音乐放起来了" : nil
        }
    }
}
