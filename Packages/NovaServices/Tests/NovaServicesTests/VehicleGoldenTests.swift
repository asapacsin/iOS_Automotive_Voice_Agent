import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaServices

// Golden cases ported from the Android `T/vehicle/*Test.kt` files (commit 9c53929): the same call
// sequence must give the same payload, announcement and chip.

struct Car {
    let port: SimulatedVehicle
    init(port: SimulatedVehicle = SimulatedVehicle()) { self.port = port }
    var window: WindowToolHandler { WindowToolHandler(port: port) }
    var seat: SeatToolHandler { SeatToolHandler(port: port) }
    var climate: ClimateToolHandler { ClimateToolHandler(port: port) }

    func w(_ args: [String: JSONValue]) async -> VehicleToolOutcome { await window.handle(args) }
    func s(_ args: [String: JSONValue]) async -> VehicleToolOutcome { await seat.handle(args) }
    func c(_ args: [String: JSONValue]) async -> VehicleToolOutcome { await climate.handle(args) }
}

extension VehicleToolOutcome {
    var announce: String? { result.data["announce"]?.stringValue }
    func window(_ id: String) -> Int64? { result.data["windows"]?[id]?.intValue }
}

@Suite("T-018 F-11 window golden files")
struct WindowGoldenTests {
    @Test("F-11 opening halfway sets every window and says so")
    func half() async {
        let car = Car()
        let o = await car.w(["action": "set", "value": 50])
        #expect(o.result.ok && o.result.data["limit_reached"] == false)
        for id in ["front_left", "front_right", "rear_left", "rear_right"] { #expect(o.window(id) == 50) }
        #expect(o.announce == "车窗都开了一半")
        #expect(o.result.data["instruction"]?.stringValue?.contains("announce") == true)
        #expect(o.chip == "✓ 车窗 50%")
        #expect(await car.port.cabinState().windows[.rearRight] == 50)
    }

    @Test("F-11 open and close are full and zero")
    func openClose() async {
        let car = Car()
        #expect(await car.w(["action": "open"]).announce == "车窗都打开了")
        #expect(await car.port.cabinState().windows[.frontLeft] == 100)
        #expect(await car.w(["action": "close"]).announce == "车窗都关好了")
        #expect(await car.port.cabinState().windows[.frontLeft] == 0)
    }

    @Test("F-11 the driver window adjusts from the current state; default step; row chip")
    func driverAndDefault() async {
        let car = Car()
        _ = await car.w(["action": "set", "window": "driver", "value": 20])
        let o = await car.w(["action": "adjust", "window": "driver", "value": 20])
        #expect(o.window("front_left") == 40 && o.window("front_right") == 0)
        #expect(o.announce == "主驾车窗开到了40%")
        #expect(o.chip == "✓ 车窗 左前40% 右前0% 左后0% 右后0%")
        let fresh = Car()
        let d = await fresh.w(["action": "adjust", "window": "front"])
        #expect(d.window("front_right") == 20 && d.announce == "前排车窗开到了20%")
        #expect(await Car().w(["action": "set", "window": "front", "value": 50]).chip == "✓ 车窗 前50% 后0%")
    }

    @Test("F-11 clamping reports the limit; one clamped window does not make the group full")
    func clamping() async {
        let car = Car()
        _ = await car.w(["action": "set", "value": 90])
        let o = await car.w(["action": "adjust", "value": 20])
        #expect(o.result.data["limit_reached"] == true && o.window("rear_left") == 100)
        #expect(o.announce == "车窗已经全开了")
        let closed = await car.w(["action": "adjust", "window": "passenger", "value": -150])
        #expect(closed.result.data["limit_reached"] == true && closed.announce == "副驾车窗已经关到底了")

        let other = Car()
        _ = await other.w(["action": "set", "window": "driver", "value": 90])
        let front = await other.w(["action": "adjust", "window": "front", "value": 20])
        #expect(front.result.data["limit_reached"] == true)
        #expect(!(front.announce!.contains("全开")) && front.announce!.contains("副驾车窗开到了20%"))
        _ = await other.w(["action": "close"])
        _ = await other.w(["action": "set", "window": "driver", "value": 90])
        let all = await other.w(["action": "adjust", "value": 20])
        #expect(all.result.data["limit_reached"] == true)
        #expect(!(all.announce!.contains("全开")) && all.announce!.contains("副驾车窗开到了20%"))
    }

    @Test("F-11 get_state reads back without changing; a zero adjust is rejected")
    func stateAndZero() async {
        let car = Car()
        _ = await car.w(["action": "set", "value": 30])
        let o = await car.w(["action": "get_state"])
        #expect(o.result.ok && o.announce == "车窗现在都开着30%")
        #expect(await car.port.cabinState().windows[.frontLeft] == 30)
        #expect(await car.w(["action": "adjust", "value": 0]).result.code == .invalidValue)
    }

    @Test("F-11 invalid requests are ok=false with no announcement and change nothing")
    func invalid() async {
        let car = Car()
        let cases: [([String: JSONValue], ToolErrorCode)] = [
            (["action": "set", "value": 150], .invalidArgument), (["action": "set"], .invalidValue),
            (["action": "set", "value": 12.5], .invalidValue), (["action": "open", "window": "sunroof"], .invalidValue),
            (["action": "fly"], .actionNotAllowed), ([:], .missingAction),
        ]
        for (args, code) in cases {
            let o = await car.w(args)
            #expect(!o.result.ok && o.result.code == code, "\(args)")
            #expect(o.announce == nil && o.chip == nil)
            #expect(o.result.data["instruction"]?.stringValue == "操作没有成功。如实告诉用户没有完成，不要说已经完成。")
        }
        #expect(await car.port.cabinState() == .default)
    }
}

@Suite("T-018 F-11 seat golden files")
struct SeatGoldenTests {
    @Test("F-11 lowering one step reads back the new height")
    func lower() async {
        let car = Car()
        let o = await car.s(["action": "adjust_height", "value": -1])
        #expect(o.result.ok && o.result.data["seat"] == "driver" && o.result.data["seat_height"] == 4)
        #expect(o.result.data["limit_reached"] == false)
        #expect(o.announce == "座椅降低了一档，现在是4档" && o.chip == "✓ 座椅 4档")
        #expect(await car.port.cabinState().seatHeights == [.driver: 4, .passenger: 5])
    }

    @Test("F-11 raising, setting, clamping and get_state")
    func others() async {
        let car = Car()
        #expect(await car.s(["action": "adjust_height", "value": 1]).announce == "座椅升高了一档，现在是6档")
        let p = await car.s(["action": "set_height", "seat": "passenger", "value": 2])
        #expect(p.announce == "副驾座椅调到了2档" && p.chip == "✓ 副驾座椅 2档")
        _ = await car.s(["action": "set_height", "value": 0])
        let low = await car.s(["action": "adjust_height", "value": -1])
        #expect(low.result.data["limit_reached"] == true && low.result.data["seat_height"] == 0 && low.announce == "座椅已经是最低了")
        _ = await car.s(["action": "set_height", "value": 10])
        let high = await car.s(["action": "adjust_height", "value": 3])
        #expect(high.result.data["limit_reached"] == true && high.announce == "座椅已经是最高了")
        let fresh = Car()
        let g = await fresh.s(["action": "get_state"])
        #expect(g.result.data["seat_height"] == 5 && g.announce == "座椅现在是5档")
        #expect(await fresh.s(["action": "adjust_height"]).result.code == .missingValue)
    }
}

@Suite("T-018 F-11 climate golden files")
struct ClimateGoldenTests {
    @Test("F-11 power on reads back the state, chip and ranges")
    func powerOn() async {
        let car = Car(port: SimulatedVehicle(climate: ClimateState(powerOn: false, targetTemperatureCelsius: 22, fanLevel: 3)))
        let o = await car.c(["action": "power_on"])
        #expect(o.result.ok && o.result.data["power_on"] == true && o.result.data["temperature_c"] == .double(22))
        #expect(o.result.data["fan_level"] == 3 && o.result.data["limit_reached"] == false)
        #expect(o.result.data["temperature_range_c"] == "16.0-32.0" && o.result.data["fan_range"] == "0-7")
        #expect(o.chip == "✓ 空调开 · 22°C · 风3" && o.result.code == nil)
    }

    @Test("F-11 relative steps use the current state and defaults; clamping sets limit_reached")
    func relative() async {
        let car = Car()
        #expect(await car.c(["action": "adjust_temperature"]).result.data["temperature_c"] == .double(25))
        #expect(await car.c(["action": "adjust_temperature", "value": -2]).result.data["temperature_c"] == .double(23))
        #expect(await car.c(["action": "set_temperature", "value": 22.5]).chip == "✓ 空调关 · 22.5°C · 风2")
        #expect(await car.c(["action": "set_fan", "value": 3.0]).result.data["fan_level"] == 3)
        _ = await car.c(["action": "set_fan", "value": 7])
        let limited = await car.c(["action": "adjust_fan"])
        #expect(limited.result.data["limit_reached"] == true && limited.result.data["fan_level"] == 7)
    }

    @Test("F-11 each injected fault is ok=false with its code and no state")
    func faults() async {
        let cases: [(InjectedClimateFailure, ToolErrorCode)] = [
            (.unsupported, .vehicleUnsupported), (.unavailable, .vehicleUnavailable),
            (.permissionDenied, .vehiclePermissionDenied), (.executionFailure, .vehicleExecutionFailed),
        ]
        for (fault, code) in cases {
            let car = Car()
            car.port.failNext(fault)
            let o = await car.c(["action": "power_on"])
            #expect(!o.result.ok && o.result.code == code && o.chip == nil)
            #expect(o.result.data["instruction"]?.stringValue?.contains("不要说已经完成") == true)
            #expect(o.result.data["power_on"] == nil, "a failure must not present a state")
            #expect(await car.port.climateState().powerOn == false)
            #expect(await car.c(["action": "power_on"]).result.ok, "failNext fails exactly one call")
        }
        let car = Car()
        car.port.failAlways(.setFan, .unavailable)
        for _ in 0..<2 { #expect(await car.c(["action": "set_fan", "value": 3]).result.code == .vehicleUnavailable) }
        #expect(await car.c(["action": "power_on"]).result.ok)
    }

    @Test("F-11 invalid climate requests make no port call")
    func invalid() async {
        let car = Car()
        for args: [String: JSONValue] in [["action": "open_sunroof"], ["action": "set_temperature"],
                                          ["action": "set_temperature", "value": "warm"], ["action": "set_fan", "value": 2.5],
                                          ["action": "adjust_fan", "value": "lots"], ["action": "adjust_temperature", "value": "hot"]] {
            #expect(!(await car.c(args)).result.ok, "\(args)")
        }
        #expect(await car.port.climateState() == .default)
        #expect(car.port.backendLabel == "simulated")
    }
}

@Suite("T-018 F-11 announcements and the sunroof refusal")
struct AnnouncementTests {
    func windows(_ fl: Int, _ fr: Int? = nil, _ rl: Int? = nil, _ rr: Int? = nil) -> CabinState {
        CabinState(windows: [.frontLeft: fl, .frontRight: fr ?? fl, .rearLeft: rl ?? fl, .rearRight: rr ?? fl],
                   seatHeights: CabinState.default.seatHeights)
    }
    let all = Set(WindowID.allCases)

    @Test("F-11 window, limit, state and seat sentences equal Android")
    func sentences() {
        #expect(ActionAnnouncement.window("set", all, windows(30), false) == "车窗都开到了30%")
        #expect(ActionAnnouncement.window("adjust", [.frontLeft, .frontRight], windows(40, 20, 0, 0), false, 20)
                == "主驾车窗开到了40%，副驾车窗开到了20%")
        #expect(ActionAnnouncement.window("adjust", all, windows(0), true, -20) == "车窗已经关到底了")
        #expect(ActionAnnouncement.window("adjust", [.rearLeft, .rearRight], windows(50, 50, 0, 0), true, -20) == "后排车窗已经关到底了")
        #expect(ActionAnnouncement.window("get_state", all, windows(0), false) == "车窗现在都关着")
        #expect(ActionAnnouncement.window("get_state", all, windows(40, 0, 0, 0), false)
                == "现在主驾车窗开着40%，副驾车窗关着，左后车窗关着，右后车窗关着")
        #expect(ActionAnnouncement.seat("adjust_height", .driver, 7, false, 2) == "座椅升高了2档，现在是7档")
        #expect(ActionAnnouncement.seat("adjust_height", .passenger, 10, true, 1) == "副驾座椅已经是最高了")
        #expect(ActionAnnouncement.seat("set_height", .driver, 3, false) == "座椅调到了3档")
    }

    @Test("F-11 打开天窗 is refused with UNSUPPORTED_BODY_PART and no window moves")
    func sunroof() async {
        let car = Car()
        let executor = VehicleToolExecutor(port: car.port)
        var dispatcher = ToolDispatcher()
        let open = ToolCall(id: CallID("c1")!, name: "control_window", arguments: ["action": "open", "window": "all"])
        let context = GuardContext(requestText: "帮我把天窗打开。", currentEpoch: 1, capabilityEpoch: 1)
        switch dispatcher.decide(open, context: context) {
        case .refuse(let r): #expect(r.code == .unsupportedBodyPart)
        case .execute(let c): _ = await executor.execute(c); Issue.record("window tool ran")
        }
        #expect(await car.port.cabinState() == .default)
    }
}
