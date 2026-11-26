import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §68 (T-040zu): Macau and Hong Kong places are looked up without 高德's city limit; she does not invent why a
/// place is missing.

private let abroadLimit = AmapWebFailure(.quota, info: "USER_ABROAD_DAILY_QUERY_OVER_LIMIT")
private let qps = AmapWebFailure(.quota, info: AmapWebFailure.qpsInfo)

private func sight(_ name: String, city: String) -> JSONValue { ["name": .string(name), "city": .string(city), "minutes": 60] }

@Suite("T-040zu F-15b §68 Macau and Hong Kong places without 高德's city limit; no invented reason")
struct TripMacauLookupTests {
    @Test("T-040zu F-15b §68 row 319: lookup 大三巴牌坊, city 澳门: no region/city limit; a 4404 result is dropped, an 82 result kept")
    func row319() async {
        let search = AmapLookupSearch(["大三巴牌坊": [mapPlace("大三巴牌坊(珠海店)", 22.27, city: "珠海市", adcode: "440402"),
                                                 mapPlace("大三巴牌坊", 22.19, city: "澳门", adcode: "820002")]])
        let s = sight("大三巴牌坊", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        #expect(r.ok, "\(r)")
        let requests = search.requests.withLock { $0 }
        #expect(!requests.isEmpty && requests.allSatisfy { $0.city == nil && !$0.cityLimit }, "\(requests)")
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.adcode == "820002")
        // Hong Kong the same way; only 81/82 results are kept.
        #expect(SpecialRegion.isSpecial("香港特别行政区") && SpecialRegion.isSpecial("澳门") && !SpecialRegion.isSpecial("珠海"))
        #expect(SpecialRegion.keeps(mapPlace("x", 22.3, city: "香港", adcode: "810001")))
        #expect(!SpecialRegion.keeps(mapPlace("x", 22.3, city: "珠海", adcode: "440402")))
    }

    @Test("T-040zu F-15b §68 row 320: lookup 珠海渔女, city 珠海: request as today (region 珠海, city limit)")
    func row320() async {
        let search = AmapLookupSearch(["珠海|珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市", adcode: "440402")]])
        let s = sight("珠海渔女", city: "珠海")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall())
        let requests = search.requests.withLock { $0 }
        #expect(!requests.isEmpty && requests.allSatisfy { $0.city == "珠海" && $0.cityLimit }, "\(requests)")
        #expect(await rig.planner.currentPlan.allStops.first?.stop.placed == true)
    }

    @Test("T-040zu F-15b §68 row 321: 10 lookups in one plan: never more than 3 start in one window; a QPS answer is tried once more after the wait")
    func row321() async {
        var table: [String: [Place]] = [:]
        let names = (0..<10).map { "景点\($0)" }
        for (i, n) in names.enumerated() { table[n] = [mapPlace(n, 22.2 + Double(i) / 100, city: "珠海市")] }
        let search = AmapLookupSearch(table, errors: ["景点0": [qps]])
        var tuning = TripTuning()
        tuning.paceWindow = .milliseconds(300)
        tuning.qpsRetry = .milliseconds(200)
        tuning.parallelLookups = 4
        let day = names.map { sight($0, city: "珠海") }
        let rig = await LookupRig([plannerAnswer([day]), plannerAnswer([day])], search: search, tuning: tuning)
        let r = await rig.run(planCall())
        #expect(r.ok, "\(r)")
        let at = search.requests.withLock { $0 }.map(\.at).sorted()
        #expect(at.count == 11, "\(at.count)")
        // Each start is at least one window after the start three before it (a little slack for the scheduler).
        for i in 3..<at.count { #expect(at[i] - at[i - 3] >= .milliseconds(280), "\(i): \(at[i] - at[i - 3])") }
        let first = search.requests.withLock { $0 }.filter { $0.keywords == "景点0" }.map(\.at)
        #expect(first.count == 2 && first[1] - first[0] >= .milliseconds(200), "\(first)")
        #expect(await rig.planner.currentPlan.allStops.allSatisfy(\.stop.placed))
    }

    @Test("T-040zu F-15b §68 row 322: 高德 answers USER_ABROAD_DAILY_QUERY_OVER_LIMIT: not_placed reason=map_limit; record info=")
    func row322() async {
        let search = AmapLookupSearch([:], errors: ["大三巴牌坊": [abroadLimit]])
        let s = sight("大三巴牌坊", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        guard case .array(let missed)? = r.data["not_placed"] else { Issue.record("no not_placed: \(r)"); return }
        #expect(missed.first?["reason"] == "map_limit" && missed.first?["name"] == "大三巴牌坊")
        #expect(rig.line("trip lookup name=") == ["trip lookup name=大三巴牌坊 city=澳门 info=USER_ABROAD_DAILY_QUERY_OVER_LIMIT"])
        // A daily limit is not tried again.
        #expect(search.asked == ["大三巴牌坊"])
        // A name 高德 answered with nothing kept is not_found, info=none.
        let empty = AmapLookupSearch(["大三巴牌坊": [mapPlace("大三巴牌坊(珠海店)", 22.27, city: "珠海市", adcode: "440402")]])
        let rig2 = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: empty)
        let r2 = await rig2.run(planCall("周日去澳门", city: "澳门"))
        guard case .array(let missed2)? = r2.data["not_placed"] else { Issue.record("no not_placed: \(r2)"); return }
        #expect(missed2.first?["reason"] == "not_found")
        // F-15b §70 item 2 (T-040zw): the line also says what the filter dropped.
        #expect(rig2.line("trip lookup name=") == ["trip lookup name=大三巴牌坊 city=澳门 info=none dropped=1 kept_by=none"])
    }

    @Test("T-040zu F-15b §68 row 323: a result with not_placed: must_not has invent; next names only the reason")
    func row323() async {
        let search = AmapLookupSearch(["珠海|珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市")]], errors: ["大三巴牌坊": [abroadLimit]])
        let day = [sight("珠海渔女", city: "珠海"), sight("大三巴牌坊", city: "澳门")]
        let rig = await LookupRig([plannerAnswer([day]), plannerAnswer([day])], search: search)
        let r = await rig.run(planCall())
        #expect(r.data["must_not"] == .array(["invent"]), "\(r)")
        let next = r.data["next"]?.stringValue ?? ""
        #expect(next.hasPrefix(TripPlannerShape.savedNext))
        #expect(next.contains("地图今天查不了这些地方") && !next.contains("地图没找到这些地方"), "\(next)")
        #expect(!next.contains("工具") && !next.contains("支持"))
        // No not_placed: the result is as before.
        let ok = await LookupRig([plannerAnswer([[day[0]]]), plannerAnswer([[day[0]]])], search: search)
        let r2 = await ok.run(planCall())
        #expect(r2.data["must_not"] == nil && r2.data["next"]?.stringValue == TripPlannerShape.savedNext)
    }
}
