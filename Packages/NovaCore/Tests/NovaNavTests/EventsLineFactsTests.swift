import Foundation
import NovaKit
import Testing
@testable import NovaNav
@testable import NovaTools

@Suite("T-046zg F-18 §44 item 3: the trip planner's events list")
struct EventsLineFactsTests {
    @Test("T-046zg F-18 §44 row 91a (planner part): the events list of trip-plan §64 gives an unconfirmed venue and dates as 「未找到」, confirmed ones as they are")
    func plannerList() {
        let at = Date(timeIntervalSince1970: 1_795_579_200)
        var e = EventEntry(name: "2026横琴马拉松", start: "2026-12-27", end: "2026-12-27", datesText: "", venue: "", city: "珠海",
                           sourceURL: "u", sourceSite: "", fetchedAt: at)
        let none = TripPlannerShape.eventsLine([e])
        #expect(none.contains("未找到") && !none.contains("2026-12-27"))
        e.venue = "珠海国际会展中心"
        e.venueVia = "page"
        e.datesVia = "search"
        let kept = TripPlannerShape.eventsLine([e])
        #expect(kept.contains("珠海国际会展中心") && kept.contains("2026-12-27") && !kept.contains("未找到"))
    }
}
