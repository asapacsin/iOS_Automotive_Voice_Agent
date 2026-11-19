import Foundation
import NovaKit
import NovaNav
import NovaPorts
import NovaTools
import Testing

/// F-09b §13 item 8: phrases that script her line (the gate is T-031n's; the unit check is here from stage 1).
let scriptPhrases = ["只说一句：", "只说这一句", "请如实说：", "请用户换个说法", "换个说法"]

/// F-09b §13 item 9 (unit): `facts`, `may` and `must_not` present; `next` quotes no sentence and has no script phrase.
func expectReplyShape(_ result: ToolResult, _ label: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(result.advice == nil, "\(label)", sourceLocation: sourceLocation)
    #expect(isObject(result.data["facts"]), "\(label)", sourceLocation: sourceLocation)
    #expect(isArray(result.data["may"]) && isArray(result.data["must_not"]), "\(label)",
            sourceLocation: sourceLocation)
    let next = result.data["next"]?.stringValue ?? ""
    #expect(next.hasPrefix("用自己的话简短地说。"), "\(label)", sourceLocation: sourceLocation)
    #expect(!next.contains("「") && !next.contains("」"), "\(label)", sourceLocation: sourceLocation)
    for phrase in scriptPhrases { #expect(!next.contains(phrase), "\(label) \(phrase)", sourceLocation: sourceLocation) }
}

func replyValues(_ value: JSONValue?) -> [String] {
    if case .array(let items)? = value { return items.compactMap(\.stringValue) }
    return []
}
func isObject(_ value: JSONValue?) -> Bool { if case .object? = value { true } else { false } }
func isArray(_ value: JSONValue?) -> Bool { if case .array? = value { true } else { false } }

@Suite("T-031l F-09b §13 stage 1: she says it in her own words; code gives the facts and the rules")
struct ToolReplyStage1Tests {
    @Test("F-09b §13 row 1: ToolReply.failure(.noCandidates) has facts, may, must_not and a next built from them")
    func shape() throws {
        let reply = ToolReply.failure(.noCandidates, facts: ["what": "咖啡店", "found": 0],
                                      may: [.searchWider, .similarPlace], mustNot: [.askRephrase, .invent])
        let result = reply.result
        #expect(!result.ok && result.code == .noCandidates)
        expectReplyShape(result)
        #expect(replyValues(result.data["may"]) == ["search_wider", "similar_place"])
        #expect(replyValues(result.data["must_not"]) == ["ask_rephrase", "invent"])
        #expect(reply.next == "用自己的话简短地说。可以：可以自己再搜远一点；可以搜相近的地方（比如服务区、休息区）。"
            + "不要：不要让司机重新措辞再说；不要说 facts 里没有的地点、数字或时间。")
        // The JSON the model reads carries the four keys and no advice.
        let json = try JSONValue.canonicalEncoder().encode(JSONValue.object(result.data))
        let text = String(decoding: json, as: UTF8.self)
        for key in ["\"facts\"", "\"may\"", "\"must_not\"", "\"next\""] { #expect(text.contains(key), "\(key)") }
        #expect(!text.contains("\"advice\""))
        // Every gloss is free of quotes and script phrases (later stages add cases; this keeps them honest).
        for gloss in ReplyMay.allCases.map(\.gloss) + ReplyMustNot.allCases.map(\.gloss) {
            #expect(!gloss.contains("「") && !scriptPhrases.contains { gloss.contains($0) }, "\(gloss)")
        }
        // Duplicates are dropped, order kept; a success has no code.
        let success = ToolReply.success(facts: ["name": "瑞幸咖啡"], mustNot: [.readList, .readList]).result
        #expect(success.ok && success.code == nil && replyValues(success.data["must_not"]) == ["read_list"])
        #expect(success.data["next"]?.stringValue == "用自己的话简短地说。不要：不要念屏幕上的列表。")
    }

    @Test("F-09b §13 row 3: navigate_to 附近的咖啡店, none within 3 km, far result 5.2 km: facts, offer_nearest first")
    func noCandidatesFacts() {
        let result = LookupReply.noCandidates(what: "咖啡店", around: .phone, radiusKm: 3,
                                              nearestOutside: .init(name: "瑞幸咖啡（拱北口岸店）", distanceKm: 5.24))
        expectReplyShape(result)
        #expect(result.code == .noCandidates)
        let facts = result.data["facts"]
        #expect(facts?["what"] == "咖啡店" && facts?["around"] == "phone" && facts?["found"] == .int(0))
        #expect(facts?["radius_km"] == .double(3))
        #expect(facts?["nearest_outside"]?["name"] == "瑞幸咖啡（拱北口岸店）")
        #expect(facts?["nearest_outside"]?["distance_km"] == .double(5.2))
        #expect(replyValues(result.data["may"]) == ["offer_nearest", "search_wider", "similar_place"])
        #expect(replyValues(result.data["must_not"]) == ["ask_rephrase", "invent"])

        // Without a far result there is nothing to offer.
        let none = LookupReply.noCandidates(what: "咖啡店", around: .demo, radiusKm: 50)
        #expect(replyValues(none.data["may"]) == ["search_wider", "similar_place"])
        #expect(none.data["facts"]?["nearest_outside"] == nil && none.data["facts"]?["around"] == "demo")
    }

    @Test("F-09b §13 row 3: navigate_to with nothing found returns the facts (phone fix, and no fix → city)")
    func navigateNoCandidates() async {
        for (location, around, radius) in [(FixedLocation() as any LocationProvider, "phone", Double?(50)),
                                           (NoLocation(), "city", Double?.none)] {
            let nav = NavigationController(search: FixedSearch(places: []), engine: ScriptedNaviEngine(routes: []),
                                           location: location, clock: ManualClock())
            await nav.start()
            let result = await nav.execute(tool("navigate_to", ["destination": "附近的咖啡店"]))
            #expect(result.code == .noCandidates)
            expectReplyShape(result, around)
            #expect(result.data["facts"]?["what"] == "咖啡店" && result.data["facts"]?["around"] == .string(around))
            let radiusKm: Double? = if case .double(let km)? = result.data["facts"]?["radius_km"] { km } else { nil }
            #expect(radiusKm == radius && result.data["facts"]?["found"] == .int(0), "\(around)")
            #expect(replyValues(result.data["must_not"]) == ["ask_rephrase", "invent"])
            #expect(await nav.current.phase == .idle)
        }
    }

    @Test("F-09b §13 row 4: stage 1 failures return ToolReply: key, network, quota, no location, save_place, details")
    func stage1Results_keyNetworkQuotaLocationSaveDetails() async {
        let noKey = NavigationController(search: FixedSearch(places: [], error: .keyMissing),
                                         engine: ScriptedNaviEngine(routes: []), location: NoLocation(), clock: ManualClock())
        await noKey.start()
        let key = await noKey.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(key.code == .amapWebKeyMissing && key.data["facts"]?["cause"] == "key_missing")
        expectReplyShape(key, "key")
        #expect(replyValues(key.data["may"]) == ["name_setting"])

        let down = NavigationController(search: FixedSearch(places: [], error: .timeout),
                                        engine: ScriptedNaviEngine(routes: []), location: NoLocation(), clock: ManualClock())
        await down.start()
        let network = await down.execute(tool("navigate_to", ["destination": "珠海站"]))
        #expect(network.code == .liveInfoUnavailable && network.data["facts"]?["cause"] == "network")
        expectReplyShape(network, "network")
        #expect(replyValues(network.data["may"]) == ["try_later"])

        let saved = SavedPlaces(settings: MemorySettingsStore())
        let notFound = await SavePlaceExecutor(places: saved, search: FixedSearch(places: []))
            .execute(tool("save_place", ["slot": "home", "address": "横琴某某路"]))
        #expect(notFound.code == .noCandidates && notFound.data["facts"]?["saved"] == .bool(false))
        expectReplyShape(notFound, "save_place")
        #expect(replyValues(notFound.data["must_not"]).contains("claim_done")
            && replyValues(notFound.data["must_not"]).contains("ask_rephrase"))

        // Quota, no location and details: the builders the LiveInfo and details places use.
        let quota = LookupReply.failed(LookupReply.code(for: LookupReply.cause(of: AmapWebError.quota)), what: "天气",
                                       cause: LookupReply.cause(of: AmapWebError.quota))
        #expect(quota.code == .liveInfoQuota && quota.data["facts"]?["cause"] == "quota")
        expectReplyShape(quota, "quota")
        let noFix = await LiveInfoExecutor(navigation: noKey, geocoder: FakeGeocoder(), location: NoLocation())
            .execute(tool("query_live_info", ["kind": "current_location"]))
        #expect(!noFix.ok && noFix.data["facts"] != nil)
        expectReplyShape(noFix, "no location")
        #expect(replyValues(noFix.data["must_not"]).contains("guess_location"))
        let details = LookupReply.notFound(.noResults, what: "details", facts: ["place": "珠海站"])
        #expect(details.data["facts"]?["place"] == "珠海站" && details.data["facts"]?["found"] == .int(0))
        expectReplyShape(details, "details")
        #expect(LookupReply.Cause.notConfigured.rawValue == "not_configured")
    }

    @Test("F-09b §13 row 4: no stage 1 place keeps its advice sentence (item 3 places at 8a895e9)")
    func noStage1Sentences() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/NovaNav")
        let files = ["Flow/NavigationController.swift", "Flow/SavedPlaces.swift", "LiveInfo/LiveInfoExecutor.swift",
                     "Trip/TripPlanner.swift"]
        let source = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }.joined()
        let old = [
            "没有找到这个地点。请如实说没找到，请用户换个说法。", "地点查询失败了，请如实说没查到", "高德的查询服务还没有配置好，请如实说明没有查到。",
            "路线规划失败了。请如实说没有算出路线。", "拿不到当前路线的形状", "沿途没有找到", "的详情。请如实说明，不要编造营业时间。",
            "地址没有保存。请如实说明。", "地址查询失败了，没有保存", "没有找到这个地址，没有保存", "现在拿不到位置。请如实说明",
            "目的地的位置没有查到。请如实说明。", "天气查询还没有配置。", "所以查不到地址",
            "现在还没定位到。请如实说还没定位到", "地址没有查到。请如实说明，不要猜位置。", "密钥无效，所以没有查到",
            "今天的查询次数用完了", "请如实说明没有做成清单。", "清单里的地点都没有找到",
            "请如实说明没有改行程。", "请如实说明没有改清单。", "地址没有保存成功。请如实说没有保存",
        ]
        for sentence in old { #expect(!source.contains(sentence), "\(sentence)") }
    }
}
