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
    /// F-09b §13 item 5 (T-031n): the driver asked to hear the list; she reads it in the `stops` order.
    case readListInOrder = "read_list_in_order"
    /// She may ask where the trip starts.
    case askStart = "ask_start"
    // F-09b §13 item 6 (T-031o): the moves of the ToolFailureAdvice entries (wording from the Android table).
    case restateOptions = "restate_options"
    case askCandidate = "ask_candidate"
    case askWhichOption = "ask_which_option"
    case useCloseWindow = "use_close_window"
    case answerFromLast = "answer_from_last"
    case askCall = "ask_call"
    case askFullName = "ask_full_name"
    case useAlongRoute = "use_along_route"
    case sayGuidanceContinues = "say_guidance_continues"
    case answerTurn = "answer_turn"
    case usePlayMusic = "use_play_music"
    case useNavigateNearby = "use_navigate_nearby"
    case askAddress = "ask_address"
    case retryWithTitle = "retry_with_title"
    case askRoute = "ask_route"
    case sayDetail = "say_detail"
    case offerDirect = "offer_direct"
    case useVoice = "use_voice"
    case sayEndFirst = "say_end_first"
    case offerDelete = "offer_delete"
    case askNextDay = "ask_next_day"
    case offerMake = "offer_make"
    case nameStyles = "name_styles"
    case powerOnClimate = "power_on_climate"

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
        case .readListInOrder: "按 stops 的顺序念清单，每个只念序号和名字"
        case .askStart: "可以问司机从哪里出发"
        case .restateOptions: "可以按 options_on_screen 简要重新说有哪几项，再问司机要第几个"
        case .askCandidate: "可以问司机是不是 candidate_position 那一项（说出序号和名称）"
        case .askWhichOption: "可以反问司机是 options 里的哪一项"
        case .useCloseWindow: "司机是想关窗就用 control_window action=close 正常关窗"
        case .answerFromLast: "按上一次的结果回答"
        case .askCall: "可以问司机是否要给这个人打电话；确认后用 confirmed=true 再调用一次 place_call"
        case .askFullName: "可以请司机说完整的名字"
        case .useAlongRoute: "调用 query_live_info（kind=along_route）查沿途的，再按结果回答；司机明确说要去那里时再调用 navigate_to"
        case .sayGuidanceContinues: "可以说导航还在继续，要结束请说结束导航"
        case .answerTurn: "简短回应这句话本身，没听清就请司机再说一遍"
        case .usePlayMusic: "司机说了歌名、歌手、作品或描述时改用 play_music 按描述去放"
        case .useNavigateNearby: "司机在找附近的地点（例如加油站、充电站）时改用 navigate_to 搜索"
        case .askAddress: "可以请司机直接说出地址"
        case .retryWithTitle: "还没填 title 就先确定一首具体的歌，用歌名原文和演唱者再调用一次 play_music"
        case .askRoute: "可以问司机要走哪一条（按屏幕上的条数）"
        case .sayDetail: "可以说没有做和原因（看 detail）"
        case .offerDirect: "只有一个地方时可以直接导航过去"
        case .useVoice: "可以说开车时请用语音改清单"
        case .sayEndFirst: "可以说要先结束导航"
        case .offerDelete: "可以说先删掉一个"
        case .askNextDay: "可以问司机要不要开始下一天"
        case .offerMake: "可以说先做一个行程"
        case .nameStyles: "可以说有哪几种语气：甜、傲娇、温柔、元气和正常"
        case .powerOnClimate: "先调用 control_climate{action=power_on} 把空调打开，成功后再告诉司机"
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
    /// F-09b §13 item 5 (T-031n): distances stay on the cards.
    case readDistances = "read_distances"
    /// The other routes stay on the screen; she names at most the one offer in `facts`.
    case readRoutes = "read_routes"
    /// A request was sent and not yet seen to work (music handed to the app).
    case claimPlaying = "claim_playing"
    // F-09b §13 item 6 (T-031o): the rules of the ToolFailureAdvice entries.
    case callTools = "call_tools"
    case claimRepeated = "claim_repeated"
    case sayContactMissing = "say_contact_missing"
    case claimEnded = "claim_ended"
    case askEnd = "ask_end"
    case mentionQuiet = "mention_quiet"
    case speak = "speak"

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
        case .readDistances: "不要念距离"
        case .readRoutes: "不要念其他路线"
        case .claimPlaying: "不要说正在播放"
        case .callTools: "不要再调用任何工具"
        case .claimRepeated: "不要说又做了一次"
        case .sayContactMissing: "不要说没找到这个人"
        case .claimEnded: "不要说导航已经结束"
        case .askEnd: "不要问要不要结束导航"
        case .mentionQuiet: "不要提安静或不说话的事"
        case .speak: "不要说任何话"
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
