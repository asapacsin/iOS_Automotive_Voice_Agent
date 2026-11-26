import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §70 (T-040zw): Macau and Hong Kong results are kept by their province name, since 高德 v3 gives them no adcode.

private func sarPlace(_ name: String, _ lat: Double, province: String?, city: String?, adcode: String? = nil) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: 113.54, datum: .gcj02),
          distanceMeters: nil, city: city, district: nil, adcode: adcode, province: province)
}

private func sight(_ name: String, city: String) -> JSONValue { ["name": .string(name), "city": .string(city), "minutes": 60] }

@Suite("T-040zw F-15b §70 Macau and Hong Kong results kept by province when 高德 v3 gives no adcode")
struct TripSarProvinceTests {
    @Test("T-040zw F-15b §70 row 329: v3 大三巴牌坊 with no adcode, pname 澳门特别行政区, and a 珠海 440402 result: Macau kept (kept_by=province), 珠海 dropped")
    func row329() async {
        let macau = sarPlace("大三巴牌坊", 22.197, province: "澳门特别行政区", city: "澳门特别行政区")
        let zhuhai = sarPlace("大三巴牌坊(珠海店)", 22.27, province: "广东省", city: "珠海市", adcode: "440402")
        #expect(SpecialRegion.keptBy(macau)?.by == "province" && SpecialRegion.keptBy(macau)?.region == .macau)
        #expect(SpecialRegion.keptBy(zhuhai) == nil)
        // cityname alone (no pname) also keeps it.
        #expect(SpecialRegion.keptBy(sarPlace("x", 22.2, province: nil, city: "香港特别行政区"))?.region == .hongKong)
        let search = AmapLookupSearch(["大三巴牌坊": [zhuhai, macau]])
        let s = sight("大三巴牌坊", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        #expect(r.ok, "\(r)")
        let stop = await rig.planner.currentPlan.allStops.first?.stop
        #expect(stop?.placed == true && stop?.place.name == "大三巴牌坊" && stop?.place.province == "澳门特别行政区", "\(String(describing: stop))")
        #expect(rig.line("trip lookup name=").isEmpty)
    }

    @Test("T-040zw F-15b §70 row 330: lookup city 澳门, only a 香港特别行政区 result: not kept; nomatch; record dropped=1 kept_by=none")
    func row330() async {
        let hk = sarPlace("海洋公园", 22.24, province: "香港特别行政区", city: "香港特别行政区")
        #expect(!SpecialRegion.macau.keeps(hk) && SpecialRegion.hongKong.keeps(hk))
        let search = AmapLookupSearch(["海洋公园": [hk]])
        let s = sight("海洋公园", city: "澳门")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        let r = await rig.run(planCall("周日去澳门", city: "澳门"))
        guard case .array(let missed)? = r.data["not_placed"] else { Issue.record("no not_placed: \(r)"); return }
        #expect(missed.first?["reason"] == "not_found")
        #expect(rig.line("trip lookup name=") == ["trip lookup name=海洋公园 city=澳门 info=none dropped=1 kept_by=none"])
        // Answered and filtered: not tried again, except F-15b §71 item 2b's one retry with 「澳门」 in front (T-040zx).
        #expect(search.asked == ["海洋公园", "澳门海洋公园"])
    }

    @Test("T-040zw F-15b §70 row 331: a v5-style result with adcode 820002 is kept (kept_by=adcode), as §68")
    func row331() async {
        let v5 = sarPlace("大三巴牌坊", 22.197, province: nil, city: "澳门", adcode: "820002")
        #expect(SpecialRegion.keptBy(v5)?.by == "adcode" && SpecialRegion.macau.keeps(v5))
        // An adcode outside the SARs is not rescued by a province name.
        #expect(!SpecialRegion.keeps(sarPlace("y", 22.2, province: "澳门特别行政区", city: nil, adcode: "440402")))
        let search = AmapLookupSearch(["大三巴牌坊": [v5]])
        let s = sight("大三巴牌坊", city: "澳门特别行政区")
        let rig = await LookupRig([plannerAnswer([[s]]), plannerAnswer([[s]])], search: search)
        _ = await rig.run(planCall("周日去澳门", city: "澳门"))
        #expect(await rig.planner.currentPlan.allStops.first?.stop.place.adcode == "820002")
    }
}
