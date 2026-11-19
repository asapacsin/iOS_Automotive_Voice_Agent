import Testing
@testable import NovaKit
@testable import NovaTools

/// F-09b §13 item 6 (T-031o): the `ToolFailureAdvice` table as `may`/`must_not` values.
@Suite("T-031o: F-09b §13 stage 4, the ToolFailureAdvice table")
struct FailureAdviceReplyTests {
    private static let scripts = ["只说一句：", "只说这一句", "请如实说：", "请用户换个说法", "换个说法"]

    private func checkNext(_ next: String) {
        #expect(next.hasPrefix("用自己的话简短地说。"))
        for phrase in Self.scripts { #expect(!next.contains(phrase)) }
        for quote in ["「", "」", "\u{201C}", "\u{201D}", "\""] { #expect(!next.contains(quote)) }
        #expect(!next.contains("请用一句话"))
    }

    @Test("F-09b §13 row 7: every Android code is overridden by an iOS entry of may/must_not values")
    func everyCodeCovered() {
        for code in ToolFailureAdvice.generatedTable.keys {
            #expect(ToolFailureAdvice.iosTable[code] != nil, "\(code.rawValue)")
        }
        #expect(ToolFailureAdvice.iosTable.count >= ToolFailureAdvice.generatedTable.count)
    }

    @Test("F-09b §13 row 7: each entry gives facts, may, must_not and a next built from them; no advice sentence")
    func eachEntryIsReply() {
        for (code, rules) in ToolFailureAdvice.iosTable {
            let r = ToolFailureAdvice.reply(code, facts: ["what": "x"])
            #expect(!r.ok)
            #expect(r.code == code)
            #expect(r.advice == nil, "\(code.rawValue)")
            #expect(r.data["facts"] == .object(["what": "x"]))
            #expect(r.data["may"] == .array(rules.may.map { .string($0.rawValue) }))
            #expect(r.data["must_not"] == .array(rules.mustNot.map { .string($0.rawValue) }))
            #expect(!rules.mustNot.isEmpty, "\(code.rawValue)")
            let next = r.data["next"]?.stringValue ?? ""
            checkNext(next)
            #expect(ToolFailureAdvice.forCode(code) == next)
        }
    }

    @Test("F-09b §13 row 7: refusals of a not-done kind always forbid claiming it started or done")
    func notDoneEntries() {
        for code: ToolErrorCode in [.callNotConfirmed, .contactNotFound, .vehicleBlocked, .navigationNotRequested,
                                    .homeNotSet, .workNotSet, .mediaLibraryUnsupported, .notAvailableOnIOSYet] {
            let rules = ToolFailureAdvice.iosTable[code]
            #expect(rules?.mustNot.contains(.claimStarted) == true && rules?.mustNot.contains(.claimDone) == true,
                    "\(code.rawValue)")
        }
    }

    @Test("F-09b §13 row 7: the dispatcher failure keeps the caller's data as facts and builds next")
    func dispatcherFailure() {
        let r = ToolDispatcher.failure(.noLocation, data: ["kind": "weather"])
        #expect(r.data["facts"] == .object(["kind": "weather"]))
        #expect(r.data["kind"] == "weather")
        #expect(r.data["must_not"] == .array([.string("guess_location"), .string("invent")]))
        #expect(r.advice == nil)
    }

    @Test("F-09b §13 row 7: the call, contact and climate texts are rules, not sentences")
    func fixedNexts() {
        for next in [ToolFailureAdvice.confirmCallNext, ToolFailureAdvice.chooseContactNext,
                     ToolFailureAdvice.climateOffNext] {
            checkNext(next)
        }
        #expect(ToolFailureAdvice.confirmCallNext.contains(ReplyMay.askCall.gloss))
        #expect(ToolFailureAdvice.climateOffNext.contains(ReplyMay.powerOnClimate.gloss))
    }

    @Test("F-09b §13 row 7: the new glosses have no quotes and no item 8 phrase")
    func glosses() {
        let texts = ReplyMay.allCases.map(\.gloss) + ReplyMustNot.allCases.map(\.gloss)
        for t in texts {
            for phrase in Self.scripts { #expect(!t.contains(phrase), "\(t)") }
            #expect(!t.contains("「") && !t.contains("」"), "\(t)")
        }
    }
}
