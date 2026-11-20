import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-09b §16 item 8 (T-031za): `show_place` resolves a place on screen or a named one and is done only when shown.
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

    func run(_ arguments: JSONValue, screen: [Place], search: CountingSearch = CountingSearch(places: []),
             shown: Bool = true, intro: String? = "大型综合商场", lines: Mutex<[String]>? = nil,
             presented: Presented = Presented()) async -> ToolResult {
        let tool = ShowPlaceTool(onScreen: { screen }, search: search,
                                 present: { card in
                                     presented.cards.withLock { $0.append(card) }
                                     return ShowPlaceTool.Shown(shown: shown, intro: intro, address: "香洲区")
                                 },
                                 clock: ManualClock(), onLine: { line in lines?.withLock { $0.append(line) } })
        return await tool.execute(ToolCall(id: CallID("c1")!, name: "show_place", arguments: arguments))
    }

    @Test("T-031za: index picks the place with that number on screen; facts carry the intro")
    func byIndex() async {
        let presented = Presented()
        let lines = Mutex<[String]>([])
        let result = await run(["index": 3], screen: list, lines: lines, presented: presented)
        #expect(result.ok)
        #expect(presented.cards.withLock { $0.map(\.placeID) } == ["B3"])
        #expect(result.data["facts"]?["shown"] == .bool(true))
        #expect(result.data["facts"]?["name"] == .string("富华里"))
        #expect(result.data["facts"]?["intro"] == .string("大型综合商场"))
        #expect(result.data["facts"]?["address"] == .string("香洲区"))
        // I-8: the line has codes only, no name.
        let line = lines.withLock { $0 }.first ?? ""
        #expect(line.hasPrefix("show place ok=yes via=index intro=yes ms="))
        #expect(!line.contains("富华里"))
    }

    @Test("T-031za: index outside the places on screen is OUT_OF_RANGE and nothing opens")
    func outOfRange() async {
        let presented = Presented()
        let result = await run(["index": 4], screen: list, presented: presented)
        #expect(!result.ok && result.code == .outOfRange)
        #expect(result.data["facts"]?["on_screen"] == .int(3))
        #expect(presented.cards.withLock { $0.isEmpty })
        let empty = await run(["index": 1], screen: [], presented: presented)
        #expect(!empty.ok && empty.code == .outOfRange)
    }

    @Test("T-031za: a name on screen is used without a search; two matches are AMBIGUOUS")
    func byName() async {
        let search = CountingSearch(places: [Self.place("X", "别的")])
        let one = await run(["name": "富华里"], screen: list, search: search)
        #expect(one.ok && one.data["facts"]?["name"] == .string("富华里"))
        let two = await run(["name": "华发商都"], screen: list, search: search)
        #expect(!two.ok && two.code == .ambiguous)
        #expect(two.data["facts"]?["names"] == .array([.string("华发商都(新香洲店)"), .string("华发商都(横琴店)")]))
        #expect(search.queries.withLock { $0.isEmpty })
    }

    @Test("T-031za: a name not on screen is searched; nothing found is NO_CANDIDATES; a failed search is honest")
    func searched() async {
        let search = CountingSearch(places: [Self.place("Z1", "珠海渔女", address: "香炉湾")])
        let found = await run(["name": "珠海渔女"], screen: [], search: search)
        #expect(found.ok && found.data["facts"]?["name"] == .string("珠海渔女"))
        #expect(search.queries.withLock { $0 } == ["珠海渔女"])
        let none = await run(["name": "不存在的地方"], screen: [], search: CountingSearch(places: []))
        #expect(!none.ok && none.code == .noCandidates)
        let failed = await run(["name": "珠海渔女"], screen: [], search: CountingSearch(places: [], error: .keyMissing))
        #expect(!failed.ok && failed.code == .amapWebKeyMissing)
    }

    @Test("T-031za: not shown is not done (PLACE_NOT_SHOWN, shown=false); no intro gives intro null")
    func notShown() async {
        let result = await run(["index": 1], screen: list, shown: false)
        #expect(!result.ok && result.code == .placeNotShown)
        #expect(result.data["facts"]?["shown"] == .bool(false))
        let noIntro = await run(["index": 1], screen: list, intro: nil)
        #expect(noIntro.ok && noIntro.data["facts"]?["intro"] == .null)
    }

    @Test("T-031za: declared NON_BLOCKING with exactly one of index 1-10 or name 1-40")
    func declaration() {
        #expect(ToolCatalog.spec("show_place") != nil)
        #expect(AsyncTool(name: "show_place") == .showPlace)
        #expect(ToolCatalog.validate("show_place", ["index": 2]) == nil)
        #expect(ToolCatalog.validate("show_place", ["name": "珠海渔女"]) == nil)
        #expect(ToolCatalog.validate("show_place", [:]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["index": 1, "name": "x"]) == .invalidFields)
        #expect(ToolCatalog.validate("show_place", ["index": 11]) == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_place", ["name": "  "]) == .invalidFieldValue)
        #expect(ToolCatalog.validate("show_place", ["name": .string(String(repeating: "长", count: 41))]) == .invalidFieldValue)
    }
}
