import NovaKit

/// F-23 / ios-architecture §11.2 (T-063): each permission is asked on its first need, never up front,
/// and a denial is explained with the way to allow it. Pure; the App asks the system.
public enum AppPermission: String, Sendable, Hashable, CaseIterable {
    case microphone, location, contacts, camera
}

public enum PermissionStatus: Sendable, Hashable { case notDetermined, granted, denied }

/// The moment a feature first needs something.
public enum PermissionNeed: Sendable, Hashable {
    case firstTalk, navigationOrWeatherHere, firstCall, firstCameraQuestion

    public var permission: AppPermission {
        switch self {
        case .firstTalk: .microphone
        case .navigationOrWeatherHere: .location
        case .firstCall: .contacts
        case .firstCameraQuestion: .camera
        }
    }
}

public enum PermissionAction: Sendable, Hashable {
    /// Ask the system now (first need, not decided yet).
    case request(AppPermission)
    case proceed
    /// Denied: show this explanation; the rest of the app keeps working.
    case explain(AppPermission, message: String)
}

public enum PermissionCoordinator {
    public static func action(for need: PermissionNeed, status: PermissionStatus) -> PermissionAction {
        let permission = need.permission
        switch status {
        case .granted: return .proceed
        case .notDetermined: return .request(permission)
        case .denied: return .explain(permission, message: explanation(permission))
        }
    }

    public static func explanation(_ permission: AppPermission) -> String {
        switch permission {
        case .microphone: "没有麦克风权限，小诺听不到你。请到「设置 > Nova Drive」打开麦克风。"
        case .location: "没有定位权限，只能按名称搜索，不能找附近。请到「设置 > Nova Drive > 位置」允许使用期间访问。"
        case .contacts: "没有通讯录权限，不能按名字打电话。请到「设置 > Nova Drive」打开通讯录。"
        case .camera: "没有相机权限，看不到画面。请到「设置 > Nova Drive」打开相机。"
        }
    }
}
