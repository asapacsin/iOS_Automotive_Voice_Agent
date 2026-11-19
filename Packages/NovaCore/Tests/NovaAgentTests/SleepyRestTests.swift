import Testing
@testable import NovaAgent
@testable import NovaKit
@testable import NovaPorts

/// F-09b §12 (T-031k): a sleepy driver gets a rest suggestion and nearby places, nothing in the car changes.
@Suite("T-031k F-09b §12 sleepy driver: rest suggestion and nearby places")
struct SleepyRestTests {
    static let sentence = "司机说累、犯困：不要调空调、车窗、座椅或音乐。用一句话建议找地方休息，并调用 navigate_to，destination=附近的咖啡店（在高速上用 附近的服务区），让司机在屏幕上选；司机没选就不开始导航。"
    static let sleepyIDs: Set<String> = ["drowsy", "drowsyMusicOn", "fallingAsleep", "hEyelids", "hDizzy", "h2EyesClosing",
                                         "h2Yawning", "t3Exhausted", "h3Nodding", "h3Foggy"]

    static func comfortCase(_ id: String) throws -> ComfortCase {
        try #require(ComfortCases.all.first { $0.id == id })
    }

    static func navigate(_ destination: String, ok: Bool = true) -> ComfortCallRecord {
        ComfortCallRecord(name: "navigate_to", ok: ok, code: ok ? nil : .noCandidates,
                          data: ok ? ["status": "candidates_listed"] : [:], arguments: ["destination": .string(destination)])
    }

    static func run(_ c: ComfortCase, calls: [ComfortCallRecord], reply: String,
                    end: ComfortVehicleState? = nil) -> ComfortRun {
        ComfortRun(caseID: c.id, attempt: 1, end: end ?? c.start, calls: calls, reply: reply, firstAudioMs: 900)
    }

    @Test("T-031k F-09b §12 row 1: the base holds item 1's sentence, not 不要说话，不回应, within maxBaseCharacters")
    func baseSentence() {
        #expect(PersonaInstruction.sleepySentence == Self.sentence)
        #expect(PersonaInstruction.comfortRule.contains(Self.sentence))
        for search in [false, true] {
            let text = PersonaInstruction.base(PersonaInstruction.base, webSearch: search)
            #expect(text.contains(Self.sentence))
            #expect(!text.contains("不要说话，不回应"))
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(search) \(text.count)")
        }
    }

    @Test("T-031k F-09b §12 row 2: the ten sleepy cases expect a nearby rest list, forbid every facet, are not silent")
    func comfortSet() throws {
        let sleepy = ComfortCases.all.filter(\.restSuggestion)
        #expect(Set(sleepy.map(\.id)) == Self.sleepyIDs)
        for c in sleepy {
            #expect(c.forbidden == Set(ComfortFacet.allCases), "\(c.id)")
            #expect(c.expected == .noTool && !c.accepted.contains(.act), "\(c.id)")
            // A one-sentence reply with the nearby list passes, for each place word.
            for destination in ["附近的咖啡店", "附近的服务区", "附近休息的地方"] {
                let passed = ComfortScorer.score(c, Self.run(c, calls: [Self.navigate(destination)], reply: "找个地方休息一下吧。"))
                #expect(passed.pass, "\(c.id) \(destination)")
            }
            // Not silent: an empty reply without the list fails; spoken words alone are no longer a failure code.
            #expect(ComfortScorer.score(c, Self.run(c, calls: [], reply: "")).failure == .noRestList, "\(c.id)")
            #expect(ComfortScorer.score(c, Self.run(c, calls: [Self.navigate("咖啡店")], reply: "休息一下吧。")).failure
                    == .noRestList, "\(c.id)")
            #expect(ComfortScorer.score(c, Self.run(c, calls: [Self.navigate("附近的超市")], reply: "休息一下吧。")).failure
                    == .noRestList, "\(c.id)")
            let twice = [Self.navigate("附近的咖啡店"), Self.navigate("附近的服务区")]
            #expect(ComfortScorer.score(c, Self.run(c, calls: twice, reply: "休息一下吧。")).failure == .noRestList, "\(c.id)")
            #expect(ComfortScorer.score(c, Self.run(c, calls: [Self.navigate("附近的咖啡店")],
                                                    reply: "你累了。找个咖啡店休息一下吧。")).failure == .tooManySentences, "\(c.id)")
        }
        // A car change fails even with the list.
        let drowsy = try Self.comfortCase("drowsy")
        var cooled = drowsy.start
        cooled.climate.powerOn = true
        let ac = ComfortCallRecord(name: "control_climate", ok: true, code: nil, data: [:])
        #expect(ComfortScorer.score(drowsy, Self.run(drowsy, calls: [ac, Self.navigate("附近的咖啡店")], reply: "休息一下吧。",
                                                     end: cooled)).pass == false)
        // whyDrowsy is unchanged: no tool, no list required.
        let why = try Self.comfortCase("whyDrowsy")
        #expect(!why.restSuggestion && why.expected == .noTool && why.forbidden == Set(ComfortFacet.allCases))
        #expect(ComfortScorer.score(why, Self.run(why, calls: [], reply: "长时间开车容易疲劳。")).pass)
    }

    @Test("T-031k F-09b §12 row 4 (scorer): no nearby results → one rest sentence passes; no route was started")
    func noResults() throws {
        let c = try Self.comfortCase("fallingAsleep")
        let failed = Self.navigate("附近的咖啡店", ok: false)
        #expect(ComfortScorer.score(c, Self.run(c, calls: [failed], reply: "附近没找到咖啡店，找个安全的地方停下休息一下吧。")).pass)
        #expect(ComfortScorer.score(c, Self.run(c, calls: [failed], reply: "没找到。找个地方休息吧。")).failure == .tooManySentences)
    }

    @Test("T-031k F-09b §12 item 3: the runner keeps the call's arguments for scoring")
    func argumentsKept() {
        #expect(ComfortEvalRunner.fields(.object(["destination": "附近的咖啡店"])) == ["destination": "附近的咖啡店"])
        #expect(ComfortEvalRunner.fields(.string("x")).isEmpty)
    }
}
