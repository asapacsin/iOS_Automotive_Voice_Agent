import NovaKit
/// What a reply claims to have done (`A/voice/ActionClaimGuard.kt`).
public enum ClaimKind: String, Sendable, Hashable {
    /// A vehicle, phone or other action reported as done (「空调已打开」).
    case action
    /// 「导航已开始」: needs the navigation phase NAVIGATING as evidence.
    case navigationStarted
    /// 「正在播放」: needs verified playback.
    case musicPlaying
}

extension ClaimKind {
    /// Navigation and music need stronger evidence than a plain action, so they win.
    static func strongest(_ a: ClaimKind?, _ b: ClaimKind?) -> ClaimKind? {
        let rank: (ClaimKind?) -> Int = { k in
            switch k { case .navigationStarted: 3; case .musicPlaying: 2; case .action: 1; case nil: 0 }
        }
        return rank(a) >= rank(b) ? a : b
    }
}

/// Phrase tables for claims and driver requests. PROPOSED: the spec gives examples only; the Android
/// tables (`ActionClaimGuard.kt:447,671`) are an open EVIDENCE_REQUEST (STATUS.md, T-019).
public enum ClaimLexicon {
    static let navigation = ["导航已开始", "已开始导航", "已经开始导航", "开始导航了", "正在为您导航", "正在为你导航",
                             "导航已经开始",
                             // F-15a §2.5 (PROPOSED): a route claimed as chosen is a start claim too.
                             "已选好路线", "已经选好路线", "已选择路线", "已经为你选", "已经为您选", "已为你选", "已为您选"]
    static let music = ["正在播放", "已播放", "已经播放", "开始播放", "为您播放", "为你播放", "放起来了"]
    static let action = ["已打开", "已开启", "已关闭", "已关上", "已调", "已设置", "已为您", "已为你", "已帮您", "已帮你",
                         "已经打开", "已经开启", "已经关闭", "已经关上", "已经调", "已经设置", "已经帮", "已拨打", "正在拨打",
                         "打开了", "开好了", "关上了", "关好了", "关闭了", "调到了", "调高了", "调低了", "调好了", "设置好了",
                         "升高了", "降低了", "放下了", "搞定了"]
    /// A driver utterance asking for an action, so a tool call should follow.
    static let request = ["打开", "关闭", "关上", "关掉", "开一下", "开个", "调高", "调低", "调到", "调成", "设置", "升高",
                          "降低", "放首", "放一首", "播放", "放歌", "导航", "打电话", "打给", "拨打", "开窗", "关窗", "凉一点",
                          "暖一点", "热一点", "冷一点", "高一点", "低一点", "大一点", "小一点",
                          // Feelings are requests (SPEC-006 C2, Android `DriverTurn.kt:930`): 「我有点热」.
                          "热", "冷", "闷", "困", "晒", "蚊子", "关一下", "开一下", "调一下", "放一下"]
    /// Negations that turn a phrase into the opposite (「没能打开」, 「无法播放」).
    static let negations = ["没有", "没能", "未能", "无法", "不能", "失败", "没法", "暂时不", "还没"]

    /// Every kind of claim in `text`, judged per clause. Negated clauses claim nothing.
    public static func claims(in text: String) -> Set<ClaimKind> {
        // Negation is judged per clause: 「已为您打开空调，如果还没凉下来请告诉我」 still claims.
        let clauses = text.split(whereSeparator: { "。！？!?；;\n，,、：:".contains($0) })
        var found: Set<ClaimKind> = []
        for clause in clauses.map(String.init) where !negations.contains(where: clause.contains) {
            if navigation.contains(where: clause.contains) { found.insert(.navigationStarted) }
            else if music.contains(where: clause.contains) { found.insert(.musicPlaying) }
            else if action.contains(where: clause.contains) { found.insert(.action) }
        }
        return found
    }

    /// The strongest claim in `text`, or nil.
    public static func claim(in text: String) -> ClaimKind? {
        claims(in: text).reduce(nil) { ClaimKind.strongest($0, $1) }
    }

    // MARK: Claims per tool (F-12 §14 item 12, T-031b)

    /// What an action claim names. Each needs an ok result of the tool that controls it.
    public enum Topic: String, Sendable, Hashable, CaseIterable {
        case windows, climate, fan, music
    }

    /// PROPOSED word lists; words from comfort-eval failures are added here.
    static let topicWords: [Topic: [String]] = [
        .windows: ["车窗", "窗户", "窗"],
        .climate: ["空调", "温度", "冷气", "制冷", "暖气", "度"],
        .fan: ["风量", "风速", "吹风", "风"],
        .music: ["音乐", "歌", "曲子"],
    ]

    static func topics(of clause: String) -> Set<Topic> {
        Set(Topic.allCases.filter { topic in topicWords[topic]!.contains(where: clause.contains) })
    }

    /// The topics named by the claiming clauses of `text` (negated clauses claim nothing).
    public static func claimedTopics(in text: String) -> Set<Topic> {
        let clauses = text.split(whereSeparator: { "。！？!?；;\n，,、：:".contains($0) })
        var found: Set<Topic> = []
        for clause in clauses.map(String.init) where !negations.contains(where: clause.contains) {
            if music.contains(where: clause.contains) || action.contains(where: clause.contains) {
                found.formUnion(topics(of: clause))
            }
        }
        return found
    }

    /// Whether an ok result of tool `name` (with its `data`) proves a claim about `topic`.
    public static func proves(_ name: String, _ data: [String: JSONValue], _ topic: Topic) -> Bool {
        switch name {
        case "control_window": return topic == .windows
        case "control_climate": return topic == .climate || topic == .fan
        case "control_music", "play_music": return topic == .music
        case "run_scenario":
            // The table proves what its finished steps name (`done` labels: 打开空调, 车窗开到50%, …).
            guard case .array(let done)? = data["done"] else { return false }
            return done.contains { $0.stringValue.map { topics(of: $0).contains(topic) } ?? false }
        default: return false
        }
    }

    /// Topics claimed in `text` that no ok result in `proofs` backs (empty: every named claim is backed).
    public static func unbackedTopics(in text: String, proofs: [(name: String, data: [String: JSONValue])]) -> Set<Topic> {
        claimedTopics(in: text).filter { topic in !proofs.contains { proves($0.name, $0.data, topic) } }
    }

    public static func asksForAction(_ utterance: String) -> Bool {
        request.contains(where: utterance.contains)
    }
}
