import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// A search that answers per city: `local` for a city-limited search, `country` for a nationwide one.
final class CitySearch: PlaceSearch {
    struct Query: Hashable { let keywords: String; let city: String?; let cityLimit: Bool }
    let queries = Mutex<[Query]>([])
    let local: [Place]
    let country: [Place]
    let error: AmapWebError?

    init(local: [Place] = [], country: [Place] = [], error: AmapWebError? = nil) {
        self.local = local
        self.country = country
        self.error = error
    }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        try await text(keywords, city: city, cityLimit: false)
    }

    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        queries.withLock { $0.append(Query(keywords: keywords, city: city, cityLimit: cityLimit)) }
        if let error { throw error }
        return cityLimit ? local : country
    }

    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

/// F-09b §16 item 8 (T-031za), row 12: `show_place(name)` finds the place, the App fills and shows the card, and it is
/// done only when shown. F-09b §18 (T-031zc), rows 1–5: `show_place(name, city)` looks up exactly that name in that
/// city; one exact match opens the card, anything else is `PLACE_UNSURE` back to her.
@Suite("F-09b §16 §18 show_place")
struct ShowPlaceToolTests {
    static func place(_ id: String, _ name: String, address: String? = nil, city: String? = nil,
                      district: String? = nil) -> Place {
        Place(id: id, name: name, address: address,
              coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02), distanceMeters: 1_500,
              city: city, district: district)
    }

    let list = [place("B1", "华发商都(新香洲店)"), place("B2", "华发商都(横琴店)"), place("B3", "富华里")]

    final class Presented: Sendable {
        let cards = Mutex<[TripCard]>([])
    }

    final class Lines: Sendable {
        let all = Mutex<[String]>([])
        var first: String? { all.withLock { $0.first } }
        var last: String? { all.withLock { $0.last } }
    }

    func run(_ name: String, city: String = "珠海", screen: [Place] = [], search: CitySearch = CitySearch(),
             carCity: String? = "440400", shown: Bool = true, intro: String? = "大型综合商场", lines: Lines = Lines(),
             presented: Presented = Presented()) async -> ToolResult {
        let tool = ShowPlaceTool(onScreen: { screen }, search: search, cityCode: { carCity },
                                 present: { card in
                                     presented.cards.withLock { $0.append(card) }
                                     return ShowPlaceTool.Shown(shown: shown, intro: intro, address: "香洲区")
                                 },
                                 clock: ManualClock(), onLine: { line in lines.all.withLock { $0.append(line) } })
        return await tool.execute(ToolCall(id: CallID("c1")!, name: "show_place",
                                           arguments: ["name": .string(name), "city": .string(city)]))
    }

    static func found(_ result: ToolResult) -> [String] {
        guard case .array(let items)? = result.data["facts"]?["found"] else { return [] }
        return items.compactMap { $0["name"]?.stringValue }
    }

    @Test("T-031za: a name on screen opens that place without a search; facts carry the intro; log has no name")
    func onScreen() async {
        let search = CitySearch(local: [Self.place("X", "别的")])
        let presented = Presented()
        let lines = Lines()
        let result = await run("富华里", screen: list, search: search, lines: lines, presented: presented)
        #expect(result.ok)
        #expect(presented.cards.withLock { $0.map(\.placeID) } == ["B3"])
        #expect(result.data["facts"]?["shown"] == .bool(true))
        #expect(result.data["facts"]?["name"] == .string("富华里"))
        #expect(result.data["facts"]?["intro"] == .string("大型综合商场"))
        #expect(result.data["facts"]?["address"] == .string("香洲区"))
        #expect(search.queries.withLock { $0.isEmpty })
        let line = lines.first ?? ""
        #expect(line.hasPrefix("show place ok=yes via=screen sure=yes found=0 ms="))
        #expect(!line.contains("富华里"))
        // Several on screen match: the first is used (screen match unchanged by §18).
        let first = await run("华发商都", screen: list, presented: presented)
        #expect(first.ok && first.data["facts"]?["name"] == .string("华发商都(新香洲店)"))
        let longer = await run("富华里商场", screen: list, search: search)
        #expect(longer.ok && longer.data["facts"]?["name"] == .string("富华里"))
        #expect(search.queries.withLock { $0.isEmpty })
    }

    @Test("T-031zc row 1: one exact name in her city opens its card; facts name and city; searched in her city only")
    func sureInCity() async {
        let search = CitySearch(local: [Self.place("Q1", "清远新世界酒店", city: "清远市", district: "清城区"),
                                        Self.place("Q2", "清远新世界酒店停车场", city: "清远市")],
                                country: [Self.place("Z", "新世界门业(梅花豪庭店)", city: "珠海市")])
        let lines = Lines()
        let presented = Presented()
        let result = await run("清远新世界酒店", city: "清远", search: search, lines: lines, presented: presented)
        #expect(result.ok)
        #expect(presented.cards.withLock { $0.map(\.placeID) } == ["Q1"])
        #expect(result.data["facts"]?["name"] == .string("清远新世界酒店"))
        #expect(result.data["facts"]?["city"] == .string("清远市"))
        #expect(search.queries.withLock { $0 } == [.init(keywords: "清远新世界酒店", city: "清远", cityLimit: true)])
        let line = lines.first ?? ""
        #expect(line.hasPrefix("show place ok=yes via=city sure=yes found=2 ms="))
        #expect(!line.contains("清远"))
        // A trailing bracket branch, spaces and case are ignored.
        let branch = CitySearch(local: [Self.place("S", "Starbucks 星巴克(大元路店)", city: "清远市")])
        let b = await run("starbucks星巴克", city: "清远", search: branch)
        #expect(b.ok && b.data["facts"]?["name"] == .string("Starbucks 星巴克(大元路店)"))
    }

    @Test("T-031zc row 2: only another name in the city: no card, PLACE_UNSURE with asked, found and the next")
    func unsureOtherName() async {
        let search = CitySearch(local: [Self.place("C", "清远清泉湾生态旅游度假区", address: "佛冈县", city: "清远市",
                                                   district: "佛冈县")],
                                country: [Self.place("Y", "悦天下生态度假区", city: "云浮市")])
        let presented = Presented()
        let lines = Lines()
        let result = await run("清远悦天下生态度假区", city: "清远", search: search, lines: lines, presented: presented)
        #expect(!result.ok && result.code == .placeUnsure)
        #expect(presented.cards.withLock { $0.isEmpty })
        #expect(search.queries.withLock { $0.map(\.cityLimit) } == [true])
        #expect(result.data["facts"]?["asked"]?["name"] == .string("清远悦天下生态度假区"))
        #expect(result.data["facts"]?["asked"]?["city"] == .string("清远"))
        #expect(Self.found(result) == ["清远清泉湾生态旅游度假区"])
        if case .array(let items)? = result.data["facts"]?["found"] {
            #expect(items.first?["city"] == .string("清远市"))
            #expect(items.first?["district"] == .string("佛冈县"))
            #expect(items.first?["address"] == .string("佛冈县"))
        }
        #expect(result.data["next"] == .string(ShowPlaceTool.unsureNext))
        #expect(ShowPlaceTool.unsureNext.contains("web_search") && ShowPlaceTool.unsureNext.contains("不要说功能异常"))
        #expect(result.data["must_not"] == .array([.string("claim_done")]))
        #expect(lines.first?.hasPrefix("show place ok=no via=city sure=no found=1 ms=") == true)
        // Nothing found: also unsure, found empty; the name in another city is not sure either.
        let none = await run("清远悦天下生态度假区", city: "清远", search: CitySearch())
        #expect(none.code == .placeUnsure && Self.found(none).isEmpty)
        let otherCity = await run("悦天下生态度假区", city: "清远",
                                  search: CitySearch(local: [Self.place("Y", "悦天下生态度假区", city: "云浮市")]))
        #expect(otherCity.code == .placeUnsure && Self.found(otherCity) == ["悦天下生态度假区"])
        // found holds at most five.
        let many = CitySearch(local: (1...7).map { Self.place("M\($0)", "度假村\($0)", city: "清远市") })
        let capped = await run("温泉", city: "清远", search: many)
        #expect(Self.found(capped).count == 5)
    }

    @Test("T-031zc row 3: two results with the asked name in the city: no card, both in found")
    func unsureTwoSame() async {
        let search = CitySearch(local: [Self.place("A", "星巴克(大元路店)", city: "清远市"),
                                        Self.place("B", "星巴克(万达店)", city: "清远市")])
        let presented = Presented()
        let result = await run("星巴克", city: "清远", search: search, presented: presented)
        #expect(!result.ok && result.code == .placeUnsure)
        #expect(Self.found(result) == ["星巴克(大元路店)", "星巴克(万达店)"])
        #expect(presented.cards.withLock { $0.isEmpty })
    }

    @Test("T-031zc row 3 then item 4: called again with a branch name from found, that branch alone is sure (full-width brackets too)")
    func againWithBranch() async {
        let places = [Self.place("A", "星巴克(大元路店)", city: "清远市"), Self.place("B", "星巴克(万达店)", city: "清远市")]
        let presented = Presented()
        let result = await run("星巴克（大元路店）", city: "清远", search: CitySearch(local: places), presented: presented)
        #expect(result.ok, "\(result)")
        #expect(presented.cards.withLock { $0.map(\.placeID) } == ["A"])
        #expect(ShowPlaceTool.sureMatch(places, name: "星巴克(东城店)", city: "清远") == nil)
    }

    @Test("T-031zc row 4: city empty searches the car's city only; sure or unsure as rows 1-3; no fix is honest")
    func nearCar() async {
        let one = CitySearch(local: [Self.place("S", "星巴克(拱北店)", city: "珠海市")],
                             country: [Self.place("X", "星巴克", city: "北京市")])
        let lines = Lines()
        let result = await run("星巴克", city: "", search: one, lines: lines)
        #expect(result.ok && result.data["facts"]?["city"] == .string("珠海市"))
        #expect(one.queries.withLock { $0 } == [.init(keywords: "星巴克", city: "440400", cityLimit: true)])
        #expect(lines.first?.hasPrefix("show place ok=yes via=near sure=yes found=1 ms=") == true)
        let two = CitySearch(local: [Self.place("A", "星巴克(拱北店)", city: "珠海市"),
                                     Self.place("B", "星巴克(香洲店)", city: "珠海市")])
        let unsure = await run("星巴克", city: "", search: two)
        #expect(unsure.code == .placeUnsure && Self.found(unsure).count == 2)
        #expect(two.queries.withLock { $0.map(\.cityLimit) } == [true])
        let noFix = CitySearch(country: [Self.place("X", "星巴克")])
        let none = await run("星巴克", city: "", search: noFix, carCity: nil)
        #expect(!none.ok && none.code == .noLocation)
        #expect(noFix.queries.withLock { $0.isEmpty })
    }

    @Test("T-031za T-031zc: a failed search is honest (search_failed cause) with the same next; nothing opens")
    func searchFailed() async {
        let presented = Presented()
        let lines = Lines()
        let failed = await run("珠海渔女", search: CitySearch(error: .keyMissing), lines: lines, presented: presented)
        #expect(!failed.ok && failed.code == .amapWebKeyMissing)
        #expect(failed.data["facts"]?["cause"] == .string("key_missing"))
        #expect(failed.data["next"] == .string(ShowPlaceTool.unsureNext))
        #expect(presented.cards.withLock { $0.isEmpty })
        #expect(lines.first?.hasPrefix("show place ok=no via=city sure=no found=0 ms=") == true)
    }

    @Test("T-031za: not shown is not done (PLACE_NOT_SHOWN, shown=false); no intro gives intro null")
    func notShown() async {
        let lines = Lines()
        let result = await run("富华里", screen: list, shown: false, lines: lines)
        #expect(lines.first?.hasPrefix("show place ok=no via=screen sure=yes found=0 ms=") == true)
        #expect(lines.first?.contains("富华里") == false)
        #expect(!result.ok && result.code == .placeNotShown)
        #expect(result.data["facts"]?["shown"] == .bool(false))
        let noIntro = await run("富华里", screen: list, intro: nil)
        #expect(noIntro.ok && noIntro.data["facts"]?["intro"] == .null)
    }

    @Test("T-031za T-031zc row 5: declared with name and city; the description has the city sentence")
    func declaration() {
        #expect(ToolCatalog.spec("show_place") != nil)
        #expect(AsyncTool(name: "show_place") == .showPlace)
        let spec = ToolCatalog.spec("show_place")
        let schema = spec?.declaration.parametersJSONSchema
        if case .object(let properties)? = schema?["properties"] {
            #expect(properties.keys.sorted() == ["city", "name"])
        } else { Issue.record("no properties") }
        #expect(schema?["required"] == .array([.string("name"), .string("city")]))
        #expect(spec?.declaration.description.contains("city 填这个地方所在的城市；不确定在哪个城市时先用 web_search 查。") == true)
        #expect(ToolCatalog.validate("show_place", ["name": "珠海渔女", "city": "珠海"]) == nil)
        #expect(ToolCatalog.validate("show_place", ["name": "星巴克", "city": ""]) == nil)
        #expect(ToolCatalog.validate("show_place", [:]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["index": 1]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["name": "  ", "city": "珠海"]) == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_place", ["name": "珠海渔女", "city": 3]) == .invalidFieldType)
        #expect(ToolCatalog.validate("show_place", ["name": .string(String(repeating: "长", count: 41))]) == .invalidFieldValue)
    }
}
