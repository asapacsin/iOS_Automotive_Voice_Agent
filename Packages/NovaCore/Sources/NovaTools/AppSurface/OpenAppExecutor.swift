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
            return .failure(.actionNotAllowed, advice: "页面没有切换过去。请如实说没有打开\(surface.label)页面。")
        }
        return .success(["app": .string(surface.rawValue),
                         "next": .string("已经打开\(surface.label)页面，用一句话告诉用户。")])
    }
}
