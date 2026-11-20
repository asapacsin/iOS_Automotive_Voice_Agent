import NovaKit
import NovaPorts

/// F-09b §16 item 6 (T-031z): a tool that changes the screen answers from the screen state, not from its own intent.
/// After the inner tool says ok, it waits up to `ScreenTuning.screenConfirm` for the key it changes:
/// - `exit_navigation_mode` (§17 item 4, T-031zb): only the top panel closes; a sheet, the camera or the music card
///   through `close`, the navigation panels through the flow. The result carries `closed` and `top`.
/// - `exit_navigation_mode`: every panel it closes (on before the call) must be `off`; else `STILL_ON_SCREEN` with
///   `still_on=<key>`. 「没有在导航」 (`no_navigation_active`) only when every navigation key is `off`.
/// - `control_music play` / `play_music`: `musicVolume` 0 is not done before playing (`MEDIA_VOLUME_ZERO`); after
///   playing, done only when `music` is `on`; else `MUSIC_NOT_HEARD`.
public struct ScreenConfirmedExecutor: ToolExecutor {

    /// The panels a result of `exit_navigation_mode` closes (only those are waited for: a list closed over kept
    /// guidance leaves `navigation` on; stopping guidance leaves the trip cards).
    static func closes(status: String?) -> [ScreenPanel] {
        switch status {
        case "navigation_stopped": [.navigation, .routePicking]
        case "list_closed_guidance_kept": [.destinationList]
        case "navigation_selection_cancelled": [.destinationList, .routePicking, .routeCalculating, .tripScreen]
        case "trip_cards_hidden": [.tripScreen]
        default: []
        }
    }

    /// F-09b §17 item 4 (T-031zb): the panels `exit_navigation_mode` closes itself through `close` when one is the top
    /// (the navigation panels and `tripScreen` go through the navigation flow, as before), with the name her `next` uses.
    public static let ownClose: [ScreenPanel: String] = [
        .tripDetail: "地方卡片", .tripPlans: "我的行程", .camera: "摄像头画面", .musicCard: "音乐卡片",
    ]

    private let inner: any ToolExecutor
    private let screen: ScreenStateStore
    private let clock: any NovaClock
    private let tuning: ScreenTuning
    private let close: @Sendable (ScreenPanel) async -> Void

    /// `close`: the App dismisses that panel (the sheet, the camera, the preview and its card); done only when the
    /// panel's own report says off.
    public init(_ inner: any ToolExecutor, screen: ScreenStateStore, clock: any NovaClock,
                tuning: ScreenTuning = ScreenTuning(), close: @escaping @Sendable (ScreenPanel) async -> Void = { _ in }) {
        self.close = close
        self.inner = inner
        self.screen = screen
        self.clock = clock
        self.tuning = tuning
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "exit_navigation_mode": return await exit(call)
        case "play_music": return await play(call)
        case "control_music" where call.arguments["action"]?.stringValue == "play": return await play(call)
        default: return await inner.execute(call)
        }
    }

    private func exit(_ call: ToolCall) async -> ToolResult {
        let before = await screen.current
        // §17 item 4: a named panel closes that panel; 「收起来」 (no panel) closes the top one only.
        let named = call.arguments["panel"]?.stringValue.flatMap(ScreenPanel.init(rawValue:))
        let target = named ?? before.top
        if let top = target, let name = Self.ownClose[top], before.isOn(top) {
            await close(top)
            let off = await screen.wait(until: { !$0.isOn(top) }, timeout: tuning.screenConfirm, clock: clock)
            guard off else {
                return ToolReply.notDone(.stillOnScreen, facts: ["still_on": .string(top.rawValue)],
                                         may: [.tryLater], mustNot: [.invent]).result
            }
            let now = await screen.current.top
            return .success(["status": "panel_closed", "closed": .string(top.rawValue),
                             "top": .string(now?.rawValue ?? "none"), "next": .string("说一句：\(name)收起来了。")])
        }
        // The navigation flow takes no panel argument.
        let result = await inner.execute(ToolCall(id: call.id, name: call.name, arguments: [:]))
        guard result.ok else { return result }
        if result.data["status"]?.stringValue == "no_navigation_active",
           let shown = ScreenPanel.navigationKeys.first(where: before.isOn) {
            // The flow has nothing open but the display still shows a navigation panel: not 「没有在导航」.
            return ToolReply.notDone(.stillOnScreen, facts: ["still_on": .string(shown.rawValue)],
                                     may: [.tryLater], mustNot: [.invent]).result
        }
        let closing = Self.closes(status: result.data["status"]?.stringValue).filter(before.isOn)
        guard !closing.isEmpty else { return await withTop(result, before: before) }
        let closed = await screen.wait(until: { s in closing.allSatisfy { !s.isOn($0) } },
                                       timeout: tuning.screenConfirm, clock: clock)
        if closed { return await withTop(result, before: before) }
        let still = await screen.current
        let key = closing.first(where: still.isOn) ?? closing[0]
        return ToolReply.notDone(.stillOnScreen, facts: ["still_on": .string(key.rawValue)],
                                 may: [.tryLater], mustNot: [.invent]).result
    }

    /// §17 item 4: a navigation close says `closed` (a layered panel that was on and is off now: the old top when it
    /// went, else the highest of them; none when nothing went off) and `top=<the top now>`.
    private func withTop(_ result: ToolResult, before: ScreenState) async -> ToolResult {
        guard result.ok else { return result }
        let now = await screen.current
        let gone = before.order.filter { $0.layer != nil && !now.isOn($0) }
        var data = result.data
        if let top = before.top, gone.contains(top) {
            data["closed"] = .string(top.rawValue)
        } else if let highest = gone.max(by: { ($0.layer ?? 0) < ($1.layer ?? 0) }) {
            data["closed"] = .string(highest.rawValue)
        }
        data["top"] = .string(now.top?.rawValue ?? "none")
        return ToolResult(ok: result.ok, code: result.code, data: data, advice: result.advice)
    }

    private func play(_ call: ToolCall) async -> ToolResult {
        guard await screen.current.musicVolume > 0 else {
            return ToolReply.notDone(.mediaVolumeZero, facts: ["musicVolume": 0], may: [.nameSetting],
                                     mustNot: [.invent]).result
        }
        let result = await inner.execute(call)
        guard result.ok else { return result }
        let heard = await screen.wait(until: { $0.music }, timeout: tuning.screenConfirm, clock: clock)
        if heard { return result }
        let volume = await screen.current.musicVolume
        return ToolReply.notDone(.musicNotHeard, facts: ["music": "off", "musicVolume": .int(Int64(volume))],
                                 may: [.tryLater], mustNot: [.invent]).result
    }
}
