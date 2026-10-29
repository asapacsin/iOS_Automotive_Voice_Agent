import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

/// In-memory vehicle with per-operation failure injection.
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

func scenario(_ name: String) -> ToolCall { call("run_scenario", ["name": .string(name)]) }

func windows(_ state: CabinState) -> [Int] { WindowID.allCases.map { state.windows[$0] ?? -1 } }

@Suite("F-12 comfort scenarios")
struct ScenarioToolHandlerTests {
    @Test("every catalog scenario has a step table")
    func catalogCovered() {
        for name in ToolCatalog.scenarios {
            #expect(ScenarioToolHandler.steps(name, mosquitoActive: false) != nil)
        }
    }

    @Test("有蚊子 → all windows half open")
    func mosquito() async {
        let car = FakeVehicle()
        let result = await ScenarioToolHandler(port: car).execute(scenario("mosquito"))
        #expect(result.ok)
        #expect(windows(await car.cabinState()) == [50, 50, 50, 50])
        #expect(await car.climateState() == .default)
        #expect(result.data["announce"]?.stringValue == "车窗都开了一半")
    }

    @Test("蚊子还没走 → AC on, fan +1, windows untouched")
    func mosquitoAgain() async {
        let car = FakeVehicle()
        let handler = ScenarioToolHandler(port: car)
        _ = await handler.execute(scenario("mosquito"))
        let result = await handler.execute(scenario("mosquito"))
        #expect(result.ok)
        let climate = await car.climateState()
        #expect(climate.powerOn && climate.fanLevel == ClimateState.default.fanLevel + 1)
        #expect(windows(await car.cabinState()) == [50, 50, 50, 50])
        #expect(result.data["announce"]?.stringValue == "空调打开了，风量调到了3档")
    }

    @Test("蚊子出去了 after mosquito → windows closed")
    func mosquitoDone() async {
        let car = FakeVehicle()
        let handler = ScenarioToolHandler(port: car)
        _ = await handler.execute(scenario("mosquito"))
        let result = await handler.execute(scenario("mosquito_done"))
        #expect(result.ok)
        #expect(windows(await car.cabinState()) == [0, 0, 0, 0])
        #expect(result.data["announce"]?.stringValue == "车窗都关好了")
        // The flag is cleared: a second mosquito_done is refused again.
        #expect(await handler.execute(scenario("mosquito_done")).code == .noRecentMosquito)
    }

    @Test("mosquito_done without a recent mosquito → NO_RECENT_MOSQUITO, nothing moved")
    func noRecentMosquito() async {
        let car = FakeVehicle()
        let result = await ScenarioToolHandler(port: car).execute(scenario("mosquito_done"))
        #expect(!result.ok)
        #expect(result.code == .noRecentMosquito)
        #expect(result.advice == ToolFailureAdvice.forCode(.noRecentMosquito))
        #expect(car.calls.isEmpty)
    }

    @Test("有点闷 → AC on, fan +1, front windows 20")
    func stuffy() async {
        let car = FakeVehicle()
        let result = await ScenarioToolHandler(port: car).execute(scenario("stuffy"))
        #expect(result.ok)
        let climate = await car.climateState()
        #expect(climate.powerOn && climate.fanLevel == 3)
        #expect(windows(await car.cabinState()) == [20, 20, 0, 0])
        #expect(result.data["announce"]?.stringValue == "空调打开了，风量调到了3档，前排车窗开到了20%")
    }

    @Test("好困 → AC on, temp −2, front windows 20, music, rest-stop suggestion")
    func drowsy() async {
        let car = FakeVehicle()
        let music = FakeMusic()
        let result = await ScenarioToolHandler(port: car, music: music).execute(scenario("drowsy"))
        #expect(result.ok)
        let climate = await car.climateState()
        #expect(climate.powerOn && climate.targetTemperatureCelsius == 22)
        #expect(windows(await car.cabinState()) == [20, 20, 0, 0])
        #expect(await music.isPlaying)
        #expect(result.data["suggest_rest_stop"] == .bool(true))
        #expect(result.data["announce"]?.stringValue?.contains("音乐放起来了") == true)
        #expect(result.data["announce"]?.stringValue?.contains("服务区") == true)
    }

    @Test("a failed step → ok=false, partial, instruction names done and not done; no claim of the failed step")
    func partialFailure() async {
        let car = FakeVehicle(failing: ["windows"])
        let result = await ScenarioToolHandler(port: car).execute(scenario("stuffy"))
        #expect(!result.ok)
        #expect(result.code == .vehicleExecutionFailed)
        #expect(result.data["status"]?.stringValue == "partial")
        #expect(result.data["done"] == .array([.string("打开空调"), .string("风量调大一档")]))
        #expect(result.data["not_done"] == .array([.string("前排车窗开到20%")]))
        let instruction = result.data["instruction"]?.stringValue ?? ""
        #expect(instruction.contains("没做成：前排车窗开到20%"))
        #expect(instruction.contains("不要说整个场景都完成了"))
        #expect(result.data["announce"]?.stringValue?.contains("车窗") == false)
        #expect(windows(await car.cabinState()) == [0, 0, 0, 0])
    }

    @Test("drowsy without a music player is partial, music not claimed")
    func drowsyNoMusic() async {
        let result = await ScenarioToolHandler(port: FakeVehicle()).execute(scenario("drowsy"))
        #expect(!result.ok)
        #expect(result.data["not_done"] == .array([.string("播放音乐")]))
        #expect(result.data["announce"]?.stringValue?.contains("音乐") == false)
    }

    @Test("a failed mosquito window step does not arm mosquito_done")
    func failedMosquitoDoesNotArm() async {
        let handler = ScenarioToolHandler(port: FakeVehicle(failing: ["windows"]))
        let first = await handler.execute(scenario("mosquito"))
        #expect(!first.ok && first.data["status"]?.stringValue == "failed")
        #expect(await handler.execute(scenario("mosquito_done")).code == .noRecentMosquito)
    }

    @Test("unknown or missing name is rejected")
    func rejected() async {
        let handler = ScenarioToolHandler(port: FakeVehicle())
        #expect(await handler.execute(scenario("party")).code == .invalidValue)
        #expect(await handler.execute(call("run_scenario")).code == .missingValue)
    }
}
