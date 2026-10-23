/// What a reply claims to have done (`A/voice/ActionClaimGuard.kt`).
public enum ClaimKind: String, Sendable, Hashable {
    /// A vehicle, phone or other action reported as done (「空调已打开」).
    case action
    /// 「导航已开始」: needs the navigation phase NAVIGATING as evidence.
    case navigationStarted
    /// 「正在播放」: needs verified playback.
    case musicPlaying
}

/// Phrase tables for claims and driver requests. PROPOSED: the spec gives examples only; the Android
/// tables (`ActionClaimGuard.kt:447,671`) are an open EVIDENCE_REQUEST (STATUS.md, T-019).
public enum ClaimLexicon {
    static let navigation = ["导航已开始", "已开始导航", "已经开始导航", "开始导航了", "正在为您导航", "正在为你导航",
                             "导航已经开始"]
    static let music = ["正在播放", "已播放", "已经播放", "开始播放", "为您播放", "为你播放", "放起来了"]
    static let action = ["已打开", "已开启", "已关闭", "已关上", "已调", "已设置", "已为您", "已为你", "已帮您", "已帮你",
                         "已经打开", "已经开启", "已经关闭", "已经关上", "已经调", "已经设置", "已经帮", "已拨打", "正在拨打",
                         "打开了", "开好了", "关上了", "关好了", "关闭了", "调到了", "调高了", "调低了", "调好了", "设置好了",
                         "升高了", "降低了", "放下了", "搞定了"]
    /// A driver utterance asking for an action, so a tool call should follow.
    static let request = ["打开", "关闭", "关上", "关掉", "开一下", "开个", "调高", "调低", "调到", "调成", "设置", "升高",
                          "降低", "放首", "放一首", "播放", "放歌", "导航", "打电话", "打给", "拨打", "开窗", "关窗", "凉一点",
                          "暖一点", "热一点", "冷一点", "高一点", "低一点", "大一点", "小一点"]
    /// Negations that turn a phrase into the opposite (「没能打开」, 「无法播放」).
    static let negations = ["没有", "没能", "未能", "无法", "不能", "失败", "没法", "暂时不", "还没"]

    /// The strongest claim in `text`, or nil. Negated sentences claim nothing.
    public static func claim(in text: String) -> ClaimKind? {
        let sentences = text.split(whereSeparator: { "。！？!?；;\n".contains($0) })
        var found: ClaimKind?
        for sentence in sentences.map(String.init) where !negations.contains(where: sentence.contains) {
            if navigation.contains(where: sentence.contains) { return .navigationStarted }
            if music.contains(where: sentence.contains) { found = .musicPlaying }
            else if found == nil, action.contains(where: sentence.contains) { found = .action }
        }
        return found
    }

    public static func asksForAction(_ utterance: String) -> Bool {
        request.contains(where: utterance.contains)
    }
}
