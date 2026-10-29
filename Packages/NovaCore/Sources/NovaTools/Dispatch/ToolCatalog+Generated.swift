// swiftlint:disable line_length
// Generated from the Android tables byte for byte (F-09); long literals stay on one line.
// GENERATED from the Android tool domains (evidence batch 1, commit 9c53929). Do not edit by hand:
// names, descriptions and schemas must stay byte-for-byte equal to Android (F-09 iOS notes).
import NovaKit
import NovaPorts

extension ToolCatalog {
    static let generatedSpecs: [ToolSpec] = [
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "navigate_to",
            description: "导航到地点：「导航去X」「带我去X」。屏幕会列出候选，不要念列表，按返回的 next 只说一句，选择用 choose_navigation_option；选好路线前导航未开始，不要说已开始。换目的地（「不是这个」「换成X」）时用新目的地再调用。没有路线时找附近的地点（「附近有加油站吗」「最近的充电站」）也用它：destination=附近的加油站。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "destination": [
                        "type": "string",
                        "minLength": .int(1),
                        "maxLength": .int(120),
                    ],
                ],
                "required": ["destination"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "navigation", repeatSensitive: false, declaration: ToolDeclaration(
            name: "choose_navigation_option",
            description: "选屏幕上的候选地点或路线（等同点选），三个参数只填一个。「第一个」「第二条」→index；「最快的」→preference=fastest；「最短的」→shortest；「推荐的」→recommended；「不要收费」→no_toll；路线列表时「开始导航」「就这条」→recommended；「红绿灯少的」→fewest_lights；「最近的那个」→nearest；「选万达广场那个」→name。按结果答：destination_selected 不念路线，按 next 说一句请选路线；navigation_started 说导航已开始；ok=false 按 error：OUT_OF_RANGE=没有这一项，NO_OPTIONS_ON_SCREEN=没有可选列表，OPTIONS_NOT_READY=还在计算，AMBIGUOUS=多个匹配请说第几个，OPTIONS_STALE=列表过期请重新说，CONFIRM_CANDIDATE=问是不是 candidate_position 那项。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "index": [
                        "type": "integer",
                        "minimum": .int(1),
                        "maximum": .int(10),
                    ],
                    "preference": [
                        "type": "string",
                        "enum": ["fastest", "shortest", "recommended", "no_toll", "fewest_lights", "nearest"],
                    ],
                    "name": [
                        "type": "string",
                        "minLength": .int(1),
                        "maxLength": .int(40),
                    ],
                ],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "exit_navigation_mode",
            description: "真正停止屏幕导航或关闭候选列表：「结束导航」「取消导航」「退出导航」；候选列表显示时「算了」「不用了」「不去了」「返回」关闭列表。导航中只说「算了」「不去了」不会结束导航。只口头答应不调用则屏幕不变。按 status 答：navigation_stopped=已结束，navigation_selection_cancelled=已取消选择，no_navigation_active=当前没有导航。",
            parametersJSONSchema: [
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "navigation", repeatSensitive: true, declaration: ToolDeclaration(
            name: "save_place",
            description: "记住家或公司：「我家在XX」「我公司在XX」→slot=home/work，address 填地址。之后「回家」「去公司」可直接导航。ok=false 按 error 如实说，不要谎称已保存。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "slot": [
                        "type": "string",
                        "enum": ["home", "work"],
                    ],
                    "address": [
                        "type": "string",
                        "minLength": .int(1),
                        "maxLength": .int(120),
                    ],
                ],
                "required": ["slot", "address"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "apps", repeatSensitive: true, declaration: ToolDeclaration(
            name: "open_app",
            description: "打开应用：maps=地图，settings=设置。音乐用 control_music。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "app": [
                        "type": "string",
                        "enum": ["maps", "settings"],
                    ],
                ],
                "required": ["app"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "media", repeatSensitive: true, declaration: ToolDeclaration(
            name: "control_music",
            description: "内置音乐播放器：「播放音乐」「放首歌」→play；「关闭音乐」「别放了」→stop。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["play", "stop"],
                        "description": "play=播放；stop=停止",
                    ],
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "media", repeatSensitive: true, declaration: ToolDeclaration(
            name: "play_music",
            description: "按歌名、歌手、作品或模糊描述放歌（用手机音乐 app），如「梶浦由记的、空之境界里很燃的那首片头曲」「来点开车提神的」。先用你的知识确定是哪首，填 title/artist/album_or_work；确定不了只填 query 和 mood。只按返回的 now_playing 说在放什么；status=requested_unverified 只说「已经让音乐 app 去找了」；ok=false 如实说没放成。「不是这首」时再调用并填 exclude_title。无描述的「放首歌」用 control_music。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "title": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "你确定的歌名",
                    ],
                    "artist": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "歌手或作曲者",
                    ],
                    "album_or_work": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "专辑或作品（动画、电影、游戏）",
                    ],
                    "mood": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "情绪，如燃、提神",
                    ],
                    "query": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "用户原话",
                    ],
                    "exclude_title": [
                        "type": "string",
                        "maxLength": .int(80),
                        "description": "「不是这首」时刚才那首歌名",
                    ],
                ],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "climate", repeatSensitive: true, declaration: ToolDeclaration(
            name: "control_climate",
            description: "控制空调（模拟）。「打开/关闭空调」power_on/power_off；「调到22度」set_temperature,value=22；「温度调高/低一点」「再暖/凉一点」adjust_temperature,value=±1；「风量调到3档」set_fan,value=3；「风量调大/小」adjust_fan,value=±1；「现在多少度」get_state。相对调节用 adjust_*，不要自己推算温度。描述感受时直接调，不要反问：「有点热」「还是有点热」adjust_temperature,value=-2；「有点冷」value=2；「风太大」adjust_fan,value=-1；「风太小」value=1。「有点闷」不是调风量，用 run_scenario name=stuffy。只按返回的 temperature_c/fan_level/power_on 确认；ok=false 如实说没成功。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["power_on", "power_off", "set_temperature", "adjust_temperature", "set_fan", "adjust_fan", "get_state"],
                    ],
                    "value": [
                        "type": "number",
                        "description": "set_temperature: 16-32 摄氏度；set_fan: 0-7 档；adjust_*: 变化量，默认 1",
                    ],
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "body", repeatSensitive: true, declaration: ToolDeclaration(
            name: "control_window",
            description: "控制车窗（模拟）。「打开车窗」open；「关窗」close；「车窗开一半」set,value=50；「开一点主驾车窗」「我这边的窗户开一点」adjust,window=driver,value=20；「副驾关小一点」adjust,window=passenger,value=-20；「车窗开了多少」get_state。我这边、我这侧是主驾，不是未指明。未指明窗时 window=all。只按返回的 windows/announce 确认；ok=false 如实说没成功。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["open", "close", "set", "adjust", "get_state"],
                    ],
                    "window": [
                        "type": "string",
                        "enum": ["all", "front", "rear", "driver", "passenger", "front_left", "front_right", "rear_left", "rear_right"],
                    ],
                    "value": [
                        "type": "number",
                        "description": "set: 0-100 开度百分比；adjust: 变化量（正数开大，负数关小），默认 20",
                    ],
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "body", repeatSensitive: true, declaration: ToolDeclaration(
            name: "control_seat",
            description: "调座椅高度（模拟）。「座椅调高一点」「再调高一点」「座位有点低」adjust_height,value=1；「座位有点高」value=-1；「调到最低」set_height,value=0；「最高」value=10；「座椅多高」get_state。未指明座位时 seat=driver。描述感受时直接调一档，不要反问。只按返回的 seat_height/announce 确认；ok=false 如实说没成功。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["adjust_height", "set_height", "get_state"],
                    ],
                    "seat": [
                        "type": "string",
                        "enum": ["driver", "passenger"],
                    ],
                    "value": [
                        "type": "number",
                        "description": "set_height: 0-10 档；adjust_height: 变化档数（负数降低，正数升高），必填",
                    ],
                ],
                "required": ["action"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "comfort", repeatSensitive: true, declaration: ToolDeclaration(
            name: "run_scenario",
            description: "执行固定舒适场景。「有蚊子」name=mosquito；「蚊子还没走」再调用 mosquito（车窗已开时改为调大风量）；刚执行 mosquito 后「蚊子出去了，关上吧」name=mosquito_done；「有点闷」「有异味」stuffy；「好困」drowsy。描述感受时直接执行，不要反问。按返回的 announce 说做了什么，没做成的也要说。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "enum": ["mosquito", "mosquito_done", "stuffy", "drowsy"],
                    ],
                ],
                "required": ["name"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "vision", repeatSensitive: false, declaration: ToolDeclaration(
            name: "describe_camera_view",
            description: "看摄像头画面回答：「看看前面有什么」「画面里有几个人」「这是什么」「后面是什么」（无其他上下文时一律当作问画面），question 填原问题；问后面、后排、车里时 camera=rear_view，问前面、路上时 camera=front_view，都没说就不填。需几秒，结果返回前什么都不要说（不描述画面，也不说摄像头不能用）。只按返回的 answer 答；ok=false 只转述 message，绝不猜测画面。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "question": [
                        "type": "string",
                        "minLength": .int(1),
                        "maxLength": .int(200),
                    ],
                    "camera": [
                        "type": "string",
                        "enum": ["front_view", "rear_view"],
                    ],
                ],
                "required": ["question"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "phone", repeatSensitive: true, declaration: ToolDeclaration(
            name: "place_call",
            description: "打电话：「打电话给XX」，contact 填人名。首次不填 confirmed，只找人不拨号。按 status：confirm_required=问是否要打；ambiguous=多个同名，问哪一位。用户明确答应后才用 confirmed=true 再调用。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "contact": [
                        "type": "string",
                        "minLength": .int(1),
                        "maxLength": .int(40),
                    ],
                    "confirmed": [
                        "type": "string",
                        "enum": ["true", "false"],
                        "description": "只有用户明确同意后才填 true",
                    ],
                ],
                "required": ["contact"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "live_info", repeatSensitive: true, declaration: ToolDeclaration(
            name: "query_live_info",
            description: "查询高德实时信息，只按返回结果回答，绝不编造天气、路况或地点。weather：「今天天气怎么样」→where=here；「目的地会下雨吗」→destination；「珠海天气」→珠海；问明天加 day=tomorrow。route_traffic（导航中）：「前面堵不堵」「路况怎么样」。along_route（有路线时）：「路上有加油站吗」→category=fuel；「沿途充电站」→charging；「下一个服务区」→service_area；「路上有厕所吗」→toilet；没有路线时「附近有加油站吗」不用 along_route，改用 navigate_to；结果显示在屏幕，用户说第几个再用 choose_navigation_option。place_details：「目的地几点关门」→target=destination；「第二个几点开门」→target=2。current_location：「我现在在哪」「这是哪里」「我在什么路上」，只按返回的 address 回答，不要说没有定位权限除非返回 LOCATION_PERMISSION_DENIED。新闻、股票、油价、汇率无数据源，不要调用，如实说无法回答。ok=false 按 next 说原因，不要猜。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "kind": [
                        "type": "string",
                        "enum": ["weather", "route_traffic", "along_route", "place_details", "current_location"],
                    ],
                    "where": [
                        "type": "string",
                        "maxLength": .int(20),
                        "description": "weather：here=当前位置，destination=导航目的地，或城市名",
                    ],
                    "day": [
                        "type": "string",
                        "enum": ["today", "tomorrow"],
                    ],
                    "category": [
                        "type": "string",
                        "enum": ["fuel", "charging", "service_area", "toilet"],
                    ],
                    "target": [
                        "type": "string",
                        "maxLength": .int(20),
                        "description": "place_details：destination 或屏幕候选的序号",
                    ],
                ],
                "required": ["kind"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "speech", repeatSensitive: false, declaration: ToolDeclaration(
            name: "end_conversation",
            description: "结束对话，小诺进入待命（「你好小诺」唤醒）。仅在用户明确不需要了时调用：「没事了，你休息吧」「不聊了」。调用后只说一句短道别。不用于关空调、音乐、导航、车窗，也不用于「算了」取消导航选择。",
            parametersJSONSchema: [
                "type": "object",
                "properties": .object([:]),
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "speech", repeatSensitive: false, declaration: ToolDeclaration(
            name: "set_speech_output",
            description: "「别说了」「安静」「停止说话」「停止說話」→mode=silent：立刻停说但继续听，下一句照常执行，无需唤醒，调用后不要再说话（不是休眠，休眠用 end_conversation）。「继续说」「可以说话了」→mode=spoken。不用于音乐、导航播报或音量。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "mode": [
                        "type": "string",
                        "enum": ["silent", "spoken"],
                    ],
                ],
                "required": ["mode"],
                "additionalProperties": false,
            ])),
        ToolSpec(domain: "speech", repeatSensitive: true, declaration: ToolDeclaration(
            name: "set_speaking_style",
            description: "切换小诺说话的语气（只改语气，不改声音），一直保持到再次更改。说的是她「说话」怎样（「说话能不能嗲一点」「说话再稍微嗲一点」），就是语气，不是空调、座椅或车窗的调节。「嗲一点」「甜一点」「可爱一点」「撒个娇」→sweet；「傲娇一点」「傲嬌一點」→tsundere；「温柔一点」→gentle；「元气一点」「活泼一点」→lively；「正常一点」「别嗲了」→default。不在其中的语气（如「霸道一点」）不要调用也不要替换，说只有甜、傲娇、温柔、元气和正常。调用后按返回的 instruction 用新语气简短回应。",
            parametersJSONSchema: [
                "type": "object",
                "properties": [
                    "style": [
                        "type": "string",
                        "enum": ["default", "sweet", "tsundere", "gentle", "lively"],
                    ],
                ],
                "required": ["style"],
                "additionalProperties": false,
            ])),
    ]
}
// swiftlint:enable line_length
