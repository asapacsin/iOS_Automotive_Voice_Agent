import Foundation
import NovaKit
import NovaPorts

/// F-09a (T-017a, 落域): the area of a closed driver utterance, from the phone recognizer's final text only
/// (`DriverWords.final`); Gemini's transcript is never read here. The lists are §2's, word for word. The comfort tools
/// run only in the car areas or when the area is unknown (§3).
public enum CarRequestRouter {
    /// §3 item 1: the tools this router gates. Every other tool keeps today's behaviour (§3 item 2).
    public static let comfortTools: Set<String> = ["control_climate", "control_window", "control_seat", "run_scenario"]

    /// §2 rule 2.
    static let carWords = [
        "空调", "温度", "风", "暖",
        "窗", "座椅", "座位", "椅子",
        "热", "晒", "汗", "闷", "憋", "透不过气", "喘不过气", "蒸笼", "桑拿", "黏",
        "冷", "冻", "凉", "抖", "鸡皮疙瘩", "飕",
        "味", "臭", "烟", "空气", "潮", "霉", "焦",
        "蚊", "虫", "苍蝇", "蛾",
    ]
    /// §2 rule 2: a number followed by 度 (digits, full-width digits or Chinese numerals).
    static let degrees = ICURegex("[0-9０-９零一二三四五六七八九十两百]+度")
    /// §2 rule 3.
    static let tiredWords = ["困", "累", "睡着", "想睡", "睡觉", "瞌睡", "哈欠", "眼皮", "睁不开", "点头", "昏昏", "浆糊",
                             "疲", "乏", "撑不住"]
    static let questionWords = ["为什么", "怎么", "什么", "吗", "呢", "如何", "是不是", "？", "?"]
    static let otherRequestWords = ["歌", "音乐", "播放", "导航", "去", "回家", "服务区", "打电话", "打给", "帮我", "给我", "请"]
    static let notTired = ["困难", "困扰"]
    /// §2 rule 4.
    static let followUpWords = ["再", "还", "关", "开", "调", "一点", "掉", "上", "下", "大", "小", "高", "低", "停", "别",
                                "算了", "回去", "恢复"]

    /// The previous closed utterance, for §2 rule 4.
    public struct Previous: Sendable, Hashable {
        public var area: CarRequestArea
        /// A comfort tool returned ok for it.
        public var comfortOk: Bool
        public init(area: CarRequestArea, comfortOk: Bool) {
            self.area = area
            self.comfortOk = comfortOk
        }
    }

    /// §2: `final` is the recognizer's final text, nil when there is none (`.unclear`, or none within the wait).
    public static func area(final: String?, previous: Previous?) -> CarRequestArea {
        guard let final else { return .unknown }
        let text = TranscriptText.normalize(final)
        if carWords.contains(where: text.contains) || degrees.matches(text) { return .car }
        if isTired(text) { return .tired }
        if let previous, previous.comfortOk, previous.area == .car || previous.area == .followUp,
           followUpWords.contains(where: text.contains) {
            return .followUp
        }
        return .chat
    }

    static func isTired(_ text: String) -> Bool {
        guard tiredWords.contains(where: text.contains) else { return false }
        if questionWords.contains(where: text.contains) { return false }
        if otherRequestWords.contains(where: text.contains) { return false }
        return !notTired.contains(where: text.contains)
    }

    /// §3 item 1: whether a comfort tool may run for an utterance of `area`. A tap is never refused.
    public static func allows(_ area: CarRequestArea, fromTap: Bool = false) -> Bool {
        if fromTap { return true }
        switch area {
        case .car, .followUp, .unknown: return true
        case .tired, .chat: return false
        }
    }
}
