import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

// Tables ported from the Android `ToolCallGuard*Test` files (commit 9c53929). Each list is copied.

func call(_ name: String, _ args: [String: JSONValue] = [:], id: String = "c1") -> ToolCall {
    ToolCall(id: CallID(id)!, name: name, arguments: .object(args))
}

/// `context(said, epoch = 1)`: speech onset and transcript in the same turn.
func ctx(_ said: String, epoch: Int = 1, onset: Int? = nil, navigating: Bool = false, guidance: Bool = false,
         listOpen: Bool = false) -> GuardContext {
    GuardContext(requestText: said, currentEpoch: epoch, capabilityEpoch: onset ?? epoch, navigating: navigating,
                 guidanceRunning: guidance, listOpen: listOpen)
}

@Suite("T-017 F-09 guard: sunroofOnWindowTool")
struct SunroofGuardTests {
    let openAll = call("control_window", ["action": "open", "window": "all"])

    @Test("F-09 打开天窗 gives UNSUPPORTED_BODY_PART and no window moves")
    func sunroofThroughDispatcher() {
        var dispatcher = ToolDispatcher()
        guard case .refuse(let r) = dispatcher.decide(openAll, context: ctx("帮我把天窗打开。")) else {
            Issue.record("window call ran"); return
        }
        #expect(!r.ok && r.code == .unsupportedBodyPart)
        #expect(r.advice!.contains("没有执行") && r.advice!.contains("不要改开车窗"))
        let live = TranscriptText.normalize("帮 我 把 天 窗 打 开 。")
        #expect(ToolCallGuards.sunroofOnWindowTool(openAll, ctx(live)) == .unsupportedBodyPart)
        #expect(ToolCallGuards.sunroofOnWindowTool(openAll, ctx("帮 我 把 天 窗 打 开 。")) == .unsupportedBodyPart)
    }

    @Test("F-09 sunroof, roof-shade, door and boot phrasings are refused")
    func refused() {
        for said in ["把天窗打开", "天窗开一下", "开一下天幕", "天窗关上吧", "把车门打开", "开一下后备箱"] {
            #expect(ToolCallGuards.sunroofOnWindowTool(openAll, ctx(said)) == .unsupportedBodyPart, "\(said)")
        }
    }

    @Test("F-09 an ordinary window request goes through")
    func ordinary() {
        for said in ["把 我 这 边 的 窗 户 开 一 点 。", "天 窗 和 车 窗 都 打 开", "把我这边的窗户开一点", "打开车窗",
                     "天窗和车窗都打开", "车窗开一半，天窗不用"] {
            #expect(ToolCallGuards.sunroofOnWindowTool(openAll, ctx(said)) == nil, "\(said)")
        }
    }

    @Test("F-09 a sunroof said in the previous turn and other tools are untouched")
    func staleAndOthers() {
        #expect(ToolCallGuards.sunroofOnWindowTool(openAll, ctx("帮我把天窗打开。", epoch: 1, onset: 2)) == nil)
        let seat = call("control_seat", ["action": "set_height", "value": 3])
        #expect(ToolCallGuards.sunroofOnWindowTool(seat, ctx("天窗打开，座椅调高")) == nil)
        #expect(ToolCallGuards.sunroofOnWindowTool(openAll, GuardContext()) == nil)
    }
}

@Suite("T-017 F-09 guard: driverSideWindow")
struct DriverWindowGuardTests {
    let adjustAll = call("control_window", ["action": "adjust", "window": "all", "value": 20])

    @Test("F-09 my side narrows to the driver window, live spaced line too")
    func narrows() {
        for said in ["把我这边的窗户开一点", "我这边开一点窗", "我这侧的窗户", "我这一侧窗户开一点", "我这半边的窗户"] {
            #expect(ToolCallGuards.driverSideWindow(adjustAll, ctx(said)) == "driver", "\(said)")
        }
        #expect(ToolCallGuards.driverSideWindow(adjustAll, ctx(TranscriptText.normalize("把 我 这 边 的 窗 户 开 一 点 。"))) == "driver")
        let noWindow = call("control_window", ["action": "adjust", "value": 20])
        #expect(ToolCallGuards.driverSideWindow(noWindow, ctx("我这边的窗户开一点")) == "driver")
    }

    @Test("F-09 a second named window, or none, is not narrowed")
    func notNarrowed() {
        for said in ["打开车窗", "我这边和副驾都开一点", "把后排窗户开一点", "四个窗户都开一点", "把全部车窗打开",
                     "我这边和后面的都开一点", "我这边跟右边的窗户开一点", "我这边和别的窗户都开一点"] {
            #expect(ToolCallGuards.driverSideWindow(adjustAll, ctx(said)) == nil, "\(said)")
        }
    }

    @Test("F-09 a window the model named is never rewritten")
    func named() {
        #expect(ToolCallGuards.driverSideWindow(call("control_window", ["action": "close", "window": "rear"]),
                                                ctx("我这边冷，把后面的窗户关上")) == nil)
        #expect(ToolCallGuards.driverSideWindow(call("control_window", ["action": "open", "window": "passenger"]),
                                                ctx("我这边太晒，开右边的窗")) == nil)
        for window in ["driver", "front_left"] {
            let named = call("control_window", ["action": "adjust", "window": .string(window), "value": 20])
            #expect(ToolCallGuards.driverSideWindow(named, ctx("把我这边的窗户开一点")) == nil)
        }
    }

    @Test("F-09 previous-turn words and other tools are untouched; the dispatcher rewrites")
    func staleAndDispatcher() {
        #expect(ToolCallGuards.driverSideWindow(adjustAll, ctx("把我这边的窗户开一点", epoch: 1, onset: 2)) == nil)
        #expect(ToolCallGuards.driverSideWindow(call("control_seat", ["action": "adjust_height", "value": 1]),
                                                ctx("把我这边的窗户开一点")) == nil)
        #expect(ToolCallGuards.driverSideWindow(adjustAll, GuardContext()) == nil)
        var d = ToolDispatcher()
        guard case .execute(let run) = d.decide(adjustAll, context: ctx("把我这边的窗户开一点")) else {
            Issue.record("refused"); return
        }
        #expect(run.arguments["window"] == "driver")
    }
}

@Suite("T-017 F-09 guard: nearbyQuestionWhileNavigating")
struct NearbyGuardTests {
    let gas = call("navigate_to", ["destination": "附近的加油站"])

    @Test("F-09 a nearby question mid-drive does not replace the route")
    func refused() {
        for said in ["附近有加油站吗？", "附 近 有 加 油 站 吗", "路上有加油站吗", "前面有没有服务区", "最近的加油站在哪"] {
            #expect(ToolCallGuards.nearbyQuestionWhileNavigating(gas, ctx(said, navigating: true))
                    == .nearbyQuestionWhileNavigating, "\(said)")
        }
    }

    @Test("F-09 asking to go there still navigates; with no route it is a nearby search")
    func allowed() {
        for said in ["带我去附近的加油站", "导航去最近的加油站", "附近有加油站吗？那就去最近的那个", "换个目的地，去附近的加油站"] {
            #expect(ToolCallGuards.nearbyQuestionWhileNavigating(gas, ctx(said, navigating: true)) == nil, "\(said)")
        }
        #expect(ToolCallGuards.nearbyQuestionWhileNavigating(gas, ctx("附近有加油站吗？")) == nil)
        #expect(ToolCallGuards.nearbyQuestionWhileNavigating(gas, ctx("附近有加油站吗？", epoch: 1, onset: 2, navigating: true)) == nil)
        #expect(ToolCallGuards.nearbyQuestionWhileNavigating(call("control_climate", ["action": "on"]),
                                                             ctx("附近有加油站吗", navigating: true)) == nil)
    }

    @Test("F-09 through the dispatcher the route is kept and the advice names along_route")
    func dispatcher() {
        var d = ToolDispatcher()
        guard case .refuse(let r) = d.decide(gas, context: ctx("附近有加油站吗？", navigating: true)) else {
            Issue.record("navigated"); return
        }
        #expect(r.code == .nearbyQuestionWhileNavigating)
        #expect(r.advice!.contains("along_route"))
    }
}

@Suite("T-017 F-09 guard: vagueExitWhileNavigating")
struct VagueExitGuardTests {
    let exit = call("exit_navigation_mode")

    func refusedWhileDriving(_ said: String) -> Bool {
        ToolCallGuards.vagueExitWhileNavigating(exit, ctx(said, guidance: true)) == .vagueExitWhileNavigating
    }

    @Test("F-09 a vague never-mind mid-drive does not end the drive")
    func vague() {
        for said in ["算了", "不用了", "没事了", "没事", "不去了", "好了", "算 了"] { #expect(refusedWhileDriving(said), "\(said)") }
    }

    @Test("F-09 explicit, structural and near-form end requests end the drive")
    func explicit() {
        let ends = ["结束导航", "退出导航", "停止导航", "取消导航", "关闭导航", "不导航了", "导航结束", "别导航了", "算了，结束导航吧",
                    "不要导航了", "不用导航了", "导航关了", "把导航关了", "导航关掉", "结束路线", "不去了，结束导航", "别导航", "导航不要了", "关了导航",
                    "把导航取消", "把导航取消了", "导航取消", "导航关闭", "把导航关闭", "不需要导航了", "不用导航", "不要导航",
                    "关导航", "终止导航", "取消路线", "停止路线", "把导航停了", "导航可以结束了", "别再导航了", "不想导航了",
                    "算了不用导航", "導航結束",
                    "要不结束导航吧", "要不关了导航吧", "导航不用了", "先把导航關掉",
                    "结束当前导航", "退出当前导航", "结束本次导航", "取消这个导航", "停止这次导航", "结束当前的导航", "结束一下导航",
                    "导航不要了吧", "导航不用了吧"]
        for said in ends { #expect(!refusedWhileDriving(said), "\(said)") }
    }

    @Test("F-09 continuing, a negated end, or the guidance voice is not an end request")
    func notEnd() {
        for said in ["继续导航", "导航继续", "不要结束导航"] {
            #expect(!ToolCallGuards.isExplicitEnd(said), "\(said)")
            #expect(refusedWhileDriving(said), "\(said)")
        }
        for said in ["导航别说话了", "导航太吵了别说了", "关掉导航声音", "把导航声音关小一点", "关闭导航播报", "导航不要走高速",
                     "我不想走这条路线", "关窗，然后导航去公司", "关空调导航到公司", "不用管导航", "关这个空调导航去公司"] {
            #expect(refusedWhileDriving(said), "\(said)")
        }
    }

    @Test("F-09 a list open, a pre-guidance search, stale words and other tools are untouched")
    func untouched() {
        #expect(ToolCallGuards.vagueExitWhileNavigating(exit, ctx("算了", guidance: true, listOpen: true)) == nil)
        #expect(ToolCallGuards.vagueExitWhileNavigating(exit, ctx("算了，不去了", navigating: true, guidance: false)) == nil)
        #expect(ToolCallGuards.vagueExitWhileNavigating(exit, ctx("算了")) == nil)
        #expect(ToolCallGuards.vagueExitWhileNavigating(call("control_climate", ["action": "on"]), ctx("算了", guidance: true)) == nil)
        #expect(ToolCallGuards.vagueExitWhileNavigating(exit, ctx("算了", epoch: 1, onset: 2, guidance: true)) == nil)
    }
}

@Suite("T-017 F-09 guard: speechOutputNotRequested")
struct SpeechOutputGuardTests {
    func speech(_ mode: String) -> ToolCall { call("set_speech_output", ["mode": .string(mode)]) }

    @Test("F-09 the mumble and lines not about talking are refused")
    func refused() {
        for mode in ["silent", "spoken"] {
            #expect(ToolCallGuards.speechOutputNotRequested(speech(mode), ctx("嗯……那个……")) == .speechOutputNotRequested)
        }
        for said in ["嗯", "那个", "等一下", "音乐先关了吧", "你好，你叫什么名字", "还要开多久", "好了，谢谢", "说话能不能嗲一点",
                     "你可以再说一遍吗", "你可以说慢一点吗", "说话能不能慢一点"] {
            #expect(ToolCallGuards.speechOutputNotRequested(speech("silent"), ctx(said)) == .speechOutputNotRequested, "\(said)")
        }
    }

    @Test("F-09 stop, resume and every ListeningIntent shut-up phrase are allowed")
    func allowed() {
        let stop = ["闭嘴", "小诺闭嘴", "别说了", "不要说了", "你先别说了", "别说话", "停止说话", "停止說話", "安静", "安静点",
                    "别出声", "别吵了", "少说两句", "别讲了", "shut up", "stop talking",
                    "住嘴", "住口", "闭上嘴", "别啰嗦了", "别唠叨了", "别念了", "不许说话", "不准说话", "噓"]
        let resume = ["继续说", "接着说", "可以说话了", "你可以说了", "繼續說", "说话吧"]
        let shutUp = ["shut up", "be quiet", "keep quiet", "keep silent", "stay silent", "stop talking", "silence", "quiet",
                      "闭嘴", "小诺闭嘴", "安静", "安静点", "安静一点", "保持安静", "别说话", "不要说话", "别出声", "不要出声",
                      "别吵", "别吵了", "少说话", "别说了", "不要说了", "别讲了", "不要讲了"]
        for said in stop + resume + shutUp {
            #expect(ToolCallGuards.speechOutputNotRequested(speech("silent"), ctx(said)) == nil, "\(said)")
        }
    }

    @Test("F-09 before the transcript the call is not judged; other tools untouched; advice claims nothing")
    func untouched() {
        #expect(ToolCallGuards.speechOutputNotRequested(speech("silent"), ctx("嗯", epoch: 1, onset: 2)) == nil)
        #expect(ToolCallGuards.speechOutputNotRequested(speech("silent"), GuardContext()) == nil)
        for other in [call("control_climate", ["action": "on"]), call("end_conversation"), call("set_speaking_style", ["style": "gentle"])] {
            #expect(ToolCallGuards.speechOutputNotRequested(other, ctx("嗯……那个……")) == nil)
        }
        let advice = ToolFailureAdvice.forCode(.speechOutputNotRequested)!
        #expect(advice.contains("没有执行"))
        #expect(!advice.replacingOccurrences(of: "也不要说你会安静或已经安静", with: "").contains("已经安静了"))
    }
}

@Suite("T-017 F-09 guard: repeatedInTurn and unsupportedMedia")
struct RepeatAndMediaGuardTests {
    @Test("F-09 an identical repeat-sensitive call twice in one turn is dropped")
    func repeats() {
        let firsts = [call("place_call", ["contact": "张三"]), call("navigate_to", ["destination": "中交汇通"]),
                      call("open_app", ["app": "maps"]), call("save_place", ["slot": "home", "address": "中交汇通"]),
                      call("exit_navigation_mode"),
                      call("control_climate", ["action": "adjust_temperature", "value": -2]),
                      call("control_music", ["action": "play"]), call("query_live_info", ["kind": "weather", "where": "北京"])]
        for first in firsts {
            var d = ToolDispatcher()
            let c = ctx("说点什么")
            if case .refuse(let r) = d.decide(first, context: c), r.code == .duplicateInTurn { Issue.record("\(first.name)") }
            guard case .refuse(let r) = d.decide(first, context: c) else { Issue.record("\(first.name) ran twice"); continue }
            #expect(r.code == .duplicateInTurn, "\(first.name)")
        }
    }

    @Test("F-09 different arguments, a new turn, a pure read or no speech onset are not repeats")
    func notRepeats() {
        var d = ToolDispatcher()
        let c = ctx("说点什么")
        #expect(d.decide(call("navigate_to", ["destination": "A"]), context: c) != .refuse(ToolDispatcher.failure(.duplicateInTurn)))
        guard case .execute = d.decide(call("navigate_to", ["destination": "B"]), context: c) else { Issue.record("B"); return }
        guard case .execute = d.decide(call("navigate_to", ["destination": "A"]), context: ctx("再导航去A", epoch: 2)) else {
            Issue.record("new turn"); return
        }
        let look = call("describe_camera_view", ["question": "前面是什么"])
        for _ in 0..<2 { guard case .execute = d.decide(look, context: c) else { Issue.record("look"); return } }
        var fresh = ToolDispatcher()
        let dial = call("place_call", ["contact": "张三"])
        for _ in 0..<2 { guard case .execute = fresh.decide(dial, context: GuardContext()) else { Issue.record("no onset"); return } }
    }

    @Test("F-09 a named song on control_music play is MEDIA_LIBRARY_UNSUPPORTED")
    func media() {
        let play = call("control_music", ["action": "play"])
        #expect(ToolCallGuards.unsupportedMedia(play, ctx("放周杰伦的歌")) == .mediaLibraryUnsupported)
        #expect(ToolCallGuards.unsupportedMedia(play, ctx("放首歌")) == nil)
        #expect(ToolCallGuards.unsupportedMedia(play, ctx("来点音乐吧")) == nil)
        #expect(ToolCallGuards.unsupportedMedia(call("control_music", ["action": "stop"]), ctx("放周杰伦的歌")) == nil)
    }
}

@Suite("T-017 F-09 saved places, power advice, validation, catalog")
struct DispatchTests {
    @Test("F-09 回家 with no home saved is HOME_NOT_SET; 家乐福 is a search")
    func savedPlaces() {
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "回家"]), GuardContext()) == .homeNotSet)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "带我去公司吧"]), GuardContext()) == .workNotSet)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "回家"]), GuardContext(savedPlaces: [.home])) == nil)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "家乐福"]), GuardContext()) == nil)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "公司附近的星巴克"]), GuardContext()) == nil)
    }

    @Test("F-09 a temperature change with the climate off carries the CLIMATE_OFF advice")
    func powerAdvice() {
        let adjust = call("control_climate", ["action": "adjust_temperature", "value": -1])
        let off = ToolResult.success(["power_on": false, "temperature_c": 22])
        #expect(ToolDispatcher().finish(adjust, off).advice == ToolFailureAdvice.climateOff)
        #expect(ToolDispatcher().finish(adjust, .success(["power_on": true])).advice == nil)
        #expect(ToolDispatcher().finish(call("control_climate", ["action": "get_state"]), off).advice == nil)
    }

    @Test("F-09 validation codes from each domain")
    func validation() {
        let cases: [(ToolCall, ToolErrorCode?)] = [
            (call("open_app", ["app": "x"]), .appNotAllowed),
            (call("navigate_to", ["destination": .string(String(repeating: "a", count: 4097))]), .argumentsTooLarge),
            (call("no_such_tool"), .unknownTool),
            (call("navigate_to", ["destination": "  "]), .blankDestination),
            (call("navigate_to", ["destination": 1]), .invalidFieldType),
            (call("choose_navigation_option", ["index": 11]), .invalidIndex),
            (call("choose_navigation_option", ["index": "2"]), nil),
            (call("choose_navigation_option", ["index": 2, "name": "x"]), .invalidFields),
            (call("choose_navigation_option", ["preference": "cheapest"]), .preferenceNotAllowed),
            (call("control_climate", ["action": "set_temperature"]), .missingValue),
            (call("control_climate", ["action": "set_temperature", "value": "22"]), .invalidFieldType),
            (call("control_climate", ["action": "set_temperature", "value": 22]), nil),
            (call("control_climate", ["action": "on"]), .actionNotAllowed),
            (call("control_window", ["action": "adjust", "value": 0]), .invalidValue),
            (call("control_window", ["action": "open", "window": "sunroof"]), .invalidFieldValue),
            (call("control_seat", ["action": "adjust_height"]), .missingValue),
            (call("play_music", ["exclude_title": "x"]), .missingValue),
            (call("play_music", ["mood": "提神"]), nil),
            (call("query_live_info", ["kind": "news"]), .invalidKind),
            (call("query_live_info", ["kind": "weather", "where": .string(String(repeating: "北", count: 21))]), .invalidArgument),
            (call("set_speaking_style", ["style": "bossy"]), .styleNotAllowed),
            (call("exit_navigation_mode", ["x": 1]), .invalidFields),
            (ToolCall(id: CallID("c")!, name: "open_app", arguments: "maps"), .malformedJson),
        ]
        for (c, code) in cases { #expect(ToolCatalog.validate(c) == code, "\(c.name) \(c.arguments)") }
        #expect(ToolErrorCode.validationError.rawValue == "_validation_error")
    }

    @Test("F-09 the catalog has the 17 Android tools in domain order")
    func catalog() {
        #expect(ToolCatalog.specs.map(\.name) == [
            "navigate_to", "choose_navigation_option", "exit_navigation_mode", "save_place", "open_app",
            "control_music", "play_music", "control_climate", "control_window", "control_seat", "run_scenario",
            "describe_camera_view", "place_call", "query_live_info", "end_conversation", "set_speech_output",
            "set_speaking_style"])
        #expect(ToolCatalog.spec("describe_camera_view")?.repeatSensitive == false)
        #expect(ToolCatalog.spec("set_speaking_style")?.repeatSensitive == true)
        #expect(ToolCatalog.spec("play_music")?.declaration.parametersJSONSchema["required"] == nil)
        #expect(ToolCatalog.spec("control_window")?.declaration.parametersJSONSchema["properties"]?["window"]?["enum"]
                == .array(ToolCatalog.windows.map(JSONValue.string)))
    }

    @Test("F-09 every refusal code a guard returns has advice; NotYetExecutor is honest")
    func advice() async {
        for code: ToolErrorCode in [.unsupportedBodyPart, .nearbyQuestionWhileNavigating, .vagueExitWhileNavigating,
                                    .speechOutputNotRequested, .ambiguousReferent, .duplicateInTurn, .mediaLibraryUnsupported,
                                    .homeNotSet, .workNotSet, .notAvailableOnIOSYet] {
            #expect(ToolFailureAdvice.forCode(code)?.isEmpty == false, "\(code)")
        }
        let r = await NotYetExecutor().execute(call("describe_camera_view", ["question": "x"]))
        #expect(!r.ok && r.code == .notAvailableOnIOSYet && r.advice != nil)
        let wire = ToolDispatcher.failure(.duplicateInTurn).wireObject(tool: "navigate_to")
        #expect(wire["ok"] == false && wire["error"] == "DUPLICATE_IN_TURN" && wire["tool"] == "navigate_to")
    }

    @Test("F-09 ambiguous referent refuses with the options joined by 还是")
    func referent() {
        var d = ToolDispatcher()
        let seat = call("control_seat", ["action": "adjust_height", "value": -1])
        guard case .refuse(let r) = d.decide(seat, context: ctx("再低一点。"), clarify: { _ in ["座椅", "温度"] }) else {
            Issue.record("ran"); return
        }
        #expect(r.code == .ambiguousReferent && r.data["options"] == "座椅还是温度")
        let set = call("control_seat", ["action": "set_height", "value": 3])
        guard case .execute = d.decide(set, context: ctx("再低一点。"), clarify: { _ in ["座椅", "温度"] }) else {
            Issue.record("absolute held"); return
        }
    }
}
