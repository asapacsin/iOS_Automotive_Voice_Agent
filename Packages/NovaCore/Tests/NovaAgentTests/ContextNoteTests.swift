import Foundation
import Testing
import NovaKit
import NovaNav
import NovaPorts
@testable import NovaAgent

/// F-09b §14 items 1, 5, 8 (T-031p): the `[系统] 现在` note, `AskOrActEval` and the complaint set.
@Suite("T-031p F-09b §14 stage A")
struct ContextNoteTests {
    static let zhuhai = GeoCoordinate(latitude: 22.27, longitude: 113.57, datum: .gcj02)

    static func snap(district: String = "香洲区", trip: String? = nil, time: String = "11月20日 星期五 14:05",
                     navigating: Bool = false, shown: Bool = false) -> ContextSnapshot {
        ContextSnapshot(place: ContextPlace(city: "珠海市", district: district, trip: trip), onHighway: nil,
                        localTime: time, navigating: navigating, tripShown: shown)
    }

    static func fields(_ effects: [AgentEffect]) -> [[String]] {
        effects.compactMap { if case .diagnostic(.contextNote(let f)) = $0 { f.map(\.rawValue) } else { nil } }
    }

    @Test("T-031p F-09b §14 row 1: note at start and on a district change, not on a same-district fix or a new minute; field names only in the log")
    func row1() {
        var d = Drive()
        d.send(.context(Self.snap()))
        d.connect()
        #expect(FlexibleAssistantTests.notes(d.effects).contains { $0.contains("[系统] 现在：位置：珠海市香洲区；当地时间 11月20日 星期五 14:05；没在导航；屏幕上没有行程。这句不用回答。") })
        #expect(Self.fields(d.effects) == [["place", "time", "navigating", "trip"]])
        // A fix in the same district, a minute later: no note.
        #expect(Self.fields(d.send(.context(Self.snap(time: "11月20日 星期五 14:06")))).isEmpty)
        // District change: a note with the new place.
        let moved = d.send(.context(Self.snap(district: "金湾区")))
        #expect(Self.fields(moved).count == 1)
        #expect(FlexibleAssistantTests.notes(moved).joined().contains("珠海市金湾区"))
        // Navigation starts: one of the facts changed.
        #expect(Self.fields(d.send(.context(Self.snap(district: "金湾区", navigating: true)))).count == 1)
        // The log line names fields only.
        let line = DiagnosticEvent.contextNote(fields: [.place, .highway, .time, .navigating, .trip]).logLine
        #expect(line == "contextNote fields=place,highway,time,navigating,trip")
        var highway = Self.snap()
        highway.onHighway = true
        #expect(highway.note.contains("；在高速上；") && highway.fields.contains(.highway))
        #expect({ var r = ConversationRecorder(); return r.add(.nowNote(fields: [.place, .time]), atMs: 5) }() == ["5 contextNote fields=place,time"])
        // Nothing while disconnected; on the next connect the note goes again.
        var off = Drive()
        #expect(Self.fields(off.send(.context(Self.snap()))).isEmpty)
    }

    @Test("T-031p F-09b §14 row 1: city cut from the regeo address; regeo only after a move or a trip change")
    func cityAndTracker() {
        #expect(ContextPlace.city(formatted: "广东省珠海市香洲区情侣中路", district: "香洲区") == "珠海市")
        #expect(ContextPlace.city(formatted: "北京市朝阳区建国路", district: "朝阳区") == "北京市")
        #expect(ContextPlace.city(formatted: "澳门特别行政区花地玛堂区", district: "花地玛堂区") == "澳门特别行政区")
        #expect(ContextPlace.city(formatted: "新疆维吾尔自治区乌鲁木齐市天山区", district: "天山区") == "乌鲁木齐市")
        var t = ContextPlaceTracker()
        let here = ContextCenter(coordinate: Self.zhuhai, trip: nil)
        #expect(t.known(here) == nil)
        t.looked(here, ContextPlace(city: "珠海市", district: "香洲区"))
        let near = ContextCenter(coordinate: GeoCoordinate(latitude: 22.271, longitude: 113.571, datum: .gcj02), trip: nil)
        #expect(t.known(near) == .some(ContextPlace(city: "珠海市", district: "香洲区")))
        #expect(t.known(ContextCenter(coordinate: GeoCoordinate(latitude: 22.30, longitude: 113.57, datum: .gcj02), trip: nil)) == nil)
        #expect(t.known(ContextCenter(coordinate: Self.zhuhai, trip: "大阪城")) == nil)
    }

    @Test("T-031p F-09b §14 row 2: trip cards shown, the note's place is the trip location (F-15b §51 item 9)")
    func row2() {
        let center = ContextCenter(coordinate: GeoCoordinate(latitude: 34.69, longitude: 135.53, datum: .gcj02), trip: "大阪城")
        let place = ContextPlace(center: center, address: PlaceAddress(formatted: "大阪府大阪市中央区", district: "中央区", road: nil))
        let s = ContextSnapshot(place: place, onHighway: nil, localTime: "11月20日 星期五 14:05", navigating: false, tripShown: true)
        #expect(s.note.contains("位置：行程位置（大阪城）") && s.note.contains("屏幕上显示着行程"))
        let none = ContextSnapshot(place: nil, onHighway: nil, localTime: "t", navigating: false, tripShown: false)
        #expect(none.note.contains("位置：不知道"))
    }

    @Test("T-031p F-09b §14 row 3: item 5's cases; the scorer fails a tool before agreement and a question in a decided case")
    func row3() throws {
        let ids = Set(AskOrActEval.cases.map(\.id))
        #expect(ids.count == AskOrActEval.cases.count)
        let said = AskOrActEval.cases.flatMap { $0.turns.map(\.said) }
        for s in ["有點困了", "好", "不用", "想带家人玩三天，不知道去哪", "太近了", "周末带孩子去哪玩", "随便",
                  "有点热", "准备一个广东三天的旅游行程", "做个打卡清单", "再低一点", "我现在在哪", "现在几点",
                  "导航去珠海站", "第二个", "为什么开车容易犯困", "导航去公司"] {
            #expect(said.contains(s), "\(s)")
        }
        let sleepy = try #require(AskOrActEval.askOrAct.first { $0.id == "sleepy-yes" })
        // Good: a question first, nothing done; navigate_to after 好 without a question.
        let good = [AskOrActEval.TurnRun(tools: [], asked: true), .init(tools: ["navigate_to"], asked: false)]
        #expect(AskOrActEval.score(sleepy, good) == nil)
        // A tool before agreement.
        let early = [AskOrActEval.TurnRun(tools: ["navigate_to"], asked: true), .init(tools: ["navigate_to"], asked: false)]
        #expect(AskOrActEval.score(sleepy, early)?.failure == .actedBeforeAgreement)
        // A read-only tool before agreement is fine.
        let read = [AskOrActEval.TurnRun(tools: ["query_live_info"], asked: true), .init(tools: ["navigate_to"], asked: false)]
        #expect(AskOrActEval.score(sleepy, read) == nil)
        // A suggestion that does not ask.
        #expect(AskOrActEval.score(sleepy, [.init(tools: [], asked: false)])?.failure == .noQuestion)
        // A question in a decided case.
        let hot = try #require(AskOrActEval.complaint.first { $0.id == "hot" })
        #expect(AskOrActEval.score(hot, [.init(tools: ["control_climate"], asked: true)])?.failure == .askedWhenDecided)
        #expect(AskOrActEval.score(hot, [.init(tools: ["control_seat"], asked: false)])?.failure == .wrongTool)
        #expect(AskOrActEval.score(hot, [.init(tools: [], asked: false)])?.failure == .noTool)
        #expect(AskOrActEval.score(hot, [.init(tools: ["control_climate"], asked: false, claimsMatch: false)])?.failure == .claimMismatch)
        // Report: ≥ 9 of 10.
        let pass = AskOrActEval.report(hot, Array(repeating: [.init(tools: ["control_climate"], asked: false)], count: 9)
                                           + [[.init(tools: [], asked: false)]])
        #expect(pass.pass && pass.logLine == "ask-or-act case=hot runs=10 passed=9 pass=yes noTool=1")
        let fail = AskOrActEval.report(hot, Array(repeating: [.init(tools: [], asked: true)], count: 2)
                                           + Array(repeating: [.init(tools: ["control_climate"], asked: false)], count: 8))
        #expect(!fail.pass)
        #expect(AskOrActEval.newFailures(baseline: [pass], now: [fail]) == ["hot"])
        #expect(AskOrActEval.newFailures(baseline: [fail], now: [fail]).isEmpty)
    }
}
