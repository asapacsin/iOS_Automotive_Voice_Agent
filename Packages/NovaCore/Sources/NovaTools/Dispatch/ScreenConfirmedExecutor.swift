import NovaKit
import NovaPorts

/// F-09b §16 item 6 (T-031z): a tool that changes the screen answers from the screen state, not from its own intent.
/// After the inner tool says ok, it waits up to `ScreenTuning.screenConfirm` for the key it changes:
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

    private let inner: any ToolExecutor
    private let screen: ScreenStateStore
    private let clock: any NovaClock
    private let tuning: ScreenTuning

    public init(_ inner: any ToolExecutor, screen: ScreenStateStore, clock: any NovaClock,
                tuning: ScreenTuning = ScreenTuning()) {
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
        let result = await inner.execute(call)
        guard result.ok else { return result }
        if result.data["status"]?.stringValue == "no_navigation_active",
           let shown = ScreenPanel.navigationKeys.first(where: before.isOn) {
            // The flow has nothing open but the display still shows a navigation panel: not 「没有在导航」.
            return ToolReply.notDone(.stillOnScreen, facts: ["still_on": .string(shown.rawValue)],
                                     may: [.tryLater], mustNot: [.invent]).result
        }
        let closing = Self.closes(status: result.data["status"]?.stringValue).filter(before.isOn)
        guard !closing.isEmpty else { return result }
        let closed = await screen.wait(until: { s in closing.allSatisfy { !s.isOn($0) } },
                                       timeout: tuning.screenConfirm, clock: clock)
        if closed { return result }
        let still = await screen.current
        let key = closing.first(where: still.isOn) ?? closing[0]
        return ToolReply.notDone(.stillOnScreen, facts: ["still_on": .string(key.rawValue)],
                                 may: [.tryLater], mustNot: [.invent]).result
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
