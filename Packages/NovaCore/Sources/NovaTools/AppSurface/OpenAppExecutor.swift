import NovaKit
import NovaPorts

/// A screen `open_app` may bring forward (F-25).
public enum AppSurface: String, Sendable, Hashable, CaseIterable {
    case maps, settings

    var label: String {
        switch self {
        case .maps: "地图"
        case .settings: "设置"
        }
    }
}

/// The app's screen switcher. `show` switches, then returns the surface that is visible afterwards.
public protocol AppSurfacePort: Sendable {
    func show(_ surface: AppSurface) async -> AppSurface?
}

/// `open_app` (F-25): maps → the 驾驶 map, settings → 设置. The reply comes from the read-back, so it
/// never claims a screen that is not showing (I-1).
public struct OpenAppExecutor: ToolExecutor {
    public static let tool = "open_app"

    private let surfaces: any AppSurfacePort

    public init(surfaces: any AppSurfacePort) { self.surfaces = surfaces }

    public func execute(_ call: ToolCall) async -> ToolResult {
        guard let raw = call.arguments["app"]?.stringValue, let surface = AppSurface(rawValue: raw) else {
            return ToolDispatcher.failure(.appNotAllowed)
        }
        guard await surfaces.show(surface) == surface else {
            // F-09b §13 item 4 (T-031m): not done; facts and rules, no sentence.
            return ToolReply.notDone(.appNotOpened, facts: ["page": .string(surface.label), "opened": false],
                                     may: [.tryLater]).result
        }
        // F-09b §13 item 5 (T-031n): what changed as facts.
        return .success(["app": .string(surface.rawValue)].merging(
            ToolReply.success(facts: ["opened": .string(surface.label)]).result.data) { $1 })
    }
}
