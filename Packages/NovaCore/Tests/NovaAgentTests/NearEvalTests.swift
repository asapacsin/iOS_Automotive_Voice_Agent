import Testing
@testable import NovaAgent
@testable import NovaNav

@Suite("T-040z F-15b §51 row 187: NearEval cases and scoring (the live run is on the PC)")
struct NearEvalTests {
    @Test("F-15b §51 row 187: about 25 sentences × 4 set-ups, the spec's sentences included")
    func cases() {
        let sentences = NearEval.cases.map(\.sentence)
        #expect((23...27).contains(sentences.count) && Set(sentences).count == sentences.count)
        for s in ["附近的咖啡店", "东京的便利店", "浅草寺附近吃的", "酒店附近有什么", "那边天气", "路上有加油站吗", "珠海站", "附近有什么酒店"] {
            #expect(sentences.contains(s), "\(s)")
        }
        #expect(NearEval.Setup.all.count == 4)
        // No case accepts near=trip while no trip is shown.
        for c in NearEval.cases {
            for s in NearEval.Setup.all where s.tripShown == false {
                #expect(c.accepted(s).contains(.near(.trip)) == false, "\(c.sentence) \(s)")
            }
        }
    }

    @Test("F-15b §51 row 187: right centre or a question; wrong country without saying so; near=trip while hidden")
    func scoring() throws {
        let coffee = try #require(NearEval.cases.first { $0.sentence == "附近的咖啡店" })
        let zhuhaiTrip = NearEval.Setup(phone: .zhuhai, tripShown: true)
        let tokyoNone = NearEval.Setup(phone: .tokyo, tripShown: false)
        let good = NearEval.score(coffee, zhuhaiTrip, .init(choice: .near(.here), searchedCountry: "CN"))
        #expect(good.right && good.wrongCountrySilent == false)
        #expect(NearEval.score(coffee, zhuhaiTrip, .init(choice: .asks)).right)
        let wrong = NearEval.score(coffee, zhuhaiTrip, .init(choice: .near(.place), searchedCountry: "JP"))
        #expect(wrong.right == false && wrong.wrongCountrySilent)
        #expect(NearEval.score(coffee, zhuhaiTrip, .init(choice: .near(.place), searchedCountry: "JP", saidWhere: true))
            .wrongCountrySilent == false)
        let hotel = try #require(NearEval.cases.first { $0.sentence == "酒店附近有什么" })
        #expect(NearEval.score(hotel, tokyoNone, .init(choice: .near(.trip))).tripWhileHidden)
        let report = NearEval.report([good, good, wrong])
        #expect(report.passed == false && report.logLine == "near eval runs=3 right=2 wrong_country=1 trip_hidden=0 pass=no")
        #expect(NearEval.report(Array(repeating: good, count: 20)).passed)
    }
}
