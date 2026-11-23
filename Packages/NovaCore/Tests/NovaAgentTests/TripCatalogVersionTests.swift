import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

@Suite("T-040zh F-15b §55 items 11–13 the trip catalog and the agent version")
struct TripCatalogVersionTests {
    @Test("T-040zh F-15b row 234: no make_trip_list, no edit_trip_list; set_trip_plan has the item 12 text, city and hotel near; agent 6.0.0")
    func row234() {
        let declared = ToolCatalog.specs.map(\.name)
        #expect(!declared.contains("make_trip_list") && !declared.contains("edit_trip_list"))
        #expect(ToolCatalog.spec("make_trip_list") == nil && ToolCatalog.spec("edit_trip_list") == nil)
        #expect(ToolCatalog.validate(ToolCall(id: CallID("x")!, name: "make_trip_list", arguments: ["places": ["外滩"]])) == .unknownTool)
        #expect(TripPlanner.tools == ["set_trip_plan", "trip_next", "trip_plans"])
        #expect(AsyncTool(name: "make_trip_list") == nil && AsyncTool(name: "edit_trip_list") == nil)
        let text = ToolCatalog.setTripPlanDescription
        #expect(text == "做行程或改行程，都用这个：把整份行程（每天的地点）写好后整份传回。新行程：每个地点写 name，加 city（城市，跨城市就写省或地区）。改行程：把结果里的行程照着改，已有的地点保留 id（其他字段可以照抄），新地点写 name。每天的景点你自己安排好：一般每天3到4个，一天6到8小时，整天的地方（比如迪士尼）单独一天。role：start 出发点（司机说了才写，第一天第一个）、end 终点（最后一天最后一个）、hotel 酒店（每晚一个：当天最后一个、第二天第一个；司机说了住哪就写那个，说住在某处附近就写 {role:\"hotel\",near:\"某处\"}）、sight 景点。去掉的地点不写。例：「规划广州两天」→city=\"广州\"，days=[[{name:\"广州塔\"},{name:\"陈家祠\"},{name:\"沙面\"},{name:\"珠江夜游\"},{role:\"hotel\",near:\"北京路\"}],[{role:\"hotel\",near:\"北京路\"},{name:\"长隆野生动物世界\",minutes:480},{role:\"hotel\",near:\"北京路\"}]]。结果是 trip_needs_fix 时先不要说话，按 issues 改好再传。结果稍后回来。新行程：" + ToolCatalog.tripWorkingLine + "改行程：" + ToolCatalog.tripEditWorkingLine)
        let schema = ToolCatalog.spec("set_trip_plan")?.declaration.parametersJSONSchema
        #expect(schema?["properties"]?["city"]?["type"] == "string")
        #expect(schema?["properties"]?["days"]?["items"]?["items"]?["properties"]?["near"]?["type"] == "string")
        #expect(schema?["properties"]?["day_count"] == nil)
        // trip_next's text is unchanged (§55 item 12).
        #expect(ToolCatalog.tripNextDescription.hasPrefix("行程按站导航："))
        // §56 item 5 (T-040zi) changed the 改行程 sentence (row 243); the version moved on with it.
        #expect(AgentSetup.version.hasPrefix("6."))
    }
}
