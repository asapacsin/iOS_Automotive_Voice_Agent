import NovaPorts

/// One Amap manoeuvre icon (F-17, contracts/navigation.md HUD fields: icon type 2–16).
public struct TurnIndicator: Sendable, Hashable {
    public let word: String
    public let arrow: String

    public init(word: String, arrow: String) {
        self.word = word
        self.arrow = arrow
    }

    /// PROPOSED table from the public `AMapNaviIconType` enum; pending the Android
    /// `TextNavigationPanelModel.kt:56-87` table via EVIDENCE_REQUEST. Unknown types fall back to 直行.
    public static func forIconType(_ iconType: Int) -> TurnIndicator {
        switch iconType {
        case 2: TurnIndicator(word: "左转", arrow: "←")
        case 3: TurnIndicator(word: "右转", arrow: "→")
        case 4: TurnIndicator(word: "靠左", arrow: "↖")
        case 5: TurnIndicator(word: "靠右", arrow: "↗")
        case 6: TurnIndicator(word: "左后转", arrow: "↙")
        case 7: TurnIndicator(word: "右后转", arrow: "↘")
        case 8: TurnIndicator(word: "掉头", arrow: "↶")
        case 9: TurnIndicator(word: "直行", arrow: "↑")
        case 10: TurnIndicator(word: "到达途经点", arrow: "●")
        case 11: TurnIndicator(word: "进入环岛", arrow: "↻")
        case 12: TurnIndicator(word: "驶出环岛", arrow: "↗")
        case 13: TurnIndicator(word: "到达服务区", arrow: "●")
        case 14: TurnIndicator(word: "到达收费站", arrow: "●")
        case 15: TurnIndicator(word: "到达目的地", arrow: "●")
        case 16: TurnIndicator(word: "进入隧道", arrow: "↑")
        default: TurnIndicator(word: "直行", arrow: "↑")
        }
    }
}

/// F-17 text navigation panel. Pure value built from the latest navi data.
public struct HUDPanelModel: Sendable, Hashable {
    public static let waitingText = "等待导航数据…"

    public let title: String
    /// nil until the first `naviInfo` arrives; the view then shows `waitingText`.
    public let turn: TurnIndicator?
    public let stepDistanceText: String?
    /// 「进入 {road}」; omitted when the road name is missing or blank (§8).
    public let nextRoadText: String?
    public let remainingText: String?
    /// 「限速 N km/h」 only when limit > 0 (limit 0 = no data).
    public let speedLimitText: String?
    public let lastGuidance: String?
    public let statusText: String?

    public init(destinationName: String, naviInfo: NaviInfo?, lastGuidance: String? = nil, speedLimitKmh: Int = 0) {
        title = "导航中 → \(destinationName)"
        self.lastGuidance = lastGuidance
        speedLimitText = speedLimitKmh > 0 ? "限速 \(speedLimitKmh) km/h" : nil
        guard let info = naviInfo else {
            turn = nil
            stepDistanceText = nil
            nextRoadText = nil
            remainingText = nil
            statusText = Self.waitingText
            return
        }
        statusText = nil
        turn = TurnIndicator.forIconType(info.iconType)
        stepDistanceText = Self.stepDistance(info.stepDistanceMeters)
        if let road = info.nextRoadName?.trimmingSpaces, !road.isEmpty {
            nextRoadText = "进入 \(road)"
        } else {
            nextRoadText = nil
        }
        remainingText = "剩余 \(Self.kilometres(info.remainingMeters)) km · \(Self.minutes(info.remainingSeconds)) 分钟"
    }

    /// ≥ 1 000 m → 「x.x 公里」, else 「N 米」.
    static func stepDistance(_ meters: Int) -> String {
        meters >= 1_000 ? "\(kilometres(meters)) 公里" : "\(max(meters, 0)) 米"
    }

    /// One decimal, rounded half up, locale-free.
    static func kilometres(_ meters: Int) -> String {
        let tenths = (max(meters, 0) + 50) / 100
        return "\(tenths / 10).\(tenths % 10)"
    }

    /// Whole minutes, rounded up so a non-zero remainder never reads as 0 (PROPOSED rounding).
    static func minutes(_ seconds: Int) -> Int {
        (max(seconds, 0) + 59) / 60
    }
}

private extension String {
    var trimmingSpaces: String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
