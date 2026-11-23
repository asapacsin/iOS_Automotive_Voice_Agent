/// F-09b §16 items 1–2 (T-031z): one key per panel `DriveView` shows, in the fixed order of the `屏幕` line.
public enum ScreenPanel: String, Sendable, Hashable, CaseIterable {
    case destinationList, routePicking, routeCalculating, navigation
    /// F-15b §57 item 4 (T-040zj, amends §16 item 1): the 「去下一站：<名字>」 and 「结束导航」 buttons, after `navigation`.
    case tripNextButton, stopNavigationButton
    case tripScreen, tripDetail, tripPlans, musicCard
    /// F-09b §19 item 5 (T-031zd): the pin `show_on_map` drew and its small card, after `musicCard`'s music fields.
    case mapPin
    case camera, working
    /// F-04 §15 item 4 (T-004k): the background-work caption (a tool call running), after `working`.
    case backgroundWork
    case settings

    /// §16 item 6: the keys that together mean 「在导航」 (all off: 「没有在导航」).
    public static let navigationKeys: [ScreenPanel] = [.destinationList, .routePicking, .routeCalculating, .navigation]

    /// F-09b §17 item 1 (T-031zb): 3 sheet over everything, 2 full panel, 1 small floating card, 0 base; nil for
    /// `working` and `settings`, which she never closes.
    public var layer: Int? { PanelRegistry.entry(self).layer }
}

/// F-09b §16 (T-031z): what the display really shows, made only from the views' own on/off reports (item 2), plus
/// `music` (sound really heard, item 3) and `musicVolume` (0–10). Nothing else: no names, counts or minutes.
public struct ScreenState: Sendable, Hashable {
    public private(set) var on: Set<ScreenPanel> = []
    public private(set) var music = false
    public private(set) var musicVolume = 0
    /// F-09b §17 item 2 (T-031zb): the panels that are on, oldest first (the order their reports turned them on).
    public private(set) var order: [ScreenPanel] = []

    public init(on: Set<ScreenPanel> = [], music: Bool = false, musicVolume: Int = 0) {
        self.on = on
        self.order = ScreenPanel.allCases.filter(on.contains)
        self.music = music
        self.musicVolume = Self.clampVolume(musicVolume)
    }

    public func isOn(_ panel: ScreenPanel) -> Bool { on.contains(panel) }

    /// Item 2: a view's `onAppear` (true) or `onDisappear` (false). The only way a panel key changes.
    @discardableResult
    public mutating func report(_ panel: ScreenPanel, on shown: Bool) -> Bool {
        if shown {
            guard on.insert(panel).inserted else { return false }
            order.append(panel)
            return true
        }
        guard on.remove(panel) != nil else { return false }
        order.removeAll { $0 == panel }
        return true
    }

    /// §17 item 2: the panel on the highest layer; on the same layer, the newest. nil when no layered panel is on.
    public var top: ScreenPanel? {
        var best: (panel: ScreenPanel, layer: Int)?
        for panel in order {
            guard let layer = panel.layer else { continue }
            if best == nil || layer >= best!.layer { best = (panel, layer) }
        }
        return best?.panel
    }

    /// §17 item 7: the record line of one view report, `panel <key> <on|off> top=<panel|none>` (codes only, I-8).
    public func panelLine(_ panel: ScreenPanel, on shown: Bool) -> String {
        "panel \(panel.rawValue) \(word(shown)) top=\(top?.rawValue ?? "none")"
    }

    /// Item 3: the measured verdict of the media lane (true only when sound was heard).
    @discardableResult
    public mutating func reportMusic(heard: Bool) -> Bool {
        defer { music = heard }
        return music != heard
    }

    /// Item 1: the saved media volume, 0–10.
    @discardableResult
    public mutating func reportVolume(_ volume: Int) -> Bool {
        let v = Self.clampVolume(volume)
        defer { musicVolume = v }
        return musicVolume != v
    }

    /// Item 6: 「没有在导航」 only when every navigation key is off.
    public var navigationOff: Bool { ScreenPanel.navigationKeys.allSatisfy { !on.contains($0) } }

    static func clampVolume(_ v: Int) -> Int { min(10, max(0, v)) }

    private func word(_ b: Bool) -> String { b ? "on" : "off" }

    /// Item 4, exact form: every key in the fixed order, `music` and `musicVolume` after `musicCard`.
    public var line: String {
        var parts: [String] = []
        for panel in ScreenPanel.allCases {
            parts.append("\(panel.rawValue) \(word(on.contains(panel)))")
            if panel == .musicCard {
                parts.append("music \(word(music))")
                parts.append("musicVolume \(musicVolume)")
            }
        }
        // §17 item 5: one field at the end, the top panel.
        parts.append("top \(top?.rawValue ?? "none")")
        return "[系统] 屏幕：" + parts.joined(separator: "；") + "。这句不用回答。"
    }

    /// Item 9: the record form, `screen <key>=<on|off> … musicVolume=<n>` (codes only, I-8).
    public var recordLine: String {
        var parts: [String] = []
        for panel in ScreenPanel.allCases {
            parts.append("\(panel.rawValue)=\(word(on.contains(panel)))")
            if panel == .musicCard {
                parts.append("music=\(word(music))")
                parts.append("musicVolume=\(musicVolume)")
            }
        }
        return "screen " + parts.joined(separator: " ")
    }
}

/// F-09b §17 item 3 (T-031zb): every panel with its layer and its tools: the tools that open it, the one that closes it,
/// the ones that act on it. `scripts/gates/check_panel_tools.py` reads this table: every `.screenPanel(...)` in
/// `App/NovaDrive` needs an entry, and every entry with a layer a close tool. Keep one entry per line.
public struct PanelEntry: Sendable, Hashable {
    public let layer: Int?
    public let opens: [String]
    public let close: String?
    public let acts: [String]
}

public enum PanelRegistry {
    public static let table: [ScreenPanel: PanelEntry] = [
        .tripDetail: PanelEntry(layer: 3, opens: ["show_place"], close: "exit_navigation_mode", acts: ["navigate_to"]),
        .tripPlans: PanelEntry(layer: 3, opens: [], close: "exit_navigation_mode", acts: ["trip_plans"]),
        .destinationList: PanelEntry(layer: 2, opens: ["navigate_to", "show_places", "trip_next"], close: "exit_navigation_mode", acts: ["choose_navigation_option", "show_place"]),
        .routePicking: PanelEntry(layer: 2, opens: ["navigate_to", "choose_navigation_option"], close: "exit_navigation_mode", acts: ["choose_navigation_option"]),
        .routeCalculating: PanelEntry(layer: 2, opens: ["navigate_to", "choose_navigation_option", "trip_next"], close: "exit_navigation_mode", acts: []),
        .tripScreen: PanelEntry(layer: 2, opens: ["set_trip_plan", "trip_plans"], close: "exit_navigation_mode", acts: ["set_trip_plan", "trip_next", "show_place"]),
        .camera: PanelEntry(layer: 2, opens: [], close: "exit_navigation_mode", acts: ["describe_camera_view"]),
        .mapPin: PanelEntry(layer: 1, opens: ["show_on_map"], close: "exit_navigation_mode", acts: ["navigate_to"]),
        .musicCard: PanelEntry(layer: 1, opens: ["play_music"], close: "exit_navigation_mode", acts: ["control_music"]),
        .navigation: PanelEntry(layer: 0, opens: ["choose_navigation_option", "trip_next"], close: "exit_navigation_mode", acts: ["choose_navigation_option", "navigate_to"]),
        .working: PanelEntry(layer: nil, opens: [], close: nil, acts: []),
        .backgroundWork: PanelEntry(layer: nil, opens: [], close: nil, acts: []),
        // F-15b §57 item 4 (T-040zj): buttons, not panels: no layer, never closed by her.
        .tripNextButton: PanelEntry(layer: nil, opens: [], close: nil, acts: ["trip_next"]),
        .stopNavigationButton: PanelEntry(layer: nil, opens: [], close: nil, acts: ["exit_navigation_mode"]),
        .settings: PanelEntry(layer: nil, opens: ["open_app"], close: nil, acts: []),
    ]

    public static func entry(_ panel: ScreenPanel) -> PanelEntry { table[panel]! }
}
