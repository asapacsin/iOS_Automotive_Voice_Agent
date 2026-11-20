/// F-09b §16 items 1–2 (T-031z): one key per panel `DriveView` shows, in the fixed order of the `屏幕` line.
public enum ScreenPanel: String, Sendable, Hashable, CaseIterable {
    case destinationList, routePicking, routeCalculating, navigation, tripScreen, tripDetail, tripPlans, musicCard
    case camera, working, settings

    /// §16 item 6: the keys that together mean 「在导航」 (all off: 「没有在导航」).
    public static let navigationKeys: [ScreenPanel] = [.destinationList, .routePicking, .routeCalculating, .navigation]
}

/// F-09b §16 (T-031z): what the display really shows, made only from the views' own on/off reports (item 2), plus
/// `music` (sound really heard, item 3) and `musicVolume` (0–10). Nothing else: no names, counts or minutes.
public struct ScreenState: Sendable, Hashable {
    public private(set) var on: Set<ScreenPanel> = []
    public private(set) var music = false
    public private(set) var musicVolume = 0

    public init(on: Set<ScreenPanel> = [], music: Bool = false, musicVolume: Int = 0) {
        self.on = on
        self.music = music
        self.musicVolume = Self.clampVolume(musicVolume)
    }

    public func isOn(_ panel: ScreenPanel) -> Bool { on.contains(panel) }

    /// Item 2: a view's `onAppear` (true) or `onDisappear` (false). The only way a panel key changes.
    @discardableResult
    public mutating func report(_ panel: ScreenPanel, on shown: Bool) -> Bool {
        shown ? on.insert(panel).inserted : on.remove(panel) != nil
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
