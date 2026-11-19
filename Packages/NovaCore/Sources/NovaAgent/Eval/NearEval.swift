import NovaKit
import NovaNav

/// F-15b §51 item 8 (T-040z): the search-centre eval. About 25 sentences, each run in four set-ups (phone in Zhuhai or
/// in Tokyo × a Tokyo trip shown or none). Each case lists the accepted `near` values or "asks". Run on the PC against
/// the live route (3 runs each); this file holds the cases and the scoring only (no network, no key).
/// Pass: right centre or a question ≥ 95 %; a search in the wrong country without saying so: 0; `near=trip` while no
/// trip is shown: 0.
public enum NearEval {
    public enum Phone: String, Sendable, Hashable, CaseIterable { case zhuhai, tokyo }

    public struct Setup: Sendable, Hashable, CustomStringConvertible {
        public let phone: Phone
        public let tripShown: Bool
        public init(phone: Phone, tripShown: Bool) {
            self.phone = phone
            self.tripShown = tripShown
        }
        public static let all: [Setup] = Phone.allCases.flatMap { p in [false, true].map { Setup(phone: p, tripShown: $0) } }
        public var description: String { "\(phone.rawValue)/\(tripShown ? "trip" : "none")" }
        /// The country of the phone's fix.
        public var phoneCountry: String { phone == .zhuhai ? "CN" : "JP" }
    }

    /// What the model did with the sentence.
    public enum Choice: Sendable, Hashable {
        case near(NearKind)
        case asks
        /// No `navigate_to` and no question (another tool, or a plain answer).
        case other
    }

    public struct Case: Sendable, Hashable {
        public let sentence: String
        /// Whether the sentence is a navigation search at all (「那边天气」 is not: it must not become `navigate_to`).
        public let accepted: @Sendable (Setup) -> Set<Choice>
        /// The country the driver means, when the sentence settles it; nil when only a question is right.
        public let country: @Sendable (Setup) -> String?

        public init(_ sentence: String, accepted: @escaping @Sendable (Setup) -> Set<Choice>,
                    country: @escaping @Sendable (Setup) -> String?) {
            self.sentence = sentence
            self.accepted = accepted
            self.country = country
        }
        public static func == (a: Case, b: Case) -> Bool { a.sentence == b.sentence }
        public func hash(into h: inout Hasher) { h.combine(sentence) }
    }

    /// One run of a case in a set-up: the model's choice, the country searched (from the tool's `vendor` and
    /// `searched_around` facts), and whether her reply said where it searched.
    public struct Run: Sendable, Hashable {
        public let choice: Choice
        public let searchedCountry: String?
        public let saidWhere: Bool
        public init(choice: Choice, searchedCountry: String? = nil, saidWhere: Bool = false) {
            self.choice = choice
            self.searchedCountry = searchedCountry
            self.saidWhere = saidWhere
        }
    }

    public struct Score: Sendable, Hashable {
        public let right: Bool
        public let wrongCountrySilent: Bool
        public let tripWhileHidden: Bool
    }

    public static func score(_ c: Case, _ setup: Setup, _ run: Run) -> Score {
        let right = c.accepted(setup).contains(run.choice)
        let wrong: Bool = {
            guard let searched = run.searchedCountry, let meant = c.country(setup) else { return false }
            return searched != meant && !run.saidWhere
        }()
        return Score(right: right, wrongCountrySilent: wrong, tripWhileHidden: run.choice == .near(.trip) && !setup.tripShown)
    }

    public struct Report: Sendable, Hashable {
        public let runs: Int
        public let right: Int
        public let wrongCountrySilent: Int
        public let tripWhileHidden: Int
        public var rightRate: Double { runs == 0 ? 0 : Double(right) / Double(runs) }
        public var passed: Bool { runs > 0 && rightRate >= 0.95 && wrongCountrySilent == 0 && tripWhileHidden == 0 }
        /// `near eval runs= right= wrong_country= trip_hidden= pass=` (numbers only, I-8).
        public var logLine: String {
            "near eval runs=\(runs) right=\(right) wrong_country=\(wrongCountrySilent) trip_hidden=\(tripWhileHidden) pass=\(passed ? "yes" : "no")"
        }
    }

    public static func report(_ scores: [Score]) -> Report {
        Report(runs: scores.count, right: scores.filter(\.right).count,
               wrongCountrySilent: scores.filter(\.wrongCountrySilent).count,
               tripWhileHidden: scores.filter(\.tripWhileHidden).count)
    }

    // MARK: Cases

    private static let here: Set<Choice> = [.near(.here)]
    private static let place: Set<Choice> = [.near(.place)]
    /// 「附近」: the phone; with a trip shown in the other country, a question which side is also right.
    private static let nearby: @Sendable (Setup) -> Set<Choice> = { s in
        s.tripShown && s.phone == .zhuhai ? [.near(.here), .asks] : [.near(.here)]
    }
    private static let phoneCountry: @Sendable (Setup) -> String? = { $0.phoneCountry }
    /// A trip place: `trip` while shown; otherwise only a question (no trip to search).
    private static let tripPlace: @Sendable (Setup) -> Set<Choice> = { s in s.tripShown ? [.near(.trip), .asks] : [.asks] }
    private static let tokyo: @Sendable (Setup) -> String? = { _ in "JP" }
    private static let china: @Sendable (Setup) -> String? = { _ in "CN" }

    public static let cases: [Case] = [
        Case("附近的咖啡店", accepted: nearby, country: phoneCountry),
        Case("附近有什么酒店", accepted: nearby, country: phoneCountry),
        Case("附近有什么好吃的", accepted: nearby, country: phoneCountry),
        Case("最近的加油站", accepted: nearby, country: phoneCountry),
        Case("这儿有停车场吗", accepted: nearby, country: phoneCountry),
        Case("找个厕所", accepted: nearby, country: phoneCountry),
        Case("我想喝点咖啡", accepted: nearby, country: phoneCountry),
        Case("找个便利店", accepted: nearby, country: phoneCountry),
        Case("东京的便利店", accepted: { _ in place }, country: tokyo),
        Case("浅草寺附近吃的", accepted: { s in s.tripShown ? [.near(.place), .near(.trip)] : place }, country: tokyo),
        Case("新宿站附近的拉面", accepted: { _ in place }, country: tokyo),
        Case("涩谷有什么好玩的", accepted: { _ in place }, country: tokyo),
        Case("大阪的酒店", accepted: { _ in place }, country: { _ in "JP" }),
        Case("珠海站", accepted: { s in s.phone == .zhuhai ? [.near(.here), .near(.place)] : place }, country: china),
        Case("香洲的停车场", accepted: { s in s.phone == .zhuhai ? [.near(.here), .near(.place)] : place }, country: china),
        Case("广州塔附近的餐厅", accepted: { _ in place }, country: china),
        Case("澳门的赌场酒店", accepted: { _ in place.union([.asks]) }, country: { _ in nil }),
        Case("酒店附近有什么", accepted: tripPlace, country: { s in s.tripShown ? "JP" : nil }),
        Case("酒店附近吃的", accepted: tripPlace, country: { s in s.tripShown ? "JP" : nil }),
        Case("第一天那个景点附近的咖啡店", accepted: tripPlace, country: { s in s.tripShown ? "JP" : nil }),
        Case("行程里那家酒店旁边有便利店吗", accepted: tripPlace, country: { s in s.tripShown ? "JP" : nil }),
        Case("那边天气", accepted: { _ in [.other, .asks] }, country: { _ in nil }),
        Case("路上有加油站吗", accepted: { _ in [.near(.route), .near(.here), .asks] }, country: phoneCountry),
        Case("那里有停车场吗", accepted: { _ in [.asks] }, country: { _ in nil }),
        Case("去那边的超市", accepted: { _ in [.asks] }, country: { _ in nil }),
    ]
}
