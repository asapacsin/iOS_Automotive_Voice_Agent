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
/// done only when shown.
@Suite("F-09b §16 show_place")
struct ShowPlaceToolTests {
    static func place(_ id: String, _ name: String, address: String? = nil) -> Place {
        Place(id: id, name: name, address: address,
              coordinate: GeoCoordinate(latitude: 22.2, longitude: 113.5, datum: .gcj02), distanceMeters: 1_500)
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

    func run(_ name: String, screen: [Place] = [], search: CitySearch = CitySearch(), city: String? = "440400",
             shown: Bool = true, intro: String? = "大型综合商场", lines: Lines = Lines(),
             presented: Presented = Presented()) async -> ToolResult {
        let tool = ShowPlaceTool(onScreen: { screen }, search: search, cityCode: { city },
                                 present: { card in
                                     presented.cards.withLock { $0.append(card) }
                                     return ShowPlaceTool.Shown(shown: shown, intro: intro, address: "香洲区")
                                 },
                                 clock: ManualClock(), onLine: { line in lines.all.withLock { $0.append(line) } })
        return await tool.execute(ToolCall(id: CallID("c1")!, name: "show_place", arguments: ["name": .string(name)]))
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
        #expect(line.hasPrefix("show place ok=yes via=screen intro=yes ms="))
        #expect(!line.contains("富华里"))
        // Several on screen match: the first is used.
        let first = await run("华发商都", screen: list, presented: presented)
        #expect(first.ok && first.data["facts"]?["name"] == .string("华发商都(新香洲店)"))
        // The asked name is longer than the name on screen: still that place, no search.
        let longer = await run("富华里商场", screen: list, search: search)
        #expect(longer.ok && longer.data["facts"]?["name"] == .string("富华里"))
        #expect(search.queries.withLock { $0.isEmpty })
    }

    @Test("T-031za: not on screen searches the car's city first, nationwide only when the city finds nothing")
    func searched() async {
        let search = CitySearch(local: [Self.place("Z1", "珠海渔女")], country: [Self.place("Q", "别处渔女")])
        let lines = Lines()
        let local = await run("珠海渔女", search: search, lines: lines)
        #expect(local.ok && local.data["facts"]?["name"] == .string("珠海渔女"))
        #expect(search.queries.withLock { $0 } == [.init(keywords: "珠海渔女", city: "440400", cityLimit: true)])
        #expect(lines.first?.contains("via=city") == true)

        let wide = CitySearch(local: [], country: [Self.place("Q", "故宫")])
        let country = await run("故宫", search: wide, lines: lines)
        #expect(country.ok && country.data["facts"]?["name"] == .string("故宫"))
        #expect(wide.queries.withLock { $0.map(\.cityLimit) } == [true, false])
        #expect(lines.last?.contains("via=country") == true)

        let noCity = CitySearch(country: [Self.place("Q", "故宫")])
        _ = await run("故宫", search: noCity, city: nil)
        #expect(noCity.queries.withLock { $0 } == [.init(keywords: "故宫", city: nil, cityLimit: false)])
    }

    @Test("T-031za: nothing found is NO_CANDIDATES; a failed search is honest; nothing opens")
    func notFound() async {
        let presented = Presented()
        let lines = Lines()
        let none = await run("不存在的地方", lines: lines, presented: presented)
        #expect(lines.first?.hasPrefix("show place ok=no via=none intro=no ms=") == true)
        #expect(lines.first?.contains("不存在") == false)
        #expect(!none.ok && none.code == .noCandidates)
        let failed = await run("珠海渔女", search: CitySearch(error: .keyMissing), presented: presented)
        #expect(!failed.ok && failed.code == .amapWebKeyMissing)
        #expect(presented.cards.withLock { $0.isEmpty })
    }

    @Test("T-031za: not shown is not done (PLACE_NOT_SHOWN, shown=false); no intro gives intro null")
    func notShown() async {
        let lines = Lines()
        let result = await run("富华里", screen: list, shown: false, lines: lines)
        #expect(lines.first?.hasPrefix("show place ok=no via=screen intro=yes ms=") == true)
        #expect(lines.first?.contains("富华里") == false)
        #expect(!result.ok && result.code == .placeNotShown)
        #expect(result.data["facts"]?["shown"] == .bool(false))
        let noIntro = await run("富华里", screen: list, intro: nil)
        #expect(noIntro.ok && noIntro.data["facts"]?["intro"] == .null)
    }

    @Test("T-031za: declared NON_BLOCKING with one name of 1-40 characters")
    func declaration() {
        #expect(ToolCatalog.spec("show_place") != nil)
        #expect(AsyncTool(name: "show_place") == .showPlace)
        let schema = ToolCatalog.spec("show_place")?.declaration.parametersJSONSchema
        if case .object(let properties)? = schema?["properties"] { #expect(properties.keys.sorted() == ["name"]) } else { Issue.record("no properties") }
        #expect(schema?["required"] == .array([.string("name")]))
        #expect(ToolCatalog.validate("show_place", ["name": "珠海渔女"]) == nil)
        #expect(ToolCatalog.validate("show_place", [:]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["index": 1]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["name": "  "]) == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_place", ["name": .string(String(repeating: "长", count: 41))]) == .invalidFieldValue)
    }
}
