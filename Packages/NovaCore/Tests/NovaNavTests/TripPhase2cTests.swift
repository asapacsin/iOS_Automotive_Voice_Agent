import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Answers with `answers` in order (nil throws), recording each query.
final class IntroSearch: WebSearchService, @unchecked Sendable {
    let answers: Mutex<[String?]>
    let queries = Mutex<[String]>([])
    init(_ answers: [String?]) { self.answers = Mutex(answers) }
    func search(_ query: String, attempt: Int) async throws -> WebSearchReply {
        queries.withLock { $0.append(query) }
        let next = answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
        guard let next else { throw WebSearchError.timeout }
        return WebSearchReply(answer: next, sources: [])
    }
}

func introCard(_ id: String, _ name: String, city: String?) -> TripCard {
    TripCard(index: 1, placeID: id, name: name, district: nil, km: nil, photoURL: nil, initial: String(name.prefix(1)),
             passed: false, city: city)
}

@Suite("T-040m F-15b phase 2c spot introduction and cards put away")
struct TripPhase2cTests {
    @Test("F-15b row 54: the sheet's introduction is the search answer; the query is 介绍一下广州陈家祠")
    func row54() async {
        let search = IntroSearch(["陈家祠是岭南祠堂。"])
        let intro = TripIntro(search: search, clock: ManualClock())
        #expect(await intro.answer(for: introCard("B1", "陈家祠", city: "广州市")) == .text("陈家祠是岭南祠堂。"))
        #expect(search.queries.withLock { $0 } == ["介绍一下广州陈家祠"])
        #expect(TripIntro.query(name: "广州塔", city: "广州") == "介绍一下广州塔")
    }

    @Test("F-15b row 55: a failure is not kept; the next open searches and shows; the third is cached")
    func row55() async {
        let search = IntroSearch([nil, "陈家祠是岭南祠堂。"])
        let lines = TripLines()
        let intro = TripIntro(search: search, clock: ManualClock(), onLine: { lines.append($0) })
        let card = introCard("B2", "陈家祠", city: "广州")
        #expect(await intro.answer(for: card) == .failed)
        #expect(await intro.answer(for: card) == .text("陈家祠是岭南祠堂。"))
        #expect(await intro.answer(for: card) == .text("陈家祠是岭南祠堂。"))
        #expect(search.queries.withLock { $0 }.count == 2)
        #expect(lines.withLock { $0 } == ["trip intro ok=no ms=0", "trip intro ok=yes ms=0", "trip intro ok=cached ms=0"])
        // An empty answer is a failure too.
        let empty = TripIntro(search: IntroSearch(["  "]), clock: ManualClock())
        #expect(await empty.answer(for: card) == .failed)
    }

    @Test("F-15b row 56: a saved 家 stop makes no search and has no introduction")
    func row56() async {
        let search = IntroSearch(["x"])
        let intro = TripIntro(search: search, clock: ManualClock())
        #expect(await intro.answer(for: introCard("saved_home", "家", city: "广州")) == TripIntro.Answer.none)
        #expect(search.queries.withLock { $0 }.isEmpty)
    }

    @Test("F-15b row 57: 珠海环宇城 with city 珠海 is not doubled; no city leaves it out")
    func row57() {
        #expect(TripIntro.query(name: "珠海环宇城", city: "珠海") == "介绍一下珠海环宇城")
        #expect(TripIntro.query(name: "珠海环宇城", city: "珠海市") == "介绍一下珠海环宇城")
        #expect(TripIntro.query(name: "广州塔", city: nil) == "介绍一下广州塔")
    }

    func exit() -> ToolCall { trip("exit_navigation_mode") }

    @Test("F-15b row 59: nothing open, a plan with stops: trip_cards_hidden, plan unchanged; again: no_navigation_active")
    func row59() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        let r = await rig.nav.execute(exit())
        #expect(r.data["status"] == "trip_cards_hidden")
        #expect(await rig.planner.cardsHidden)
        #expect(await rig.order().count == 2)
        #expect(await rig.nav.execute(exit()).data["status"] == "no_navigation_active")
        #expect(rig.lines.withLock { $0 }.contains("trip cards hidden=yes"))
        // No plan: nothing to hide.
        let empty = await TripRig()
        #expect(await empty.nav.execute(exit()).data["status"] == "no_navigation_active")
    }

    @Test("F-15b row 60: a destination list open over a plan: navigation_selection_cancelled and the cards hidden")
    func row60() async {
        var table = tianjin
        table["车站"] = [spot("天津站", lat: 39.13, lng: 117.21), spot("天津西站", lat: 39.16, lng: 117.16)]
        let rig = await TripRig(search: TripSearch(table))
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await rig.nav.execute(trip("navigate_to", ["destination": "车站"]))
        #expect(await rig.nav.current.phase == .awaitingDestinationSelection)
        #expect(await rig.nav.execute(exit()).data["status"] == "navigation_selection_cancelled")
        #expect(await rig.planner.cardsHidden)
    }

    @Test("F-15b row 61 (§51 item 2): hidden, then edit_trip_list read shows; hidden again, trip_next is refused; trip_plans list leaves them hidden")
    func row61() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        _ = await rig.nav.execute(exit())
        _ = await rig.run(trip("edit_trip_list", ["action": "read"]))
        #expect(await !rig.planner.cardsHidden)
        _ = await rig.nav.execute(exit())
        #expect(await rig.planner.cardsHidden)
        #expect(await rig.run(trip("trip_next")).code == .tripHidden)
        #expect(await rig.planner.cardsHidden)
        #expect(rig.lines.withLock { $0 }.filter { $0 == "trip cards hidden=no" }.count == 1)
        _ = await rig.run(trip("trip_plans", ["action": "list"]))
        #expect(await rig.planner.cardsHidden)
    }

    @Test("F-15b row 62: guidance running: navigation_stopped, the cards stay")
    func row62() async {
        let rig = await TripRig()
        _ = await rig.run(trip("make_trip_list", ["places": names(["古文化街", "五大道"])]))
        #expect(await rig.run(trip("trip_next")).ok)
        #expect(await rig.nav.execute(exit()).data["status"] == "navigation_stopped")
        #expect(await !rig.planner.cardsHidden)
    }

    @Test("F-15b row 63: the exit and edit texts carry the §22 item 4 sentences; the rest is Android's")
    func row63() {
        let android = ToolCatalog.generatedSpecs.first { $0.name == "exit_navigation_mode" }!.declaration.description
        let ios = ToolCatalog.spec("exit_navigation_mode")!.declaration.description
        #expect(ios == android.replacingOccurrences(of: "按 status 答：", with: ToolCatalog.exitPanelText + ToolCatalog.exitCardsText))  // + F-09b §17 item 4
        #expect(ios.contains("每次说关掉都要调用，没调用不要说已关闭。按 status 答：trip_cards_hidden=已收起行程卡片，navigation_stopped="))
        #expect(ToolCatalog.spec("edit_trip_list")!.declaration.description.contains("「清单里有什么」「打开行程」「看看行程」→read"))
    }
}
