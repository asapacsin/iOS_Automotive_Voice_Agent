import Testing
@testable import NovaNav
@testable import NovaTools

/// F-15b §53 (T-040zf): a thin day is under 75% of its budget, or has fewer sights than the pace with room for one
/// more; a 360+ minute sight and a one-day plan of must-sees are exempt. Multi-day plans are a pool with `day_count`.
@Suite("TripThinDay")
struct TripThinDayTests {
    private func day(_ minutes: Int, driving: Int, sights: [Int], mustSee: Bool = false) -> TripChecks.Day {
        TripChecks.Day(minutes: minutes, drivingMinutes: driving, onlyMustSee: mustSee, area: "天河区",
                       sights: sights.count, longestSightMinutes: sights.max() ?? 0)
    }

    private func under(_ days: [TripChecks.Day], budget: Int = 480) -> [String] {
        TripChecks.run(notFound: [], days: days, budgetMinutes: budget, spareEmpty: true).filter { $0.kind == .under }.map(\.line)
    }

    private let full = TripChecks.Day(minutes: 450, drivingMinutes: 60, onlyMustSee: false, area: nil, sights: 4,
                                      longestSightMinutes: 120)

    @Test("T-040zf F-15b row 208: normal, one 90-min sight and 150 min of driving is thin (240 < 360)")
    func row208() {
        #expect(under([day(240, driving: 150, sights: [90]), full]) == ["第1天还空约4小时，在天河区附近加1到2个"])
    }

    @Test("F-15b row 209: normal, 2 sights and 390 min with 90 min left is thin by sights")
    func row209() {
        #expect(under([day(390, driving: 150, sights: [120, 120]), full]).count == 1)
    }

    @Test("F-15b row 210: normal, 2 sights of 180 and 420 min (60 left < 90) is not thin")
    func row210() {
        #expect(under([day(420, driving: 60, sights: [180, 180]), full]).isEmpty)
    }

    @Test("F-15b row 211: a day with one 480-min sight is the day, not thin")
    func row211() {
        #expect(under([day(480, driving: 0, sights: [480]), full]).isEmpty)
        // A 480-min park plus 40 min of driving on a must-see day: neither under nor over.
        let park = day(520, driving: 40, sights: [480], mustSee: true)
        #expect(TripChecks.run(notFound: [], days: [park, full], budgetMinutes: 480, spareEmpty: true).isEmpty)
        #expect(under([day(300, driving: 0, sights: [360]), full]).isEmpty)
    }

    @Test("F-15b row 212: a one-day plan of must-sees is what the driver listed; one importance-2 sight makes it thin")
    func row212() {
        #expect(under([day(200, driving: 20, sights: [90, 90], mustSee: true)]).isEmpty)
        #expect(under([day(200, driving: 20, sights: [90, 90], mustSee: false)]).count == 1)
        // More than one day: must-sees do not exempt.
        #expect(under([day(200, driving: 20, sights: [90, 90], mustSee: true), full]).count == 1)
    }

    @Test("F-15b row 213: relaxed (360), 2 sights and 280 min (≥ 270) is not thin")
    func row213() {
        #expect(TripChecks.minSights(budgetMinutes: 360) == 2 && TripChecks.minSights(budgetMinutes: 600) == 4)
        #expect(under([day(280, driving: 40, sights: [120, 120]), full], budget: 360).isEmpty)
        #expect(under([day(260, driving: 40, sights: [110, 110]), full], budget: 360).count == 1)
    }

    @Test("F-15b §53 item 3: spare places left means nothing more fits, so no under; unknown sights use minutes only")
    func spareAndUnknown() {
        let thin = day(240, driving: 150, sights: [90])
        #expect(TripChecks.run(notFound: [], days: [thin, full], budgetMinutes: 480, spareEmpty: false)
            .allSatisfy { $0.kind != .under })
        let unknown = TripChecks.Day(minutes: 400, drivingMinutes: 100, onlyMustSee: false, area: nil)
        #expect(under([unknown, full]).isEmpty)
    }

    @Test("F-15b row 214: fitNotes says a day is thin under 75% of the budget only")
    func row214() {
        let notes = TripPlanner.fitNotes([300, 400], budget: 480, spare: [])
        #expect(notes.contains { $0.hasPrefix("第1天还空大约") })
        #expect(!notes.contains { $0.hasPrefix("第2天还空") })
    }

    @Test("F-15b row 215: the make_trip_list text gives a multi-day plan as a pool with day_count, no days example")
    func row215() {
        let d = ToolCatalog.makeTripListDescription
        #expect(d.contains("places 填整个行程的地点池，加 day_count"))
        #expect(d.contains("day_count=2，places=[{name:"))
        #expect(!d.contains("days=[["))
        #expect(d.contains("司机自己说了哪天去哪里，才用 days 代替 places"))
    }
}
