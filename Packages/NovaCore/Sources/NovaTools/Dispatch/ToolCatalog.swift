import Foundation
import NovaKit
import NovaPorts

/// One declared tool. `repeatSensitive`: an identical second call in one driver turn is dropped
/// (`RealtimeToolCatalog.ToolSpec`, `ToolCallGuards.repeatedInTurn`).
public struct ToolSpec: Sendable, Hashable {
    public let domain: String
    public let repeatSensitive: Bool
    public let declaration: ToolDeclaration
    public var name: String { declaration.name }
}

/// The product tool catalog (`A/tools/ToolRegistry.kt` + `*Domain.kt`) with each domain's argument rules.
public enum ToolCatalog {
    /// `RealtimeToolCatalog.MAX_ARGUMENT_BYTES`.
    public static let maxArgumentBytes = 4096
    public static let maxChoiceIndex = 10
    public static let choicePreferences: Set<String> = ["fastest", "shortest", "recommended", "no_toll", "fewest_lights", "nearest"]
    public static let liveInfoKinds = ["weather", "route_traffic", "along_route", "place_details", "current_location", "current_time"]
    public static let climateActions = ["power_on", "power_off", "set_temperature", "adjust_temperature", "set_fan",
                                        "adjust_fan", "get_state"]
    public static let windowActions = ["open", "close", "set", "adjust", "get_state"]
    public static let windows = ["all", "front", "rear", "driver", "passenger", "front_left", "front_right",
                                 "rear_left", "rear_right"]
    public static let seatActions = ["adjust_height", "set_height", "get_state"]
    public static let seats = ["driver", "passenger"]
    public static let speakingStyles = ["default", "sweet", "tsundere", "gentle", "lively"]

    /// All tools in Android domain order without `run_scenario` (F-09b §3 item 1, T-031c: the model decides comfort),
    /// then the iOS-only `set_volume` (F-13a) and `get_vehicle_state` (F-12 §14 item 9). iOS descriptions where the
    /// iOS flow differs (`iosDescriptions`); the climate and window texts are the model-chosen ones (F-12 §14 item 8,
    /// §18 item 1).
    public static let specs: [ToolSpec] = generatedSpecs.compactMap { spec in
        if spec.name == "run_scenario" { return nil }
        let live = spec.name == "query_live_info"
        let schema = live ? forecastArguments(longerDays(spec.declaration.parametersJSONSchema))
            : spec.declaration.parametersJSONSchema
        let description: String
        switch spec.name {
        case "query_live_info": description = forecastDescription(spec.declaration.description)
        case "control_climate": description = modelClimateDescription
        case "control_window": description = modelWindowDescription(spec.declaration.description)
        default: description = iosDescriptions[spec.name] ?? spec.declaration.description
        }
        return ToolSpec(domain: spec.domain, repeatSensitive: spec.repeatSensitive,
                        declaration: ToolDeclaration(name: spec.name, description: description,
                                                     parametersJSONSchema: schema))
    } + [volumeSpec, vehicleStateSpec, undoSpec] + tripSpecs

    // MARK: Volume (F-13a §4, T-032g)

    public static let volumeTargets = VolumeTarget.allCases.map(\.rawValue)
    public static let volumeActions = ["up", "down", "set", "mute", "max"]
    /// §4 items 1, 3, 7: the app's two volumes; the description says which target (the validator checks only the
    /// fields). Not repeat-sensitive: two 「再大一点」 are two steps. Not a comfort tool (F-09a §3 item 2).
    public static let volumeSpec = ToolSpec(domain: "media", repeatSensitive: false, declaration: ToolDeclaration(
        name: "set_volume",
        description: "司机说音量、声音大小、大声、小声、静音、最大声时一定调用。调 app 自己的音量（app 里的 0–10 档）。target：media=音乐，voice=你说话的声音。「音乐/歌声音大一点」，或正在放音乐时「音量调大」「小声点」「静音」→media；「你说话大声点」「语音音量调小」「你声音太大了」→voice；没在放音乐时「音量调大」→voice。action：up/down 调一档，set 填 value，mute 静音，max 最大。只按返回的 announce 说一句。",
        parametersJSONSchema: [
            "type": "object",
            "properties": [
                "target": ["type": "string", "enum": .array(volumeTargets.map { .string($0) })],
                "action": ["type": "string", "enum": .array(volumeActions.map { .string($0) })],
                "value": ["type": "integer", "minimum": .int(0), "maximum": .int(Int64(VolumeLevels.maximum))],
            ],
            "required": ["target", "action"],
            "additionalProperties": false,
        ]))

    /// F-18 §23 item 2: `query_live_info.day` reaches 大后天, with search on and off; §28 item 1 adds `now`.
    public static let weatherDays = ["now", "today", "tomorrow", "day_after", "day_after_next"]
    public static let dayDescription = "现在的天气、现在几度填 now；今天一整天填 today；明天 tomorrow，后天 day_after，大后天 day_after_next。"
    public static let weatherParts = ["morning", "afternoon", "evening"]
    public static let partDescription = "问上午、下午、晚上时填 morning、afternoon、evening，可以和 day 或 date 一起用。"
    static func longerDays(_ schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema, case .object(var props)? = root["properties"],
              case .object(var day)? = props["day"] else { preconditionFailure("query_live_info schema changed") }
        day["enum"] = .array(weatherDays.map { .string($0) })
        day["description"] = .string(dayDescription)
        props["day"] = .object(day)
        props["part"] = ["type": "string", "enum": .array(weatherParts.map { .string($0) }), "description": .string(partDescription)]
        root["properties"] = .object(props)
        return .object(root)
    }

    /// F-18 §26 item 1 (T-046o): `where` up to 40 with the new description, and the new `date` and `country`.
    public static let whereDescription = "here=当前位置，destination=导航目的地，或地名。中国（含香港、澳门）用中文；国外用英文名并填 country，例如 Oslo、Sendai。"
    public static let dateDescription = "说几号或星期几时填，yyyy-MM-dd。"
    public static let countryDescription = "国外地点的国家代码，例如 NO、JP、US。中国、香港、澳门不填。"
    public static let maxWhereLength = 40
    static func forecastArguments(_ schema: JSONValue) -> JSONValue {
        guard case .object(var root) = schema, case .object(var props)? = root["properties"],
              case .object(var place)? = props["where"] else { preconditionFailure("query_live_info schema changed") }
        place["maxLength"] = .int(Int64(maxWhereLength))
        place["description"] = .string(whereDescription)
        props["where"] = .object(place)
        props["date"] = ["type": "string", "description": .string(dateDescription)]
        props["country"] = ["type": "string", "description": .string(countryDescription)]
        root["properties"] = .object(props)
        return .object(root)
    }

    /// F-18 §26 item 8: the weather part of the `query_live_info` description.
    static let oldWeatherPart = "weather：「今天天气怎么样」→where=here；「目的地会下雨吗」→destination；「珠海天气」→珠海；问明天加 day=tomorrow。"
    public static let weatherPart = "weather：任何地方现在的天气，和今后10天内任何一天、上午下午晚上的天气预报。「现在天气怎么样」「外面几度」→where=here, day=now；「今天天气怎么样」→day=today；「下午会下雨吗」→part=afternoon；「目的地会下雨吗」→destination；「珠海天气」→珠海；明天、后天、大后天用 day；说几号或星期几用 date（yyyy-MM-dd），不知道今天几号先调用 current_time；国外地点用英文名并填 country：「奥斯陆11月12日天气」→where=Oslo, country=NO, date=2026-11-12。"
    static func forecastDescription(_ today: String) -> String {
        precondition(today.contains(oldWeatherPart), "query_live_info description changed")
        return today.replacingOccurrences(of: oldWeatherPart, with: weatherPart)
    }

    /// F-15a §2.5 (T-040h): iOS has no route list; guidance starts on the recommended route once the place is
    /// known, and the route is changed during the trip. Names and schemas stay the Android ones.
    /// F-13 §14 item 9 (T-032b): `play_music` plays iTunes 30 s previews; no requested_unverified sentence.
    public static let playMusicDescription = "按歌名、歌手、作品或模糊描述放歌（播放 iTunes 30 秒试听），如「梶浦由记的、空之境界里很燃的那首片头曲」「来点开车提神的」。先用你的知识确定是哪首，填 title/artist/album_or_work；先用你的知识确定一首具体的歌：title 填发行时的歌名原文（如 oblivious），artist 填演唱者（如 Kalafina）；不要把用户的原话填进 query。实在确定不了才只填 query 或 mood。只按返回的 now_playing 说在放什么；ok=false 如实说没放成。「不是这首」时再调用并填 exclude_title。无描述的「放首歌」用 control_music。"
    static let iosDescriptions: [String: String] = [
        "play_music": playMusicDescription,
        "navigate_to": "导航到地点：「导航去X」「带我去X」。只有一个地点时直接开始导航（推荐路线）；有多个时屏幕会列出候选，不要念列表，按返回的 next 只说一句，选择用 choose_navigation_option。按结果答：navigation_started 按 next 说已开始导航和大约几分钟，alternatives 只按 next 提一句，不要念所有路线；ok=false 按 next 说原因，不要说已开始。换目的地（「不是这个」「换成X」）时用新目的地再调用。没有路线时找附近的地点（「附近有加油站吗」「最近的充电站」）也用它：destination=附近的加油站。",
        "choose_navigation_option": "选屏幕上的候选地点（等同点选），或导航中换路线，三个参数只填一个。地点列表时：「第一个」「第二个」→index；「最近的那个」→nearest；「选万达广场那个」→name；选好地点后直接开始导航。导航中：「换最快的」→preference=fastest；「最短的」→shortest；「不走高速」「不要收费」→no_toll；「红绿灯少的」→fewest_lights；「推荐的」→recommended；「换第二条」→index；她问「要换吗？」后司机说「好」「换」→preference=上次结果的 offer_preference。按结果答：navigation_started 说已开始导航；route_changed 按 next 说已换成哪条路线和大约几分钟；route_unchanged 说现在走的就是这条；ok=false 按 error：OUT_OF_RANGE=没有这一项，NO_OPTIONS_ON_SCREEN=没有可选列表或没有别的路线，OPTIONS_NOT_READY=还在计算，AMBIGUOUS=多个匹配请说第几个，OPTIONS_STALE=列表过期请重新说，CONFIRM_CANDIDATE=问是不是 candidate_position 那项。",
    ]
    public static let declarations: [ToolDeclaration] = specs.map(\.declaration)
    private static let byName: [String: ToolSpec] = Dictionary(uniqueKeysWithValues: (specs + [webSearchSpec]).map { ($0.name, $0) })

    /// A declared tool, or `web_search` (declared only with search on).
    public static func spec(_ name: String) -> ToolSpec? { byName[name] }

    // MARK: Model-chosen comfort (F-12 §14 items 7-9, F-09b §3)

    /// F-12 §14 item 9: read-only vehicle state for the model's own judgement. F-09b §5 item 3: stays declared; no rule
    /// says when to call it (the state arrives by note).
    public static let vehicleStateSpec = ToolSpec(domain: "comfort", repeatSensitive: false, declaration: ToolDeclaration(
        name: "get_vehicle_state",
        description: "读取车内状态（模拟）：车窗开度、空调开关、温度、风量、是否在放音乐、是否在导航、车速（未知时为 null）。车内状态平时由系统消息告诉你；动作工具也会返回最新状态。只读，不会改变任何东西。",
        parametersJSONSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false]))

    /// F-12 §14 item 8, §18 item 2: the feeling-to-action sentences removed from `control_climate`; direct requests stay.
    static let modelClimateDescription = "控制空调（模拟）。空调主要调节温度，风量让车内空气流动。「打开/关闭空调」power_on/power_off；「调到22度」set_temperature,value=22；「温度调高/低一点」「再暖/凉一点」adjust_temperature,value=±1；「风量调到3档」set_fan,value=3；「风量调大/小」adjust_fan,value=±1；「现在多少度」get_state。相对调节用 adjust_*，不要自己推算温度。只按返回的 temperature_c/fan_level/power_on 确认；ok=false 如实说没成功。"

    /// F-12 §18 item 1: the window tool says what opening and closing are for, then today's text.
    static let windowPurpose = "开窗能换入车外空气、散掉车内异味；关窗能隔绝噪音和车外空气。"
    static func modelWindowDescription(_ today: String) -> String {
        let head = "控制车窗（模拟）。"
        precondition(today.hasPrefix(head), "control_window description changed")
        return head + windowPurpose + String(today.dropFirst(head.count))
    }


    // MARK: Trip list (F-15b §5, T-040i)

    public static let maxTripStops = 16
    public static let maxTripName = 40
    public static let tripEditActions = ["remove", "add", "replace", "move", "clear", "read"]
    public static let tripOrders = ["nearest", "as_listed"]

    public static let makeTripListDescription = "把刚才推荐的地点做成打卡清单：「做个打卡清单」「列个清单」「把这些地方存下来」。places 填地点名（最多16个，每个只写地名，不写介绍），知道城市时填 city。会替换旧清单。按结果答：只说清单有几个地点；not_found 里的地点说没找到；不要念整张清单，司机问时再念。多天的行程按天分别调用，day 填第几天：「第一天去古文化街和五大道」→day=1。"
    public static let editTripListDescription = "修改打卡清单：「去掉第二个」→remove index=2；「不去古文化街了」→remove name；「加上天津之眼」→add；「第三个换成五大道」→replace；「把瓷房子放到第一个」→move；「清单里有什么」→read；「清空清单」→clear。第几个按她最后说的清单顺序。按结果答：一句话说改了什么和现在几个地点；ok=false 按 error：NO_TRIP_LIST=还没有清单，OUT_OF_RANGE=没有这一项，NOT_FOUND=没找到这个地方，TRIP_TOO_LONG=最多16个地点，AMBIGUOUS=有多个匹配请说第几个。说到第几天时填 day，不说就是刚才那一天。"
    public static let routeTripDescription = "把打卡清单串成一条自驾路线（多个途经点）：「串成自驾路线」「规划一下路线」→start=false；看过路线后「开始导航」「出发」→start=true；「按清单顺序走」→order=as_listed，默认 nearest（就近排序，清单会按路线顺序重新编号）。只有一个地点时用 navigate_to。按结果答：按 next 说；不要念每个地点；ok=false 按 error：NO_TRIP_LIST=还没有清单，TRIP_TOO_SHORT=至少要两个地点，ROUTE_CALCULATION_FAILED=路线规划失败，START_FAILED=导航没有启动，不要说已开始。「开始第二天的导航」→day=2, start=true。"
    public static let tripPlansDescription = "保存、打开、列出、删除、改名行程：「把这个行程存成天津一日游」→save name=天津一日游；「打开天津一日游」→open；「我存了哪些行程」→list；「删掉天津那个行程」→delete；「改名叫周末出游」→rename。打开后要导航就再调用 route_trip。按结果答：一句话说做了什么；list 只说有几个和名字；ok=false 按 error：NO_TRIP_LIST=还没有清单，PLAN_NOT_FOUND=没有这个行程，PLANS_FULL=最多存20个，AMBIGUOUS=有多个请说全名。"
    public static let tripPlanActions = ["save", "open", "list", "delete", "rename"]
    public static let tripDay: JSONValue = ["type": "integer", "minimum": 1, "maximum": 5]

    public static let tripSpecs: [ToolSpec] = [
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "make_trip_list", description: makeTripListDescription,
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "places": ["type": "array", "minItems": 1, "maxItems": .int(Int64(maxTripStops)),
                               "items": ["type": "string", "minLength": 1, "maxLength": .int(Int64(maxTripName))]],
                    "city": ["type": "string", "maxLength": 20],
                    "day": tripDay,
                ],
                "required": ["places"],
                "additionalProperties": false,
            ])),
        // Not repeat-sensitive: 「去掉第一个和第二个」 is two identical remove index=1 calls, since the list renumbers.
        ToolSpec(domain: "navigation", repeatSensitive: false, declaration: ToolDeclaration(
            name: "edit_trip_list", description: editTripListDescription,
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": .array(tripEditActions.map { .string($0) })],
                    "index": ["type": "integer", "minimum": 1],
                    "name": ["type": "string", "minLength": 1, "maxLength": .int(Int64(maxTripName))],
                    "to_index": ["type": "integer", "minimum": 1],
                    "day": tripDay,
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "route_trip", description: routeTripDescription,
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "order": ["type": "string", "enum": .array(tripOrders.map { .string($0) })],
                    "start": ["type": "boolean"],
                    "day": tripDay,
                ],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "trip_plans", description: tripPlansDescription,
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": ["type": "string", "enum": .array(tripPlanActions.map { .string($0) })],
                    "name": ["type": "string", "minLength": 1, "maxLength": 20],
                    "new_name": ["type": "string", "minLength": 1, "maxLength": 20],
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
    ]

    /// F-09b §4 item 1 (T-031j): undo the last comfort change set.
    public static let undoSpec = ToolSpec(domain: "comfort", repeatSensitive: false, declaration: ToolDeclaration(
        name: "undo_last_change",
        description: "撤销刚才的车辆调整：「不用」「改回去」「刚才那个不要」「还是原来的好」。按结果答：一句话说恢复成了什么；NOTHING_TO_UNDO 说没有可以撤销的。",
        parametersJSONSchema: ["type": "object", "properties": .object([:]), "additionalProperties": false]))

    // MARK: Web search (F-18 §16, T-046d)

    /// F-18 §16 item 3: one general information tool; only declared with 「联网搜索（实验）」 on. §26 item 8: no forecasts.
    public static let webSearchSpec = ToolSpec(domain: "live_info", repeatSensitive: true, declaration: ToolDeclaration(
        name: "web_search",
        description: "查网上的信息：新闻、营业时间、价格、油价、汇率、比分等会变的信息。query 写完整的中文问题，带上地点和日期。不用于控制车辆。只按返回的 answer 回答。不用于查现在的时间、日期、星期（用 query_live_info 的 current_time）。不用于查现在的气温或10天内的天气预报（用 query_live_info 的 weather）。",
        parametersJSONSchema: [
            "type": "object",
            "properties": ["query": ["type": "string", "minLength": .int(1), "maxLength": .int(200)]],
            "required": ["query"],
            "additionalProperties": false,
        ]))

    /// F-18 §23 item 1, §26 item 8: the sentence her search-on `query_live_info` text adds (a tool description, not the search prompt).
    public static let officialFirst = "现在的气温和天气预报（今后10天内）只用 query_live_info，不用 web_search。地点营业时间先用 query_live_info；它没有数据时再用 web_search。"

    /// F-18 §16 item 9 as changed by §23 item 1: with search on, `query_live_info` keeps every kind, argument and
    /// line; only the no-data-source sentence goes, and `officialFirst` is added.
    static func searchOnLiveInfo(_ spec: ToolSpec) -> ToolSpec {
        let d = spec.declaration
        let cut = "新闻、股票、油价、汇率无数据源，不要调用，如实说无法回答。"
        precondition(d.description.contains(cut), "query_live_info description changed")
        let text = d.description.replacingOccurrences(of: cut, with: officialFirst)
        return ToolSpec(domain: spec.domain, repeatSensitive: spec.repeatSensitive,
                        declaration: ToolDeclaration(name: d.name, description: text, parametersJSONSchema: d.parametersJSONSchema))
    }

    /// The declarations a session sends. `webSearch` false is exactly `declarations`.
    public static func declarations(webSearch: Bool) -> [ToolDeclaration] {
        let base = declarations
        guard webSearch else { return base }
        let liveInfo = searchOnLiveInfo(spec("query_live_info")!).declaration
        return base.map { $0.name == "query_live_info" ? liveInfo : $0 } + [webSearchSpec.declaration]
    }

    /// Rule-violation code, `UNKNOWN_TOOL`, `ARGUMENTS_TOO_LARGE`, or nil when the call may proceed.
    public static func validate(_ call: ToolCall) -> ToolErrorCode? {
        guard spec(call.name) != nil else { return .unknownTool }
        guard case .object(let args) = call.arguments else { return .malformedJson }
        let bytes = (try? JSONValue.canonicalEncoder().encode(call.arguments).count) ?? Int.max
        if bytes > maxArgumentBytes { return .argumentsTooLarge }
        return validate(call.name, args)
    }

    // Port of each `*Domain.validate`. Lengths are UTF-16 units, as Kotlin `String.length` counts. `args.opt(k) is String/Number` checks become JSONValue cases.
    static func validate(_ name: String, _ a: [String: JSONValue]) -> ToolErrorCode? {
        let keys = Set(a.keys)
        func str(_ k: String) -> String? { a[k]?.stringValue }
        func isString(_ k: String) -> Bool { str(k) != nil }
        func num(_ k: String) -> Double? {
            switch a[k] {
            case .int(let v): Double(v)
            case .double(let v): v
            default: nil
            }
        }
        func isNumber(_ k: String) -> Bool { num(k) != nil }
        let trimmed: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        /// F-15b §15 item 2: a day is an integer 1–5.
        func isDay(_ v: JSONValue?) -> Bool {
            switch v {
            case .int(let d): (1...5).contains(d)
            case .double(let d): d.truncatingRemainder(dividingBy: 1) == 0 && (1...5).contains(d)
            default: false
            }
        }

        switch name {
        case "navigate_to":
            if keys != ["destination"] { return .invalidFields }
            guard let d = str("destination") else { return .invalidFieldType }
            if trimmed(d).isEmpty { return .blankDestination }
            if trimmed(d).utf16.count > 120 { return .destinationTooLong }
        case "choose_navigation_option":
            if keys.count != 1 || !keys.isSubset(of: ["index", "preference", "name"]) { return .invalidFields }
            if keys.contains("index") {
                let index: Int? = switch a["index"] {
                case .int(let v): Int(v)
                case .double(let v) where v.truncatingRemainder(dividingBy: 1) == 0: Int(exactly: v)
                case .string(let s): Int(trimmed(s))
                default: nil
                }
                if index == nil || !(1...maxChoiceIndex).contains(index!) { return .invalidIndex }
            } else if keys.contains("preference") {
                if !(str("preference").map(choicePreferences.contains) ?? false) { return .preferenceNotAllowed }
            } else {
                guard let n = str("name"), !trimmed(n).isEmpty, n.utf16.count <= 40 else { return .invalidName }
            }
        case "make_trip_list":
            // F-15b §5.1: 1–16 names of 1–40 characters, optional city ≤ 20.
            guard keys.contains("places"), keys.isSubset(of: ["places", "city", "day"]) else { return .invalidFields }
            if keys.contains("day"), !isDay(a["day"]) { return .invalidFields }
            guard case .array(let places)? = a["places"], (1...maxTripStops).contains(places.count) else { return .invalidFields }
            for place in places {
                guard let n = place.stringValue, !trimmed(n).isEmpty, n.utf16.count <= maxTripName else { return .invalidFields }
            }
            if keys.contains("city") {
                guard let c = str("city"), !trimmed(c).isEmpty, c.utf16.count <= 20 else { return .invalidFields }
            }
        case "edit_trip_list":
            // F-15b §5.2: the fields each action needs.
            guard let action = str("action"), tripEditActions.contains(action) else { return .invalidFields }
            guard keys.isSubset(of: ["action", "index", "name", "to_index", "day"]) else { return .invalidFields }
            if keys.contains("day"), !isDay(a["day"]) { return .invalidFields }
            let keys = keys.subtracting(["day"])
            func integer(_ k: String) -> Bool {
                switch a[k] {
                case .int: true
                case .double(let v): v.truncatingRemainder(dividingBy: 1) == 0
                default: false
                }
            }
            for k in ["index", "to_index"] where keys.contains(k) && !integer(k) { return .invalidFields }
            if keys.contains("name") {
                guard let n = str("name"), !trimmed(n).isEmpty, n.utf16.count <= maxTripName else { return .invalidFields }
            }
            let needs: Bool = switch action {
            case "remove": keys.contains("index") != keys.contains("name") && !keys.contains("to_index")
            case "add": keys.contains("name") && !keys.contains("to_index")
            case "replace": keys == ["action", "index", "name"]
            case "move": keys == ["action", "index", "to_index"]
            default: keys == ["action"]
            }
            if !needs { return .invalidFields }
        case "route_trip":
            guard keys.isSubset(of: ["order", "start", "day"]) else { return .invalidFields }
            if keys.contains("day"), !isDay(a["day"]) { return .invalidFields }
            if keys.contains("order"), !(str("order").map(tripOrders.contains) ?? false) { return .invalidFields }
            if keys.contains("start"), case .bool? = a["start"] {} else if keys.contains("start") { return .invalidFields }
        case "trip_plans":
            // F-15b §16 item 5: the fields each action needs, 1–20 characters.
            guard let action = str("action"), tripPlanActions.contains(action) else { return .invalidFields }
            for k in ["name", "new_name"] where keys.contains(k) {
                guard let v = str(k), !trimmed(v).isEmpty, v.utf16.count <= 20 else { return .invalidFields }
            }
            let need: Set<String> = switch action {
            case "list": ["action"]
            case "rename": ["action", "name", "new_name"]
            default: ["action", "name"]
            }
            if keys != need { return .invalidFields }
        case "exit_navigation_mode", "end_conversation", "get_vehicle_state", "undo_last_change":
            if !keys.isEmpty { return .invalidFields }
        case "open_app":
            if keys != ["app"] { return .invalidFields }
            guard let app = str("app") else { return .invalidFieldType }
            if !["maps", "settings"].contains(app) { return .appNotAllowed }
        case "control_music":
            if keys != ["action"] { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !["play", "stop"].contains(action) { return .actionNotAllowed }
        case "play_music":
            let fields: Set<String> = ["title", "artist", "album_or_work", "mood", "query", "exclude_title"]
            let describing = ["title", "artist", "album_or_work", "query", "mood"]
            if keys.isEmpty || !keys.isSubset(of: fields) { return .invalidFields }
            if keys.contains(where: { !isString($0) }) { return .invalidFieldType }
            if keys.contains(where: { str($0)!.utf16.count > 80 }) { return .invalidFieldValue }
            if !describing.contains(where: { !(str($0).map(trimmed) ?? "").isEmpty }) { return .missingValue }
        case "control_climate":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !climateActions.contains(action) { return .actionNotAllowed }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if ["set_temperature", "set_fan"].contains(action) && !keys.contains("value") { return .missingValue }
        case "control_window":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "window", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !windowActions.contains(action) { return .actionNotAllowed }
            if keys.contains("window") && !isString("window") { return .invalidFieldType }
            if keys.contains("window") && !windows.contains(str("window")!) { return .invalidFieldValue }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if action == "set" && !keys.contains("value") { return .missingValue }
            if action == "adjust" && keys.contains("value") && num("value") == 0 { return .invalidValue }
        case "control_seat":
            if !keys.contains("action") || !keys.isSubset(of: ["action", "seat", "value"]) { return .invalidFields }
            guard let action = str("action") else { return .invalidFieldType }
            if !seatActions.contains(action) { return .actionNotAllowed }
            if keys.contains("seat") && !isString("seat") { return .invalidFieldType }
            if keys.contains("seat") && !seats.contains(str("seat")!) { return .invalidFieldValue }
            if keys.contains("value") && !isNumber("value") { return .invalidFieldType }
            if ["set_height", "adjust_height"].contains(action) && !keys.contains("value") { return .missingValue }
            // Android: optDouble("value") == 0.0 (a missing value is NaN, already MISSING_VALUE above).
            if action == "adjust_height" && num("value") == 0 { return .invalidValue }
        case "describe_camera_view":
            if !keys.contains("question") || !keys.isSubset(of: ["question", "camera"]) { return .invalidFields }
            guard let q = str("question") else { return .invalidFieldType }
            if keys.contains("camera") && str("camera").flatMap(CameraLens.init(rawValue:)) == nil {
                return .invalidFieldValue
            }
            if trimmed(q).isEmpty { return .blankQuestion }
            if q.utf16.count > 200 { return .questionTooLong }
        case "place_call":
            return nil  // PhoneDomain: no rules beyond the schema; the handler checks its own arguments.
        case "query_live_info":
            if !keys.contains("kind") || !keys.isSubset(of: ["kind", "where", "day", "date", "country", "part", "category", "target", "time_zone"]) {
                return .invalidFields
            }
            if keys.contains(where: { !isString($0) }) { return .invalidFieldType }
            if !liveInfoKinds.contains(str("kind")!) { return .invalidKind }
            // F-18 §25 item 2: IANA names can be longer than 20 (America/Argentina/ComodRivadavia); CurrentTime checks them.
            // F-18 §26 item 1: `where` up to 40; the day, date and country rules are LiveInfoExecutor's (with advice).
            if keys.contains(where: { !["time_zone", "where"].contains($0) && str($0)!.utf16.count > 20 }) { return .invalidArgument }
            if keys.contains("where") && str("where")!.utf16.count > maxWhereLength { return .invalidArgument }
        case "web_search":
            if keys != ["query"] { return .invalidFields }
            guard let q = str("query") else { return .invalidFieldType }
            if trimmed(q).isEmpty { return .blankQuestion }
            if q.utf16.count > 200 { return .questionTooLong }
        case "set_speech_output":
            if keys != ["mode"] { return .invalidFields }
            guard let mode = str("mode") else { return .invalidFieldType }
            if !["silent", "spoken"].contains(mode) { return .modeNotAllowed }
        case "set_volume":
            // F-13a §4 item 4.
            if !keys.isSuperset(of: ["target", "action"]) || !keys.isSubset(of: ["target", "action", "value"]) {
                return .invalidFields
            }
            guard let target = str("target"), let action = str("action") else { return .invalidFieldType }
            if !volumeTargets.contains(target) { return .invalidFieldValue }
            if !volumeActions.contains(action) { return .actionNotAllowed }
            if keys.contains("value") {
                guard let v = num("value") else { return .invalidFieldType }
                if v.truncatingRemainder(dividingBy: 1) != 0 || !(0...Double(VolumeLevels.maximum)).contains(v) {
                    return .invalidFieldValue
                }
            }
            if action == "set" && !keys.contains("value") { return .missingValue }
        case "set_speaking_style":
            if keys != ["style"] { return .invalidFields }
            guard let style = str("style") else { return .invalidFieldType }
            if !speakingStyles.contains(style) { return .styleNotAllowed }
        default:
            return nil
        }
        return nil
    }
}

/// `A/ToolFailureAdvice.kt`: the one place that says what the driver hears after a refusal.
public enum ToolFailureAdvice {
    public static func forCode(_ code: ToolErrorCode) -> String? { generatedTable[code] ?? iosTable[code] }

    /// iOS-only codes (I-2): one honest sentence for a tool with no iOS executor yet.
    static let iosTable: [ToolErrorCode: String] = [
        // F-13 §14 item 8 (T-032b).
        .musicSearchFailed: "没有连上曲库，这首没有放。请用一句话如实说没放成，不要说正在放。",
        .musicNotFound: "曲库里没找到。如果还没填 title，请先确定一首具体的歌，用歌名原文和演唱者再调用一次 play_music；已经填了 title 还是没有，就如实说没找到，不要说在放。",
        .notAvailableOnIOSYet: "这个功能在这台 iPhone 上还没有做好，所以没有执行。请用一句话如实告诉用户暂时还不能用，不要说已经做了。",
        .cameraPermissionDenied: "摄像头没有权限，请在设置里允许。请如实说明，不要描述画面。",
        .cameraUnavailable: "摄像头现在用不了。请如实说明，不要描述画面。",
        .navigationNotRequested: "司机还没有选路线，所以没有开始导航。不要说已经开始或已经选好；请只问一句：有几条路线（按屏幕上的条数说），要走哪一条？",
        .confirmRequired: "导航还在继续，没有结束。不要说已经结束。",
        .vehicleBlocked: "这个操作被安全规则拦下了，没有执行。请用一句话如实告诉用户没有做和原因（看 detail），不要说已经做了。",
        // F-09b §4 item 1 (T-031j).
        .nothingToUndo: "没有可以撤销的调整，什么都没有改。请用一句话说没有可以撤销的。",
        // F-15b §5 (T-040i).
        .noTripList: "还没有打卡清单，什么都没有改。请用一句话如实说还没有清单。",
        .tripTooLong: "清单最多16个地点，这次没有加。请用一句话如实说明。",
        .tripTooShort: "清单里不到两个地点，串不成路线。请如实说至少要两个地点；只有一个地方就直接导航过去。",
        .notFound: "没找到这个地方，清单没有改。请用一句话如实说没找到，不要猜一个地方。",
        // F-15b §13 item 1 (T-040j).
        .notWhileMoving: "车在行驶，屏幕上的编辑没有执行。请用一句话说开车时请用语音改清单。",
        // F-15b §16 (T-040l).
        .planNotFound: "没有这个行程，什么都没有改。请用一句话如实说没有这个行程。",
        .plansFull: "最多存20个行程，这次没有存。请用一句话如实说明，可以先删掉一个。",
        .styleNotAllowed: "没有这种语气，语气没有改。请用一句话告诉用户只有甜、傲娇、温柔、元气和正常这几种。",
    ]
}
