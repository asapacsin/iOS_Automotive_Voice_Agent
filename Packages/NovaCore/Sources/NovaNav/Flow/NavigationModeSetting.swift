import NovaPorts

/// F-15a §2.1: 设置 → 导航方式. Read when guidance starts; a voice command never changes it (OQ-NAVM-1).
public enum NavigationModeSetting: String, Sendable, Hashable, CaseIterable {
    /// 真实导航（默认）.
    case real
    /// 模拟导航（演示 / 录屏）.
    case simulated

    public static let `default` = NavigationModeSetting.real

    /// The trip's `NaviMode`. 演示起点 only makes sense with a fake car (REC-003), whatever the switch says.
    public static func mode(_ setting: NavigationModeSetting, source: LocationSource) -> NaviMode {
        if source == .demo { return .emulator }
        return setting == .real ? .gps : .emulator
    }

    /// The switch is locked to 模拟导航 with 演示起点 (「演示起点只能模拟导航」).
    public static func locked(source: LocationSource) -> Bool { source == .demo }
}
