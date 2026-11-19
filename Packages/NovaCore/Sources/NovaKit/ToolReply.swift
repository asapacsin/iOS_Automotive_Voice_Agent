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
    /// F-09b §13 item 4 (T-031m): something is still running; she may say it takes a moment.
    case waitBriefly = "wait_briefly"
    /// She may ask the driver to confirm the place in `facts` (F-16 §14 item 5).
    case askConfirm = "ask_confirm"
    /// She may ask where the driver wants to go, or what to look up.
    case askDestination = "ask_destination"
    /// She may offer to look nearby instead (no guidance, so nothing along a route).
    case offerNearby = "offer_nearby"
    /// She may ask what the driver wants (a song, a name, an address).
    case askWhat = "ask_what"
    /// She may say how the driver turns it back on (the command in `facts`).
    case nameCommand = "name_command"

    public var gloss: String {
        switch self {
        case .searchWider: "可以自己再搜远一点"
        case .similarPlace: "可以搜相近的地方（比如服务区、休息区）"
        case .offerNearest: "可以提议去 facts 里最近的那个"
        case .askPick: "可以问司机选哪个"
        case .tryLater: "可以说稍后再试"
        case .askPlace: "可以问司机是哪个城市或地方"
        case .nameSetting: "可以说要在设置里打开或配置什么"
        case .waitBriefly: "可以说稍等一下"
        case .askConfirm: "可以问司机是不是 facts 里的那个"
        case .askDestination: "可以问司机要去哪里或查哪里"
        case .offerNearby: "可以提议查附近的"
        case .askWhat: "可以问司机想要什么"
        case .nameCommand: "可以说 facts 里的说法怎么打开"
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
    /// F-09b §13 item 4 (T-031m): a camera answer that has no picture.
    case describeView = "describe_view"

    public var gloss: String {
        switch self {
        case .claimStarted: "不要说已经开始"
        case .claimDone: "不要说已经做好"
        case .invent: "不要说 facts 里没有的地点、数字或时间"
        // Item 8's phrase is kept out of the gloss: the gate scans this file and `next` must not contain it.
        case .askRephrase: "不要让司机重新措辞再说"
        case .readList: "不要念屏幕上的列表"
        case .guessLocation: "不要猜位置"
        case .describeView: "不要描述画面"
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

    /// F-09b §13 item 4 (T-031m): not done or not yet. `must_not` always carries `claim_started` and `claim_done`.
    public static func notDone(_ code: ToolErrorCode, facts: [String: JSONValue], may: [ReplyMay] = [],
                               mustNot: [ReplyMustNot] = [], extra: [String: JSONValue] = [:]) -> ToolReply {
        failure(code, facts: facts, may: may, mustNot: [.claimStarted, .claimDone] + mustNot, extra: extra)
    }

    /// F-09b §13 item 4 (T-031m): choosing. `facts` are what is on screen (`on_screen` count, the matching
    /// `names`); `may` `ask_pick`; nothing was picked or started.
    public static func choosing(_ code: ToolErrorCode, onScreen count: Int, names: [String] = [],
                                facts extra: [String: JSONValue] = [:], may: [ReplyMay] = [],
                                mustNot: [ReplyMustNot] = []) -> ToolReply {
        var facts = extra
        facts["on_screen"] = .int(Int64(count))
        if !names.isEmpty { facts["names"] = .array(names.map(JSONValue.string)) }
        return failure(code, facts: facts, may: [.askPick] + may, mustNot: [.claimStarted, .invent] + mustNot)
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
