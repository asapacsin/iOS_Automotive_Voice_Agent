import Foundation
import NovaKit
@testable import NovaNav
import NovaPorts
import Testing

/// F-09b §13 item 4 (unit, row 5): not done / not yet always carries `claim_started` and `claim_done`.
func expectNotDone(_ result: ToolResult, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!result.ok, "\(label)", sourceLocation: sourceLocation)
    expectReplyShape(result, label, sourceLocation: sourceLocation)
    let rules = replyValues(result.data["must_not"])
    #expect(rules.contains("claim_started") && rules.contains("claim_done"), "\(label)", sourceLocation: sourceLocation)
}

/// F-09b §13 item 4 (unit, row 5): choosing carries what is on screen and `ask_pick`; nothing starts.
func expectChoosing(_ result: ToolResult, _ label: String, onScreen: Int, names: [String]? = nil,
                    sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!result.ok, "\(label)", sourceLocation: sourceLocation)
    expectReplyShape(result, label, sourceLocation: sourceLocation)
    #expect(result.data["facts"]?["on_screen"] == .int(Int64(onScreen)), "\(label)", sourceLocation: sourceLocation)
    if let names {
        #expect(result.data["facts"]?["names"] == .array(names.map(JSONValue.string)), "\(label)",
                sourceLocation: sourceLocation)
    }
    #expect(replyValues(result.data["may"]).contains("ask_pick"), "\(label)", sourceLocation: sourceLocation)
    #expect(replyValues(result.data["must_not"]).contains("claim_started"), "\(label)", sourceLocation: sourceLocation)
}

@Suite("T-031m F-09b §13 stage 2: not done / not yet, and choosing")
struct ToolReplyStage2Tests {
    let stations = [place("珠海站", 3_000), place("珠海北站", 9_000), place("珠海站公交站", 2_500)]
    let routes = [route(1, meters: 12_300, seconds: 1_500, toll: 5), route(2, meters: 10_100, seconds: 1_800)]

    private func listed() async -> NavigationController {
        let nav = NavigationController(search: FixedSearch(places: stations), engine: ScriptedNaviEngine(routes: routes),
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        _ = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        return nav
    }

    @Test("F-09b §13 row 5 / row 11 (unit): 导航去珠海站 then 第五个 with 3 on screen: count, names, ask_pick; nothing starts")
    func fifthOfThree() async {
        let nav = await listed()
        let fifth = await nav.execute(tool("choose_navigation_option", ["index": .int(5)]))
        #expect(fifth.code == .outOfRange)
        expectChoosing(fifth, "fifth", onScreen: 3, names: ["珠海站", "珠海北站", "珠海站公交站"])
        #expect(await nav.current.phase == .awaitingDestinationSelection)
        #expect(await nav.current.navigating == false)
    }

    @Test("F-09b §13 row 5: choosing results (name, ambiguous, preference, details target) carry on-screen facts")
    func choosingResults() async {
        let nav = await listed()
        let none = await nav.execute(tool("choose_navigation_option", ["name": "拱北"]))
        #expect(none.code == .noMatch && none.data["facts"]?["asked_name"] == "拱北")
        expectChoosing(none, "noMatch", onScreen: 3, names: ["珠海站", "珠海北站", "珠海站公交站"])
        let two = await nav.execute(tool("choose_navigation_option", ["name": "珠海站"]))
        #expect(two.code == .ambiguous)
        expectChoosing(two, "ambiguous", onScreen: 3)
        let pref = await nav.execute(tool("choose_navigation_option", ["preference": "fastest"]))
        #expect(pref.code == .preferenceNotForDestinations)
        expectChoosing(pref, "preference", onScreen: 3)
        let details = await nav.placeDetails(target: .int(9))
        #expect(details.code == .outOfRange)
        expectChoosing(details, "details", onScreen: 3)
        let noTarget = await nav.placeDetails(target: nil)
        #expect(noTarget.code == .invalidArgument)
        expectChoosing(noTarget, "details target", onScreen: 3)
    }

    @Test("F-09b §13 row 5: place_details target=destination with no destination and places on screen is a choice")
    func detailsNoDestination() async {
        let nav = await listed()
        let r = await nav.placeDetails(target: .string("destination"))
        #expect(r.code == .noDestination && r.data["facts"]?["destination"] == .null)
        expectChoosing(r, "no destination", onScreen: 3, names: ["珠海站", "珠海北站", "珠海站公交站"])
    }

    @Test("F-09b §13 row 5: an along-route category not allowed: the 4 categories as facts and ask_pick")
    func alongRouteCategory() async {
        let nav = await listed()
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        _ = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(await nav.current.navigating)
        let r = await nav.alongRoute(category: "咖啡")
        #expect(r.code == .invalidArgument)
        #expect(r.data["facts"]?["allowed"] == .array(["加油站", "充电站", "服务区", "厕所"].map(JSONValue.string)))
        #expect(replyValues(r.data["may"]).contains("ask_pick"))
    }

    @Test("F-09b §13 row 5: not-done results carry claim_started and claim_done")
    func notDoneResults() async {
        let idle = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                        location: NoLocation(), clock: ManualClock())
        await idle.start()
        let nothing = await idle.execute(tool("choose_navigation_option", ["index": .int(1)]))
        #expect(nothing.code == .noOptionsOnScreen && nothing.data["facts"]?["on_screen"] == .int(0))
        expectNotDone(nothing, "no list")
        let status = await idle.routeStatus()
        #expect(status.code == .notNavigating && status.data["facts"]?["navigating"] == .bool(false))
        expectNotDone(status, "route status")
        let along = await idle.alongRoute(category: "fuel")
        #expect(along.code == .notNavigating && replyValues(along.data["may"]) == ["offer_nearby"])
        expectNotDone(along, "along route")
        let hidden = TripPlanner.tripHiddenResult
        #expect(hidden.code == .tripHidden && hidden.data["facts"]?["show_command"] == "打开我的行程")
        expectNotDone(hidden, "trip hidden")
        let denied = LiveInfoExecutor.permissionDenied
        #expect(denied.data["facts"]?["cause"] == "permission_denied")
        expectNotDone(denied, "permission")
        #expect(replyValues(denied.data["must_not"]).contains("guess_location"))
    }

    @Test("F-09b §13 row 5: save_place without a slot is a choice; without an address nothing is saved")
    func savePlaceChoices() async {
        let executor = SavePlaceExecutor(places: SavedPlaces(settings: MemorySettingsStore()), search: FixedSearch(places: []))
        let slot = await executor.execute(tool("save_place", ["slot": "school", "address": "横琴"]))
        #expect(slot.code == .invalidFieldValue && slot.data["facts"]?["saved"] == .bool(false))
        expectReplyShape(slot, "slot")
        #expect(replyValues(slot.data["may"]) == ["ask_pick"])
        let empty = await executor.execute(tool("save_place", ["slot": "home", "address": " "]))
        #expect(empty.code == .invalidFieldValue && replyValues(empty.data["must_not"]).contains("claim_done"))
        expectReplyShape(empty, "address")
    }

    @Test("F-09b §13 row 5: no stage 2 place keeps its advice sentence (item 4 places at 8a895e9)")
    func noStage2Sentences() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = ["NovaNav/Flow/NavigationController.swift", "NovaNav/Flow/SavedPlaces.swift",
                     "NovaNav/LiveInfo/LiveInfoExecutor.swift", "NovaNav/Trip/TripPlanner.swift",
                     "NovaTools/AppSurface/OpenAppExecutor.swift", "NovaTools/Media/MusicToolHandler.swift",
                     "NovaTools/Vision/CameraQuestionHandler.swift"]  // the ToolCatalog table is stage 4 (T-031o)
        let source = try files.map { try String(contentsOf: sources.appendingPathComponent($0), encoding: .utf8) }.joined()
        let old = [
            "只问一句是不是去", "请如实说正在启动", "请如实说还在计算", "请如实说：请在设置里打开定位", "请如实说：还没有定位",
            "没有换成功，继续按原路线导航。请如实说明。", "导航没有启动成功。请如实说明", "请如实说正在换", "这次只算出一条路线",
            "现在没有在导航。请如实说明。", "不能查沿途。请如实说明", "沿途只能查加油站、充电站、服务区或厕所。请如实说明。",
            "请用户说是目的地还是第几个。", "屏幕上没有候选列表。请如实说明。",
            "候选列表已经过期。请如实说明", "屏幕上没有这个名字。请如实说明", "有多个候选都符合这个名字。请用户说第几个。",
            "不知道距离。请用户说第几个。", "不能按路线偏好选", "请用户说第几条路线。", "屏幕上只有\\(count)项",
            "页面没有切换过去。请如实说", "内置音乐没有放起来。请如实说", "请用户说想听什么。", "看图功能还没有配置。请如实说明",
            "请在设置里允许。请如实说明", "摄像头现在用不了。请如实说明", "看图服务的密钥无效。请如实说明",
            "请用一句话如实说定位权限没有打开", "问用户是家还是公司", "请用户再说一遍地址", "现在一共\\(list.count)个地点。请如实说明",
            "现在行程有\\(plan.dayCount)天。请如实说明", "没有改名。请如实说明", "要用行程请说「打开行程」",
        ]
        for sentence in old { #expect(source.contains(sentence) == false, "\(sentence)") }
    }
}
