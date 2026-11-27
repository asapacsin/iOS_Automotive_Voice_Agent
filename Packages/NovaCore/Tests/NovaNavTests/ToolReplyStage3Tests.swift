import Foundation
import NovaKit
@testable import NovaNav
import NovaPorts
import Testing

@Suite("T-031n F-09b §13 stage 3: success confirmations carry what changed")
struct ToolReplyStage3Tests {
    private func expectSuccess(_ result: ToolResult, _ label: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(result.ok, "\(label)", sourceLocation: sourceLocation)
        expectReplyShape(result, label, sourceLocation: sourceLocation)
    }

    @Test("F-09b §13 row 6 / row 12 (unit): 把第二个去掉 on three trips: what changed as facts, read_list, no sentence")
    func removeSecond() async {
        for trip3 in [["古文化街", "五大道", "天津之眼"], ["瓷房子", "意式风情区", "鼓楼"], ["南开大学", "水上公园", "西开教堂"]] {
            let rig = await TripRig()
            _ = await rig.run(planCall(["places": names(trip3)]))
            let order = await rig.order()
            // §52 (T-040zb): the stop is left out of the plan written back.
            var keep = order
            keep.remove(at: 1)
            let r = await rig.run(await planCall(rig, [keep]))
            // §61 item 3a: the review next replaces the generic 「用自己的话简短地说。」 shape for a saved trip write.
            #expect(r.ok && r.data["saved"] == true, "remove")
            #expect(r.data["facts"]?["removed"] == names([order[1]]) && r.data["facts"]?["count"] == .int(Int64(order.count - 1)))
            #expect(r.data["facts"]?["changed"] == "set")
            #expect(replyValues(r.data["must_not"]) == ["read_list", "read_distances"])
            // F-15b §61 item 3a (T-040zn): a saved write's next is the review text; the words are hers.
            #expect(r.data["next"]?.stringValue == TripPlanner.reviewNext)
        }
    }

    @Test("F-09b §13 row 6: navigate_to with a list on screen, guidance start and save_place carry what changed")
    func navigationSuccesses() async {
        let stations = [place("珠海站", 3_000), place("珠海北站", 9_000)]
        let nav = NavigationController(search: FixedSearch(places: stations),
                                       engine: ScriptedNaviEngine(routes: [route(1, meters: 12_300, seconds: 1_500)]),
                                       location: NoLocation(), clock: ManualClock())
        await nav.start()
        let listed = await nav.execute(tool("navigate_to", ["destination": "珠海站"]))
        expectSuccess(listed, "listed")
        #expect(listed.data["facts"]?["listed"] == .int(2) && replyValues(listed.data["must_not"]) == ["read_list"])
        #expect(replyValues(listed.data["may"]) == ["ask_pick"])
        let started = await nav.execute(tool("choose_navigation_option", ["index": .int(1)]))
        expectSuccess(started, "started")
        #expect(started.data["facts"]?["destination"] == "珠海站" && started.data["facts"]?["duration_min"] == .int(25))
        #expect(replyValues(started.data["must_not"]) == ["read_routes"])

        let saved = await SavePlaceExecutor(places: SavedPlaces(settings: MemorySettingsStore()),
                                            search: FixedSearch(places: [place("横琴口岸", 0)]))
            .execute(tool("save_place", ["slot": "home", "address": "横琴口岸"]))
        expectSuccess(saved, "save_place")
        #expect(saved.data["facts"]?["as"] == "家" && saved.data["facts"]?["command"] == "回家")
    }

    @Test("F-09b §13 row 6: the weather and time next texts are built by ToolReply")
    func builtNexts() {
        for next in [ForecastWeather.next, ForecastWeather.nowNext, ForecastWeather.hoursNext] {
            #expect(next.hasPrefix("用自己的话简短地说。") && scriptPhrases.contains { next.contains($0) } == false)
        }
        #expect(NavigationController.cardsHiddenNext.hasPrefix("用自己的话简短地说。"))
    }
}
