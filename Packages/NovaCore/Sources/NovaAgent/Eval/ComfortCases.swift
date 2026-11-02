import NovaKit
import NovaPorts

/// F-12 §14 item 1-2 (T-031a): the comfort test set. 40 tuning cases and 16 held out, plus 10 fresh held-out cases
/// (§15 item 5, T-031d) written before the tuning round. Held-out cases are scored but
/// never used to change a prompt or a tool description; changing one needs a new held-out case in its place.
public enum ComfortCases {
    // Starting states.
    static let windowsHalf = ComfortVehicleState(cabin: CabinState(
        windows: Dictionary(uniqueKeysWithValues: WindowID.allCases.map { ($0, 50) }), seatHeights: CabinState.default.seatHeights))
    static let acOn = ComfortVehicleState(climate: ClimateState(powerOn: true, targetTemperatureCelsius: 24, fanLevel: 2))
    static let acMinimum = ComfortVehicleState(climate: ClimateState(powerOn: true, targetTemperatureCelsius: ClimateLimits.minTemperatureC,
                                                                      fanLevel: 3))
    static let fanMax = ComfortVehicleState(climate: ClimateState(powerOn: true, targetTemperatureCelsius: 24,
                                                                   fanLevel: ClimateLimits.maxFanLevel))
    static let busy = ComfortVehicleState(
        climate: ClimateState(powerOn: true, targetTemperatureCelsius: 24, fanLevel: 2),
        cabin: CabinState(windows: Dictionary(uniqueKeysWithValues: WindowID.allCases.map { ($0, 30) }),
                          seatHeights: CabinState.default.seatHeights),
        musicPlaying: true)
    static let fast = ComfortVehicleState(speedKmh: 120)
    static let windowsBroken = ComfortVehicleState(
        cabin: CabinState(windows: Dictionary(uniqueKeysWithValues: WindowID.allCases.map { ($0, 50) }),
                          seatHeights: CabinState.default.seatHeights),
        windowsFail: true)

    static let mosquitoHistory = [TextTurn(role: .user, text: "有蚊子"), TextTurn(role: .model, text: "车窗都开了一半，让蚊子飞出去。")]

    // Expected outcomes.
    static let freshAir: [[ComfortChange]] = [[.up(.windows), .up(.fan), .up(.acPower)]]
    static let cooler: [[ComfortChange]] = [[.down(.temperature), .up(.acPower), .up(.fan), .up(.windows)]]
    static let warmer: [[ComfortChange]] = [[.up(.temperature), .down(.windows), .down(.fan), .down(.acPower)]]
    static let awake: [[ComfortChange]] = [[.down(.temperature), .up(.windows), .up(.fan), .up(.music), .up(.acPower)]]
    static let everything = Set(ComfortFacet.allCases)
    static let rest = ["休息", "服务区"]

    public static let all: [ComfortCase] = [
        // Comfort, wordings the table and the prompts name.
        ComfortCase("mosquito", "有蚊子", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat]),
        ComfortCase("mosquitoStill", "蚊子还没走", group: .comfort, expected: .act,
                    requireAny: [[.up(.fan), .up(.acPower), .changed(.windows)]], forbidden: [.temperature, .music, .seat],
                    start: windowsHalf, history: mosquitoHistory),
        ComfortCase("mosquitoGoneClose", "蚊子出去了，关上吧", group: .comfort, expected: .act,
                    requireAny: [[.down(.windows)]], forbidden: [.temperature, .music, .seat],
                    start: windowsHalf, history: mosquitoHistory),
        ComfortCase("mosquitoGone", "蚊子出去了", group: .comfort, expected: .act, accepted: [.ask, .noTool],
                    requireAny: [[.down(.windows)]], forbidden: [.temperature, .music, .seat],
                    start: windowsHalf, history: mosquitoHistory),
        ComfortCase("stuffy", "有点闷", group: .comfort, expected: .act, requireAny: freshAir, forbidden: [.music, .seat]),
        ComfortCase("odor", "有异味", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.music, .temperature, .seat]),
        ComfortCase("drowsy", "好困", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat], mention: rest),
        ComfortCase("hot", "有点热", group: .comfort, expected: .act, requireAny: cooler, forbidden: [.music, .seat]),
        ComfortCase("hotStill", "还是有点热", group: .comfort, expected: .act, requireAny: cooler, forbidden: [.music, .seat],
                    start: acOn),
        ComfortCase("cold", "有点冷", group: .comfort, expected: .act, requireAny: warmer, forbidden: [.music, .seat],
                    start: acOn),
        ComfortCase("stuffyAcOn", "有点闷，空调开着也不行", group: .comfort, expected: .act,
                    requireAny: [[.up(.windows), .up(.fan)]], forbidden: [.music, .seat], start: acOn),
        ComfortCase("drowsyMusicOn", "好困啊", group: .comfort, expected: .act,
                    requireAny: [[.down(.temperature), .up(.windows), .up(.fan), .up(.acPower)]], forbidden: [.seat],
                    start: busy, mention: rest),

        // Comfort, wordings in no prompt or description (item 2: at least 10).
        ComfortCase("flewIn", "车里飞进来一只蚊子", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], unprompted: true),
        ComfortCase("smoke", "有烟味", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], unprompted: true),
        ComfortCase("fallingAsleep", "我快睡着了", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat],
                    mention: rest, unprompted: true),
        ComfortCase("smelly", "车里好臭", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], unprompted: true),
        ComfortCase("sweaty", "后背全是汗", group: .comfort, expected: .act, requireAny: cooler, forbidden: [.music, .seat],
                    unprompted: true),
        ComfortCase("buzzing", "有只虫子在耳边嗡嗡叫", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], unprompted: true),
        ComfortCase("shivering", "冷得直发抖", group: .comfort, expected: .act, requireAny: warmer, forbidden: [.music, .seat],
                    start: acOn, unprompted: true),

        // Direct requests.
        ComfortCase("acOn", "打开空调", group: .direct, expected: .act, requireAny: [[.up(.acPower)]],
                    forbidden: [.windows, .music, .seat]),
        ComfortCase("windowsHalf", "车窗开一半", group: .direct, expected: .act, requireAny: [[.up(.windows)]],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat]),
        ComfortCase("temp22", "温度调到22度", group: .direct, expected: .act, requireAny: [[.down(.temperature)]],
                    forbidden: [.windows, .music, .seat]),
        ComfortCase("fanUp", "风量调大一点", group: .direct, expected: .act, requireAny: [[.up(.fan)]],
                    forbidden: [.windows, .temperature, .music, .seat], start: acOn),
        ComfortCase("playSong", "放首歌", group: .direct, expected: .act, requireAny: [[.up(.music)]],
                    forbidden: [.windows, .acPower, .temperature, .fan, .seat]),
        ComfortCase("acOff", "关掉空调", group: .direct, expected: .act, requireAny: [[.down(.acPower)]],
                    forbidden: [.windows, .music, .seat], start: acOn),
        ComfortCase("driverWindow", "把主驾车窗打开", group: .direct, expected: .act, requireAny: [[.up(.windows)]],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat]),
        ComfortCase("closeWindows", "把车窗都关上", group: .direct, expected: .act, requireAny: [[.down(.windows)]],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat], start: windowsHalf),
        ComfortCase("stopMusic", "别放歌了", group: .direct, expected: .act, requireAny: [[.down(.music)]],
                    forbidden: [.windows, .acPower, .temperature, .fan, .seat], start: busy),
        ComfortCase("warmer", "再暖一点", group: .direct, expected: .act, requireAny: [[.up(.temperature)]],
                    forbidden: [.windows, .music, .seat], start: acOn),

        // State: nothing to do, or the limit is reached.
        ComfortCase("colderAtMin", "再冷一点", group: .state, expected: .act, accepted: [.noTool],
                    forbidden: [.windows, .temperature, .music, .seat], start: acMinimum),
        ComfortCase("closeClosed", "关窗", group: .state, expected: .act, accepted: [.noTool], forbidden: everything),
        ComfortCase("acAlreadyOn", "打开空调", group: .state, expected: .act, accepted: [.noTool],
                    forbidden: [.windows, .temperature, .music, .seat], start: acOn),
        ComfortCase("fanAtMax", "风再大一点", group: .state, expected: .act, accepted: [.noTool],
                    forbidden: [.windows, .temperature, .music, .seat], start: fanMax),

        // Should ask.
        ComfortCase("closeWhat", "帮我关一下", group: .ask, expected: .ask, forbidden: everything, start: busy),
        ComfortCase("adjustWhat", "帮我调一下", group: .ask, expected: .ask, forbidden: everything, start: busy),

        // Should not act.
        ComfortCase("joke", "讲个笑话", group: .noAction, expected: .noTool, forbidden: everything),
        ComfortCase("mosquitoAnimal", "蚊子是什么动物", group: .noAction, expected: .noTool, forbidden: everything),
        ComfortCase("friendMosquito", "我朋友车里有蚊子", group: .noAction, expected: .noTool, forbidden: everything),
        ComfortCase("whyDrowsy", "为什么开车容易犯困", group: .noAction, expected: .noTool, forbidden: everything),
        ComfortCase("acPrinciple", "空调制冷是什么原理", group: .noAction, expected: .noTool, forbidden: everything),

        // Blocked by code (item 11): at 120 km/h a window opens at most 30%.
        ComfortCase("openAllFast", "车窗全打开", group: .blocked, expected: .refuse, accepted: [.act],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat], start: fast, maxWindowPercent: 30),

        // Held out (item 1): scored, never tuned on.
        ComfortCase("hMoldy", "车里一股霉味", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], heldOut: true, unprompted: true),
        ComfortCase("hEyelids", "眼皮在打架", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat],
                    mention: rest, heldOut: true, unprompted: true),
        ComfortCase("hNoAir", "感觉透不过气", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.music, .seat], heldOut: true, unprompted: true),
        ComfortCase("hFreezing", "冻死了", group: .comfort, expected: .act, requireAny: warmer, forbidden: [.music, .seat],
                    start: acOn, heldOut: true, unprompted: true),
        ComfortCase("hDizzy", "脑袋昏昏沉沉的", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat],
                    mention: rest, heldOut: true, unprompted: true),
        ComfortCase("hStale", "空气不太新鲜", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.music, .seat], heldOut: true, unprompted: true),
        ComfortCase("hMosquitoBite", "被蚊子咬了一口", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], heldOut: true, unprompted: true),
        ComfortCase("hRearHalf", "后排车窗开一半", group: .direct, expected: .act, requireAny: [[.up(.windows)]],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat], heldOut: true),
        ComfortCase("hTemp20", "温度调到20度", group: .direct, expected: .act, requireAny: [[.down(.temperature)]],
                    forbidden: [.windows, .music, .seat], heldOut: true),
        ComfortCase("hWarmerAtMax", "再热一点", group: .state, expected: .act, accepted: [.noTool],
                    forbidden: [.windows, .temperature, .music, .seat],
                    start: ComfortVehicleState(climate: ClimateState(powerOn: true, targetTemperatureCelsius: ClimateLimits.maxTemperatureC,
                                                                     fanLevel: 2)), heldOut: true),
        ComfortCase("hOpenWhat", "帮我开一下", group: .ask, expected: .ask, forbidden: everything, start: busy, heldOut: true),
        ComfortCase("hColleagueSmoke", "我同事说他车里全是烟味", group: .noAction, expected: .noTool, forbidden: everything,
                    heldOut: true),
        ComfortCase("hMosquitoSeason", "蚊子一般几月份最多", group: .noAction, expected: .noTool, forbidden: everything,
                    heldOut: true),
        ComfortCase("hStuffyFast", "有点闷", group: .blocked, expected: .act, accepted: [.refuse],
                    forbidden: [.music, .seat], start: fast, maxWindowPercent: 30, heldOut: true),
        // Row 9: the window move fails; she must say so.
        ComfortCase("hCloseBroken", "关窗", group: .blocked, expected: .refuse, forbidden: everything, start: windowsBroken,
                    heldOut: true),

        // §15 item 5 (T-031d): fresh held-out cases, written before the tuning round; 7 unprompted comfort wordings.
        ComfortCase("h2Steamer", "热得像蒸笼一样", group: .comfort, expected: .act, requireAny: cooler, forbidden: [.music, .seat],
                    heldOut: true, unprompted: true),
        ComfortCase("h2NumbHands", "手都冻僵了", group: .comfort, expected: .act, requireAny: warmer, forbidden: [.music, .seat],
                    start: acOn, heldOut: true, unprompted: true),
        ComfortCase("h2Fly", "有只苍蝇在车里乱飞", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], heldOut: true, unprompted: true),
        ComfortCase("h2Petrol", "好像有股汽油味", group: .comfort, expected: .act, requireAny: freshAir,
                    forbidden: [.temperature, .music, .seat], heldOut: true, unprompted: true),
        ComfortCase("h2EyesClosing", "眼睛快睁不开了", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat],
                    mention: rest, heldOut: true, unprompted: true),
        ComfortCase("h2Yawning", "开得我直打哈欠", group: .comfort, expected: .act, requireAny: awake, forbidden: [.seat],
                    mention: rest, heldOut: true, unprompted: true),
        ComfortCase("h2Damp", "车里潮乎乎的", group: .comfort, expected: .act, requireAny: freshAir, forbidden: [.music, .seat],
                    heldOut: true, unprompted: true),
        ComfortCase("h2PassengerClose", "把副驾车窗关上", group: .direct, expected: .act, requireAny: [[.down(.windows)]],
                    forbidden: [.acPower, .temperature, .fan, .music, .seat], start: windowsHalf, heldOut: true),
        ComfortCase("h2RaiseWhat", "帮我调高一点", group: .ask, expected: .ask, forbidden: everything, start: busy, heldOut: true),
        ComfortCase("h2LastNight", "我昨晚热得睡不着", group: .noAction, expected: .noTool, forbidden: everything, heldOut: true),
    ]

    /// §15 item 5: the fresh held-out ids, reported on their own.
    public static let fresh: Set<String> = ["h2Steamer", "h2NumbHands", "h2Fly", "h2Petrol", "h2EyesClosing", "h2Yawning",
                                            "h2Damp", "h2PassengerClose", "h2RaiseWhat", "h2LastNight"]
}
