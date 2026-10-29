import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

@Suite("T-030 F-10 driver context and ambiguity")
struct ContextResolverTests {
    let seatDown = call("control_seat", ["action": "adjust_height", "seat": "driver", "value": .int(-1)])
    let coolDown = call("control_climate", ["action": "adjust_temperature", "value": .int(-1)])
    let t0 = NovaInstant(milliseconds: 1_000)

    func both() -> DriverContext {
        var context = DriverContext()
        context.record(coolDown, ok: true, at: t0)
        context.record(seatDown, ok: true, at: t0 + .seconds(10))
        return context
    }

    @Test("F-10 row 1: seat and temperature changed, 再低一点 (or 第一点) asks 座椅/温度")
    func ambiguous() {
        let context = both()
        let now = t0 + .seconds(20)
        #expect(context.clarify("再低一点", at: now) == ["座椅", "温度"])
        #expect(context.clarify("第 一 点", at: now) == ["座椅", "温度"])
        var dispatcher = ToolDispatcher()
        guard case .refuse(let r) = dispatcher.decide(seatDown, context: ctx("再低一点"),
                                                      clarify: { context.clarify($0, at: now) }) else {
            Issue.record("seat moved"); return
        }
        #expect(r.code == .ambiguousReferent)
        #expect(r.data["options"] == .string("座椅还是温度"))
    }

    @Test("F-10: a line that names the dimension runs (the answer 座椅, 再凉一点)")
    func named() {
        let context = both()
        let now = t0 + .seconds(20)
        for said in ["座椅", "座位再低一点", "再凉一点", "温度再低一点", "风小一点"] {
            #expect(context.clarify(said, at: now) == nil, "\(said)")
        }
    }

    @Test("F-10 row 2: only the seat changed, so it lowers again")
    func single() {
        var context = DriverContext()
        context.record(seatDown, ok: true, at: t0)
        #expect(context.clarify("再低一点", at: t0 + .seconds(5)) == nil)
    }

    @Test("F-10 row 3: nothing changed, no question")
    func none() {
        #expect(DriverContext().clarify("再量一点", at: t0) == nil)
    }

    @Test("F-10: a failed change is no referent, and referents expire after 180 s")
    func failedAndExpired() {
        var context = DriverContext()
        context.record(coolDown, ok: false, at: t0)
        context.record(seatDown, ok: true, at: t0)
        #expect(context.referents(at: t0) == [.seat])
        context.record(coolDown, ok: true, at: t0)
        #expect(context.clarify("再低一点", at: t0 + .seconds(181)) == nil)
    }
}
