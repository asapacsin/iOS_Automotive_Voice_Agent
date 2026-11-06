import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts

/// A fixed toneless pinyin table for the logged names (F-16 §14); an unknown character stands for itself.
struct TablePinyin: PinyinConverter {
    static let table: [Character: String] = [
        "横": "heng", "琴": "qin", "道": "dao", "河": "he", "子": "zi", "口": "kou", "岸": "an",
        "丽": "li", "君": "jun", "骏": "jun", "广": "guang", "场": "chang", "庞": "pang", "都": "du", "小": "xiao",
        "镇": "zhen", "玛": "ma", "妈": "ma", "格": "ge", "阁": "ge", "庙": "miao", "创": "chuang", "新": "xin",
        "坊": "fang", "鸿": "hong", "运": "yun", "濠": "hao", "影": "ying", "汇": "hui", "奢": "she",
        "北": "bei", "京": "jing", "天": "tian", "安": "an", "门": "men",
    ]
    func syllables(_ text: String) -> [String] {
        text.filter { !$0.isWhitespace && !$0.isPunctuation }.map { Self.table[$0] ?? String($0) }
    }
}

/// Answers per step: `around`, `city`, `type` and `country` scripts keyed by keywords.
final class StepSearch: PlaceSearch, @unchecked Sendable {
    let around: [String: [Place]]
    let city: [String: [Place]]
    let country: [String: [Place]]
    let log = Mutex<[String]>([])
    /// Runs inside every search call (a driver utterance landing while the search runs).
    var during: @Sendable () -> Void = {}

    init(around: [String: [Place]] = [:], city: [String: [Place]] = [:], country: [String: [Place]] = [:]) {
        self.around = around
        self.city = city
        self.country = country
    }

    func text(_ keywords: String, city: String?) async throws -> [Place] {
        during()
        log.withLock { $0.append("country \(keywords)") }
        return country[keywords] ?? []
    }
    func text(_ keywords: String, city code: String?, cityLimit: Bool) async throws -> [Place] {
        guard cityLimit, let code else { return try await text(keywords, city: code) }
        log.withLock { $0.append("city \(keywords) \(code)") }
        return city[keywords] ?? []
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        Issue.record("the near-first search never uses the around call with a nationwide fallback")
        return []
    }
    func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        during()
        log.withLock { $0.append("around \(keywords) \(radiusMeters)") }
        return around[keywords] ?? []
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

struct HengqinGeocoder: ReverseGeocoder {
    func adcode(at coordinate: GeoCoordinate) async throws -> String? { "440404" }
    func address(at coordinate: GeoCoordinate) async throws -> PlaceAddress? {
        PlaceAddress(formatted: "广东省珠海市香洲区横琴镇", district: "香洲区", road: nil)
    }
}

/// The uplink gate's closed-utterance count, moved by the test.
final class TurnCounter: @unchecked Sendable {
    let value = Mutex(0)
    func next() { value.withLock { $0 += 1 } }
}

final class Lines: @unchecked Sendable {
    let all = Mutex<[DestinationSearchLine]>([])
}

/// The car at 横琴 (113.54, 22.13), GCJ-02 already close enough for the test distances.
private let hengqin = GeoCoordinate(latitude: 22.13, longitude: 113.54, datum: .gcj02)

private func poi(_ name: String, km: Double, city: String = "珠海市", district: String = "香洲区") -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: 22.13 + km / 111, longitude: 113.54,
          datum: .gcj02), distanceMeters: Int(km * 1000), city: city, district: district)
}

private let match = DestinationMatch(pinyin: TablePinyin())

private extension JSONValue {
    func at(_ index: Int) -> JSONValue? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }
}

@Suite("T-042c F-16 §14 near-first destination search")
struct NearFirstSearchTests {
    func controller(_ search: StepSearch, routes: [RouteSummary] = [route(1, meters: 3_000, seconds: 360)],
                    turns: TurnCounter = TurnCounter(), lines: Lines = Lines())
        async -> (NavigationController, ScriptedNaviEngine) {
        let engine = ScriptedNaviEngine(routes: routes)
        let fix = LocationFix(coordinate: GeoCoordinate(latitude: 22.13, longitude: 113.54, datum: .wgs84),
                              horizontalAccuracyMeters: 20, timestamp: .zero)
        let near = NearFirstSearch(match: match, geocoder: HengqinGeocoder(),
                                   driverTurns: { turns.value.withLock { $0 } },
                                   onLine: { line in lines.all.withLock { $0.append(line) } })
        let nav = NavigationController(search: search, engine: engine, location: FixLocation(fix: fix), clock: ManualClock(),
                                       nearFirst: near)
        await nav.start()
        return (nav, engine)
    }

    @Test("F-16 §14 row 2: scores on the logged pairs; shuffled 高德 order is ranked by score; tiers as item 3")
    func scoredAndTiered() async {
        #expect(match.similarity("玛格庙", "妈阁庙") == 1)
        #expect(match.similarity("横道河子口岸", "横琴口岸") == 0.5)
        #expect(match.prior(km: 2) == 0.15 && match.prior(km: 50) == 0 && abs(match.prior(km: 26.5) - 0.075) < 1e-9)
        let shuffled = [poi("新濠影汇", km: 4), poi("横道河子口岸", km: 2_935), poi("横琴口岸(旅检区)", km: 2)]
        let ranked = match.rank(shuffled, destination: "横琴口岸", from: hengqin)
        #expect(ranked.map(\.place.name) == ["横琴口岸(旅检区)", "横道河子口岸", "新濠影汇"])
        #expect(ranked.map(\.score) == ranked.map(\.score).sorted(by: >))
        #expect(match.check(ranked) == .sure)
        #expect(match.check(match.rank([poi("丽骏庞都", km: 3)], destination: "丽君广场", from: hengqin)) == .ask)
        #expect(match.check(match.rank([poi("鸿运坊", km: 3)], destination: "创新坊", from: hengqin)) == .none)

        // Through the flow: the no-fit 创新坊 is NO_CANDIDATES with the advice, and nothing is routed.
        let (nav, engine) = await controller(StepSearch(around: ["创新坊": [poi("鸿运坊", km: 3)]]))
        let none = await nav.execute(tool("navigate_to", ["destination": "创新坊"]))
        #expect(none.code == .noCandidates && none.advice == NearFirstSearch.noFitText)
        #expect(engine.calls.withLock { $0 }.isEmpty)

        // Item 1: around, city (citylimit), the type word; nationwide only after all three found nothing.
        let search = StepSearch(around: ["口岸": [poi("横琴口岸", km: 2), poi("拱北口岸", km: 12)]])
        let (typed, _) = await controller(search)
        let listed = await typed.execute(tool("navigate_to", ["destination": "横道河子口岸"]))
        #expect(search.log.withLock { $0 } == ["around 横道河子口岸 50000", "city 横道河子口岸 440404", "around 口岸 50000"])
        #expect(listed.data["status"] == "confirm_candidate" && listed.data["check"] == "ask")
        #expect(listed.data["next"]?.stringValue == "是去横琴口岸吗？在2.0公里外。")
        let sure = StepSearch(around: ["横琴口岸": [poi("横琴口岸", km: 2), poi("新濠影汇", km: 4)]])
        let (sureNav, _) = await controller(sure)
        let found = await sureNav.execute(tool("navigate_to", ["destination": "横琴口岸"]))
        #expect(found.data["check"] == "sure" && found.data["next"]?.stringValue == "找到横琴口岸，在2.0公里外，说第一个就去，或说第几个。")
    }

    @Test("F-16 §14 row 3: only far candidates and the destination names their city → far_only, listed with km")
    func farOnly() async {
        let beijing = [poi("天安门", km: 1_900, city: "北京市", district: "东城区")]
        let search = StepSearch(country: ["北京天安门": beijing])
        let (nav, _) = await controller(search)
        let result = await nav.execute(tool("navigate_to", ["destination": "北京天安门"]))
        // The near steps first; 北京 is not the car's city, so nationwide after them.
        #expect(search.log.withLock { $0 } == ["around 北京天安门 50000", "city 北京天安门 440404", "country 北京天安门"])
        #expect(result.data["status"] == "far_only" && result.data["check"] == "far_only")
        #expect(result.data["next"]?.stringValue == "附近没找到北京天安门，最近的在1900公里外的北京市，要去那里吗？")
        let first = result.data["candidates"]?.at(0)
        #expect(first?["distance_km"] == .double(1_900) && first?["city"] == "北京市" && first?["district"] == "东城区")
        #expect(await nav.current.phase == .awaitingDestinationSelection)
    }

    @Test("F-16 §14 row 4: choose_navigation_option on an unsure or far candidate in the same turn is CONFIRM_FIRST; on the next driver turn it runs")
    func confirmFirst() async {
        let turns = TurnCounter()
        let search = StepSearch(around: ["丽君广场": [poi("丽骏庞都", km: 3), poi("丽君小镇", km: 9)]])
        let (nav, engine) = await controller(search, turns: turns)
        let listed = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        #expect(listed.data["check"] == "ask")
        let early = await nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(early.code == .confirmFirst)
        #expect(engine.calls.withLock { $0 }.isEmpty)
        // The next driver turn: Gemini's call is the yes (words are not checked, F-05a §6).
        turns.next()
        let started = await nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(started.data["status"] == "navigation_started")
        #expect(engine.calls.withLock { $0 }.first == "calculate 丽骏庞都")

        // Far: refused in the same turn too.
        let far = StepSearch(country: ["北京天安门": [poi("天安门", km: 1_900, city: "北京市")]])
        let (farNav, farEngine) = await controller(far, turns: turns)
        _ = await farNav.execute(tool("navigate_to", ["destination": "北京天安门"]))
        #expect(await farNav.execute(tool("choose_navigation_option", ["index": 1])).code == .confirmFirst)
        #expect(farEngine.calls.withLock { $0 }.isEmpty)
        turns.next()
        #expect(await farNav.execute(tool("choose_navigation_option", ["index": 1])).ok)
    }

    @Test("F-16 §14 row 5: a no, then the same destination twice → the next candidate, then DESTINATION_REJECTED")
    func noThenNext() async {
        let turns = TurnCounter()
        let search = StepSearch(around: ["丽君广场": [poi("丽君小镇", km: 9), poi("丽骏庞都", km: 3)]])
        let (nav, engine) = await controller(search, turns: turns)
        let first = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        #expect(first.data["candidates"]?.at(0)?["name"] == "丽骏庞都")
        turns.next()
        let next = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        #expect(next.data["status"] == "next_candidate" && next.data["count"] == 1)
        #expect(next.data["candidates"]?.at(0)?["name"] == "丽君小镇")
        #expect(next.data["next"]?.stringValue == "是去丽君小镇吗？在9.0公里外。")
        // The next candidate is unsure too: refused in the same turn.
        #expect(await nav.execute(tool("choose_navigation_option", ["index": 1])).code == .confirmFirst)
        turns.next()
        let rejected = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        #expect(rejected.code == .destinationRejected)
        #expect(rejected.advice == "这个地名刚被否定了，请问司机要去哪里。")
        #expect(await nav.execute(tool("navigate_to", ["destination": "丽君广场"])).code == .destinationRejected)
        #expect(engine.calls.withLock { $0 }.isEmpty)
        // Only one search ran: the no and the refusal search nothing.
        #expect(search.log.withLock { $0 } == ["around 丽君广场 50000"])
    }

    @Test("F-16 §14 row 6: routes of 6 min, 95 min and 2,935 km → 约6分钟; 1小时35分钟; the km plus the long-trip question")
    func startSentence() async {
        #expect(match.startSentence(name: "横琴口岸", meters: 3_000, seconds: 360).text == "去横琴口岸，约3.0公里，约6分钟。")
        #expect(match.startSentence(name: "珠海站", meters: 60_000, seconds: 95 * 60).text == "去珠海站，约60公里，1小时35分钟。")
        let long = match.startSentence(name: "横道河子口岸", meters: 2_935_000, seconds: 1_750 * 60)
        #expect(long.longTrip && long.text == "去横道河子口岸，约2935公里，29小时10分钟。这是长途，确定吗？")

        let turns = TurnCounter()
        let far = StepSearch(country: ["北京天安门": [poi("天安门", km: 2_935, city: "北京市")]])
        let (nav, _) = await controller(far, routes: [route(1, meters: 2_935_000, seconds: 1_750 * 60)], turns: turns)
        _ = await nav.execute(tool("navigate_to", ["destination": "北京天安门"]))
        turns.next()
        let started = await nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(started.data["long_trip"] == true)
        #expect(started.data["next"]?.stringValue?.contains("约2935公里，29小时10分钟。这是长途，确定吗？") == true)
        // What she says is exactly item 8's sentence; the cancel rule is a separate field.
        let next = started.data["next"]?.stringValue ?? ""
        let spoken = next.split(separator: "「").last?.split(separator: "」").first.map(String.init) ?? ""
        #expect(spoken == "已开始模拟导航，去天安门，约2935公里，29小时10分钟。这是长途，确定吗？")
        #expect(!spoken.contains("exit_navigation_mode"))
        #expect(started.data["if_driver_says_no"]?.stringValue?.contains("exit_navigation_mode") == true)
        // The driver's no: Gemini's exit cancels the route.
        #expect(await nav.execute(tool("exit_navigation_mode")).ok)
        #expect(await nav.current.phase == .idle)

        let near = StepSearch(around: ["横琴口岸": [poi("横琴口岸", km: 2)]])
        let (short, _) = await controller(near)
        let shortStart = await short.execute(tool("navigate_to", ["destination": "横琴口岸"]))
        #expect(shortStart.data["long_trip"] == false)
        #expect(shortStart.data["next"]?.stringValue?.contains("去横琴口岸，约3.0公里，约6分钟。") == true)
    }

    @Test("F-16 §14 row 7: one record line per call as item 9; RuntimeLog gets step and check only, no names")
    func recordAndLog() async {
        let lines = Lines()
        let search = StepSearch(around: ["丽君广场": [poi("丽骏庞都", km: 3)]])
        let (nav, _) = await controller(search, lines: lines)
        _ = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        _ = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        let all = lines.all.withLock { $0 }
        #expect(all.count == 2)
        #expect(all[0].recordLine == "dest-search destination=丽君广场 step=around n=1 top=丽骏庞都 score=0.65 km=3.0 check=ask")
        #expect(all[0].logLine == "destSearch step=around check=ask")
        #expect(all[1].check == .rejected && all[1].logLine == "destSearch step=around check=rejected")
        for line in all {
            #expect(!line.logLine.contains("丽") && !line.logLine.contains("庞"))
        }
    }

    @Test("F-16 §14 row 4: a driver utterance during the search is not the later turn → CONFIRM_FIRST")
    func turnReadAfterSearch() async {
        let turns = TurnCounter()
        let search = StepSearch(around: ["丽君广场": [poi("丽骏庞都", km: 3)]])
        search.during = { turns.next() }
        let (nav, engine) = await controller(search, turns: turns)
        #expect(await nav.execute(tool("navigate_to", ["destination": "丽君广场"])).data["check"] == "ask")
        #expect(await nav.execute(tool("choose_navigation_option", ["index": 1])).code == .confirmFirst)
        #expect(engine.calls.withLock { $0 }.isEmpty)
    }

    @Test("F-16 §14 row 4: navigate_to while navigating is matched and listed over guidance; the pick waits for a later turn")
    func whileNavigating() async {
        let turns = TurnCounter()
        let search = StepSearch(around: ["横琴口岸": [poi("横琴口岸", km: 2)], "丽君广场": [poi("丽骏庞都", km: 3)]])
        let (nav, engine) = await controller(search, turns: turns)
        #expect(await nav.execute(tool("navigate_to", ["destination": "横琴口岸"])).data["status"] == "navigation_started")
        let listed = await nav.execute(tool("navigate_to", ["destination": "丽君广场"]))
        #expect(listed.data["status"] == "candidates_listed_over_guidance" && listed.data["check"] == "ask")
        let over = await nav.current
        #expect(over.navigating && over.alongRouteList)
        let before = engine.calls.withLock { $0 }
        #expect(await nav.execute(tool("choose_navigation_option", ["index": 1])).code == .confirmFirst)
        #expect(engine.calls.withLock { $0 } == before)
        turns.next()
        let changed = await nav.execute(tool("choose_navigation_option", ["index": 1]))
        #expect(changed.data["status"] == "navigation_started")
        #expect(engine.calls.withLock { $0 }.contains("calculate 丽骏庞都"))
        // A no-fit name while guiding keeps the guidance.
        #expect(await nav.execute(tool("navigate_to", ["destination": "创新坊"])).code == .noCandidates)
        #expect(await nav.current.navigating)
    }

    @Test("F-16 §14 row 2: all three near searches empty → nationwide; a city word nearby (北京路) still ranks the near one")
    func nationwideAfterNear() async {
        let search = StepSearch(country: ["横琴口岸": [poi("横琴口岸", km: 2)]])
        let (nav, _) = await controller(search)
        _ = await nav.execute(tool("navigate_to", ["destination": "横琴口岸"]))
        #expect(search.log.withLock { $0 }
            == ["around 横琴口岸 50000", "city 横琴口岸 440404", "around 口岸 50000", "country 横琴口岸"])

        let road = StepSearch(around: ["北京路": [poi("北京路", km: 2)]],
                              country: ["北京路": [poi("北京路(东城)", km: 1_900, city: "北京市")]])
        let (roadNav, _) = await controller(road)
        let result = await roadNav.execute(tool("navigate_to", ["destination": "北京路"]))
        #expect(road.log.withLock { $0 } == ["around 北京路 50000", "country 北京路"])
        #expect(result.data["candidates"]?.at(0)?["distance_km"] == .double(2))
    }
}
