import NovaKit
import NovaServices
import NovaTools
import SwiftUI

/// Device test app: drives the vehicle tool handlers against the simulated vehicle.
@main
struct NovaDriveApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                ContentView().tabItem { Label("车辆", systemImage: "car") }
                AudioSpikeView().tabItem { Label("音频测试", systemImage: "waveform") }
                RecorderView().tabItem { Label("录制", systemImage: "record.circle") }
                SettingsView().tabItem { Label("设置", systemImage: "key") }
            }
        }
    }
}

@MainActor
final class VehicleModel: ObservableObject {
    @Published var log: [String] = []
    private let vehicle = SimulatedVehicle()

    func run(_ tool: String, _ args: [String: JSONValue]) async {
        let outcome: VehicleToolOutcome
        switch tool {
        case "climate": outcome = await ClimateToolHandler(port: vehicle).handle(args)
        case "seat": outcome = await SeatToolHandler(port: vehicle).handle(args)
        default: outcome = await WindowToolHandler(port: vehicle).handle(args)
        }
        let line = outcome.chip ?? "✗ \(outcome.result.code?.rawValue ?? "failed")"
        log.insert(line, at: 0)
    }
}

struct ContentView: View {
    @StateObject private var model = VehicleModel()

    private let actions: [(String, String, [String: JSONValue])] = [
        ("空调开", "climate", ["action": .string("power_on")]),
        ("空调关", "climate", ["action": .string("power_off")]),
        ("温度 +1", "climate", ["action": .string("adjust_temperature"), "value": .int(1)]),
        ("温度 -1", "climate", ["action": .string("adjust_temperature"), "value": .int(-1)]),
        ("风量 +1", "climate", ["action": .string("adjust_fan"), "value": .int(1)]),
        ("风量 -1", "climate", ["action": .string("adjust_fan"), "value": .int(-1)]),
        ("开车窗", "window", ["action": .string("open")]),
        ("关车窗", "window", ["action": .string("close")]),
        ("座椅升高", "seat", ["action": .string("adjust_height"), "value": .int(1)]),
        ("座椅降低", "seat", ["action": .string("adjust_height"), "value": .int(-1)]),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section("模拟车辆") {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())]) {
                        ForEach(actions, id: \.0) { title, tool, args in
                            Button(title) { Task { await model.run(tool, args) } }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                Section("结果") {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { Text($0.element) }
                }
            }
            .navigationTitle("Nova Drive")
        }
    }
}
