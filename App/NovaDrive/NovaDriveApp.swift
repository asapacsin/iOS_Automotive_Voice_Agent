import NovaKit
import NovaPorts
import NovaTools
import SwiftUI

/// The app's tabs; `open_app` (F-25) switches between them.
enum AppTab: Hashable {
    case drive, vehicle, audio, recorder, settings
}

/// Which tab is showing. Shared so a tool can switch it.
@MainActor
final class AppNavigation: ObservableObject {
    static let shared = AppNavigation()
    @Published var tab: AppTab = .drive
}

/// `open_app` (F-25): maps → the 驾驶 map, settings → 设置. Reports only the switch it made.
struct OpenAppExecutor: ToolExecutor {
    func execute(_ call: ToolCall) async -> ToolResult {
        let app = call.arguments["app"]?.stringValue ?? ""
        let target: (AppTab, String)? = switch app {
        case "maps": (.drive, "地图")
        case "settings": (.settings, "设置")
        default: nil
        }
        guard let (tab, label) = target else { return ToolDispatcher.failure(.appNotAllowed) }
        await MainActor.run { AppNavigation.shared.tab = tab }
        return .success(["app": .string(app), "next": .string("已经打开\(label)页面，用一句话告诉用户。")])
    }
}

@main
struct NovaDriveApp: App {
    @StateObject private var navigation = AppNavigation.shared

    var body: some Scene {
        WindowGroup {
            TabView(selection: $navigation.tab) {
                DriveView().tabItem { Label("驾驶", systemImage: "steeringwheel") }.tag(AppTab.drive)
                ContentView().tabItem { Label("车辆", systemImage: "car") }.tag(AppTab.vehicle)
                AudioSpikeView().tabItem { Label("音频测试", systemImage: "waveform") }.tag(AppTab.audio)
                RecorderView().tabItem { Label("录制", systemImage: "record.circle") }.tag(AppTab.recorder)
                SettingsView().tabItem { Label("设置", systemImage: "key") }.tag(AppTab.settings)
            }
        }
    }
}
