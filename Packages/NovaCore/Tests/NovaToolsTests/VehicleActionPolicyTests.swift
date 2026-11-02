import Synchronization
import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

@Suite("T-031b F-12 §14 vehicle action policy and catalog")
struct VehicleActionPolicyTests {
    static func policed(_ fake: FakeVehicle, speed: Double?) -> PolicedVehiclePort {
        PolicedVehiclePort(fake, speedKmh: { speed })
    }

    @Test("F-12 row 5 policy: outside the limits; 50% at 120 km/h; 20% at 120 km/h; 50% with unknown speed")
    func rules() {
        let closed = CabinState.default
        let all = Set(WindowID.allCases)
        #expect(VehicleActionPolicy.check(.setTemperature(40), cabin: closed, speedKmh: nil) == .outOfRange)
        #expect(VehicleActionPolicy.check(.setFan(9), cabin: closed, speedKmh: nil) == .outOfRange)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 120), cabin: closed, speedKmh: nil) == .outOfRange)
        #expect(VehicleActionPolicy.check(.setSeat(.driver, level: 11), cabin: closed, speedKmh: nil) == .outOfRange)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 50), cabin: closed, speedKmh: 120) == .windowAtSpeed)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 20), cabin: closed, speedKmh: 120) == nil)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 50), cabin: closed, speedKmh: nil) == nil)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 50), cabin: closed, speedKmh: 100) == nil)
        // A relative open that ends above the limit is blocked; closing never is.
        #expect(VehicleActionPolicy.check(.changeWindows(all, delta: 40), cabin: closed, speedKmh: 120) == .windowAtSpeed)
        var open = closed
        for w in WindowID.allCases { open.windows[w] = 80 }
        #expect(VehicleActionPolicy.check(.changeWindows(all, delta: -20), cabin: open, speedKmh: 120) == nil)
        #expect(VehicleActionPolicy.check(.setWindows(all, percent: 0), cabin: open, speedKmh: 120) == nil)
    }

    @Test("F-12 row 5 both paths: a direct window call and the scenario table are blocked by the same port")
    func bothPaths() async {
        let fake = FakeVehicle()
        let port = Self.policed(fake, speed: 120)
        let direct = await WindowToolHandler(port: port).handle(["action": "set", "value": .int(50)])
        #expect(direct.result.ok == false)
        #expect(direct.result.code == .vehicleBlocked)
        #expect(direct.result.data["blocked"] == .string("window_at_speed"))
        #expect(direct.result.advice != nil)
        let allowed = await WindowToolHandler(port: port).handle(["action": "set", "value": .int(20)])
        #expect(allowed.result.ok)
        // The table opens all windows 50% for 有蚊子: blocked, the windows stay at 20%, and the result says so.
        let table = await ScenarioToolHandler(port: port).outcome(scenario("mosquito"))
        #expect(table.result.ok == false)
        #expect(table.result.code == .vehicleBlocked)
        #expect(windows(await fake.cabinState()) == [20, 20, 20, 20])
        // Unknown speed: allowed.
        let unknown = await WindowToolHandler(port: Self.policed(fake, speed: nil)).handle(["action": "set", "value": .int(50)])
        #expect(unknown.result.ok)
        let climate = await ClimateToolHandler(port: port).handle(["action": "set_temperature", "value": .int(40)])
        #expect(climate.result.code == .vehicleBlocked)
    }

    @Test("F-12 row 3 setting off: catalog equals today's")
    func offUnchanged() {
        #expect(ToolCatalog.declarations(for: .table) == ToolCatalog.declarations)
        #expect(ToolCatalog.declarations.contains { $0.name == "run_scenario" })
        #expect(!ToolCatalog.declarations.contains { $0.name == "get_vehicle_state" })
    }

    @Test("F-12 row 4 setting on: no run_scenario, get_vehicle_state present, no feeling rules in control_climate")
    func onCatalog() {
        let on = ToolCatalog.declarations(for: .model)
        let names = on.map(\.name)
        #expect(!names.contains("run_scenario"))
        #expect(names.contains("get_vehicle_state"))
        #expect(Set(names) == Set(ToolCatalog.declarations.map(\.name)).subtracting(["run_scenario"]).union(["get_vehicle_state"]))
        let climate = on.first { $0.name == "control_climate" }!
        #expect(!climate.description.contains("run_scenario"))
        #expect(!climate.description.contains("有点热"))
        #expect(climate.description.contains("打开/关闭空调"))
        #expect(climate.parametersJSONSchema == ToolCatalog.spec("control_climate")!.declaration.parametersJSONSchema)
        // Every other tool is unchanged.
        for d in on where d.name != "control_climate" && d.name != "get_vehicle_state" {
            #expect(ToolCatalog.declarations.contains(d))
        }
        #expect(ToolCatalog.validate(call("get_vehicle_state")) == nil)
        #expect(ToolCatalog.validate(call("get_vehicle_state", ["x": .int(1)])) == .invalidFields)
    }

    @Test("F-12 row 4 get_vehicle_state: state, speed or null, no location fields")
    func stateTool() async {
        let fake = FakeVehicle()
        _ = await fake.setWindows([.frontLeft], openPercent: 40)
        let music = FakeMusic()
        _ = await music.playBundled()
        let tool = VehicleStateTool(port: fake, music: music, navigating: { true }, speedKmh: { 63.6 })
        let r = await tool.execute(call("get_vehicle_state"))
        #expect(r.ok)
        #expect(Set(r.data.keys) == VehicleStateTool.fields)
        #expect(r.data["speed_kmh"] == .int(64))
        #expect(r.data["music_playing"] == .bool(true))
        #expect(r.data["navigating"] == .bool(true))
        guard case .object(let w)? = r.data["windows"] else { Issue.record("windows"); return }
        #expect(w["front_left"] == .int(40))
        for key in r.data.keys {
            for banned in ["lat", "lon", "coordinate", "address", "location"] { #expect(!key.contains(banned)) }
        }
        let unknown = await VehicleStateTool(port: fake, music: nil, navigating: { false }, speedKmh: { nil })
            .execute(call("get_vehicle_state"))
        #expect(unknown.data["speed_kmh"] == .null)
    }
}
