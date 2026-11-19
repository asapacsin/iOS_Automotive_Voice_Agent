/// F-09b §13 item 1 (T-031l): a move she may make on her own after a tool result. A closed enum: the model reads
/// the raw value in `may` and the gloss in `next`; logs carry only the raw value (I-8, item 11).
/// Later stages (T-031m..T-031o) add cases here; a gloss never quotes a sentence for her to say.
public enum ReplyMay: String, Sendable, Hashable, CaseIterable {
    case searchWider = "search_wider"
    case similarPlace = "similar_place"
    case offerNearest = "offer_nearest"
    case askPick = "ask_pick"
    /// The driver may say it again later (a lookup that failed, not one that found nothing).
    case tryLater = "try_later"
    /// She may ask which city or place the driver means.
    case askPlace = "ask_place"
    /// She may say the setting that would fix it (a permission or a missing key).
    case nameSetting = "name_setting"

    public var gloss: String {
        switch self {
        case .searchWider: "可以自己再搜远一点"
        case .similarPlace: "可以搜相近的地方（比如服务区、休息区）"
        case .offerNearest: "可以提议去 facts 里最近的那个"
        case .askPick: "可以问司机选哪个"
        case .tryLater: "可以说稍后再试"
        case .askPlace: "可以问司机是哪个城市或地方"
        case .nameSetting: "可以说要在设置里打开或配置什么"
        }
    }
}

/// F-09b §13 item 1: a hard rule for her reply. Code-enforced checks (F-06, `VehicleActionPolicy`) stay where they
/// are; this tells her what the result does not allow.
public enum ReplyMustNot: String, Sendable, Hashable, CaseIterable {
    case claimStarted = "claim_started"
    case claimDone = "claim_done"
    case invent = "invent"
    case askRephrase = "ask_rephrase"
    case readList = "read_list"
    /// She must not guess where the car is.
    case guessLocation = "guess_location"

    public var gloss: String {
        switch self {
        case .claimStarted: "不要说已经开始"
        case .claimDone: "不要说已经做好"
        case .invent: "不要说 facts 里没有的地点、数字或时间"
        // Item 8's phrase is kept out of the gloss: the gate scans this file and `next` must not contain it.
        case .askRephrase: "不要让司机重新措辞再说"
        case .readList: "不要念屏幕上的列表"
        case .guessLocation: "不要猜位置"
        }
    }
}

/// F-09b §13 item 1: the one result shape. Code gives the facts and the rules; she says it in her own words.
/// `next` is built here only, from `may` and `must_not`, and never quotes a sentence to say.
public struct ToolReply: Sendable, Hashable {
    public let ok: Bool
    public let code: ToolErrorCode?
    public let facts: [String: JSONValue]
    public let may: [ReplyMay]
    public let mustNot: [ReplyMustNot]
    /// Fields outside the reply shape the caller still sends (status, candidates); never a sentence.
    public let extra: [String: JSONValue]

    public init(ok: Bool, code: ToolErrorCode?, facts: [String: JSONValue], may: [ReplyMay], mustNot: [ReplyMustNot],
                extra: [String: JSONValue] = [:]) {
        self.ok = ok
        self.code = code
        self.facts = facts
        self.may = Self.unique(may)
        self.mustNot = Self.unique(mustNot)
        self.extra = extra
    }

    public static func success(facts: [String: JSONValue], may: [ReplyMay] = [], mustNot: [ReplyMustNot] = [],
                               extra: [String: JSONValue] = [:]) -> ToolReply {
        ToolReply(ok: true, code: nil, facts: facts, may: may, mustNot: mustNot, extra: extra)
    }

    public static func failure(_ code: ToolErrorCode, facts: [String: JSONValue], may: [ReplyMay] = [],
                               mustNot: [ReplyMustNot] = [], extra: [String: JSONValue] = [:]) -> ToolReply {
        ToolReply(ok: false, code: code, facts: facts, may: may, mustNot: mustNot, extra: extra)
    }

    /// 「用自己的话简短地说。可以：…。不要：…。」
    public var next: String {
        var text = "用自己的话简短地说。"
        if !may.isEmpty { text += "可以：" + may.map(\.gloss).joined(separator: "；") + "。" }
        if !mustNot.isEmpty { text += "不要：" + mustNot.map(\.gloss).joined(separator: "；") + "。" }
        return text
    }

    /// The payload the model reads: `facts`, `may`, `must_not` (raw values) and `next`; no `advice`.
    public var result: ToolResult {
        var data = extra
        data["facts"] = .object(facts)
        data["may"] = .array(may.map { .string($0.rawValue) })
        data["must_not"] = .array(mustNot.map { .string($0.rawValue) })
        data["next"] = .string(next)
        return ToolResult(ok: ok, code: code, data: data, advice: nil)
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
