import NovaAgent
import NovaKit
import NovaPorts
import NovaServices
import NovaTools
import SwiftUI

/// The app's tabs; `open_app` (F-25) switches between them.
enum AppTab: Hashable {
    case drive, vehicle, settings
}

/// Which tab is showing. Shared so a tool can switch it.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var tab: AppTab = .drive
}

/// `open_app` (F-25) on the tab bar: switches, then reports the tab that is showing.
struct TabSurfaces: AppSurfacePort {
    func show(_ surface: AppSurface) async -> AppSurface? {
        await MainActor.run {
            AppNavigation.shared.tab = surface == .maps ? .drive : .settings
            switch AppNavigation.shared.tab {
            case .drive: return .maps
            case .settings: return .settings
            case .vehicle: return nil
            }
        }
    }
}

@main
struct NovaDriveApp: App {
    @StateObject private var navigation = AppNavigation.shared

    init() {
        // F-04b §12 (T-013f): find the install-time speaker model pack (no load, no network of our own).
        SpeakerModelLocator.shared.refresh()
        // F-04b §16 item 6 (T-013j): the old calibration draft is deleted on first launch (no 校准 any more).
        SpeakerLockService.removeCalibrationDraft()
        // F-07 §15 item 2 (T-020b): once, no saved choice or 千问 moves to Gemini 原声.
        VoiceSourceMigration.run(DefaultsSettingsStore())
        // F-05a §14 item 1 (T-016l): with the switch on and the model missing, download on Wi-Fi; else load it.
        MultilingualModelStore.shared.start()
        _ = DriveSettings.musicCountry()  // F-13 §15 item 1 (T-032c): a saved 中国大陆 becomes 香港 at first launch
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $navigation.tab) {
                DriveView().tabItem { Label("驾驶", systemImage: "steeringwheel") }.tag(AppTab.drive)
                ContentView().tabItem { Label("车辆", systemImage: "car") }.tag(AppTab.vehicle)
                SettingsView().tabItem { Label("设置", systemImage: "key") }.tag(AppTab.settings)
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
