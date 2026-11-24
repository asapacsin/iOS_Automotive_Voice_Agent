import NovaKit
import NovaPorts

/// F-09b §22 (T-031zg): a panel's 「×」. A tap closes the panel at once through the one close path her
/// `exit_navigation_mode` uses (§17 item 4: `ScreenConfirmedExecutor` with `panel=<key>`; for `destinationList` /
/// `routePicking` / `tripScreen` that is the navigation flow, the same path as 「不去了」, I-6). No model call and no
/// spoken line: the result is not sent to her; her next 屏幕 line no longer has the panel.
public enum PanelCloseTap {
    /// §22 item 1: the panels that get a 「×」 here (`camera` and `mapPin` keep theirs; they close the same way).
    public static let panels: [ScreenPanel] = [.destinationList, .routePicking, .tripScreen, .tripDetail, .tripPlans,
                                               .musicCard]

    /// §22 item 3: the accessibility label 「关掉<panel name>」.
    public static func label(_ panel: ScreenPanel) -> String {
        let names: [ScreenPanel: String] = [
            .destinationList: "地点列表", .routePicking: "路线选择", .tripScreen: "行程", .tripDetail: "地方卡片",
            .tripPlans: "我的行程", .musicCard: "音乐卡片", .camera: "摄像头画面", .mapPin: "地图标记",
        ]
        return "关掉" + (names[panel] ?? panel.rawValue)
    }

    /// §22 item 3: the accessibility identifier `<panel>-close`.
    public static func identifier(_ panel: ScreenPanel) -> String { "\(panel.rawValue)-close" }

    /// §22 items 2, 5: `record` gets the tap (`panel close tap <key>`) first; then `exit` (the session's
    /// `exit_navigation_mode` executor) closes the panel. The result is returned for tests and dropped by the App.
    @discardableResult
    public static func tap(_ panel: ScreenPanel, exit: any ToolExecutor,
                           record: @Sendable (ScreenPanel) -> Void = { _ in }) async -> ToolResult {
        record(panel)
        let id = CallID("tap-close-\(panel.rawValue)")!
        return await exit.execute(ToolCall(id: id, name: "exit_navigation_mode", arguments: ["panel": .string(panel.rawValue)]))
    }
}
