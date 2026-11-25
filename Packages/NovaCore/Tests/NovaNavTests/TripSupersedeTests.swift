import Foundation
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// F-15b §69 (T-040zv): a newer trip request replaces one still running.

private let table: [String: [Place]] = [
    "珠海|珠海渔女": [mapPlace("珠海渔女", 22.27, city: "珠海市")],
    "珠海|日月贝": [mapPlace("日月贝", 22.26, city: "珠海市")],
    "珠海|长隆海洋王国": [mapPlace("长隆海洋王国", 22.10, city: "珠海市")],
]

private func sight(_ name: String) -> JSONValue { ["name": .string(name), "city": "珠海", "minutes": 60] }

/// Waits (real time, bounded) until `ok` holds.
private func until(_ ok: () async -> Bool) async {
    for _ in 0..<400 where !(await ok()) { try? await Task.sleep(for: .milliseconds(5)) }
}

@Suite("T-040zv F-15b §69 a newer trip request replaces one still running")
struct TripSupersedeTests {
    @Test("T-040zv F-15b §69 row 326: plan_trip A running, plan_trip B arrives: A cancelled, its result SUPERSEDED (not sent); B runs; record trip superseded")
    func row326() async {
        // A: round 1 answers, round 2 hangs; B: two rounds.
        let rig = await LookupRig([plannerAnswer([[sight("珠海渔女")]], done: false), .hang,
                                   plannerAnswer([[sight("日月贝")]]), plannerAnswer([[sight("日月贝")]])],
                                  search: AmapLookupSearch(table))
        let a = Task { await rig.run(planCall("珠海四天", id: "call_a")) }
        await until { rig.model.count >= 2 }
        let b = await rig.run(planCall("珠海两天", id: "call_b"))
        let ra = await a.value
        #expect(b.ok && b.data["saved"] == true, "\(b)")
        #expect(ra.code == .superseded, "\(ra)")
        #expect(rig.model.cancelled.withLock { $0 } == 1)
        let line = rig.line("trip superseded ").first ?? ""
        #expect(line.hasPrefix("trip superseded old=call_a new=call_b ms="), "\(line)")
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.asked) == ["日月贝"])
    }

    @Test("T-040zv F-15b §69 row 327: A cancelled after one planner round: nothing from A saved; B starts from the plan saved before")
    func row327() async {
        let rig = await LookupRig([plannerAnswer([[sight("长隆海洋王国")]]), plannerAnswer([[sight("长隆海洋王国")]]),
                                   plannerAnswer([[sight("珠海渔女")]], done: false), .hang,
                                   plannerAnswer([[sight("日月贝")]]), plannerAnswer([[sight("日月贝")]])],
                                  search: AmapLookupSearch(table))
        // The plan saved before.
        _ = await rig.run(planCall("珠海一天", id: "call_0"))
        let before = await rig.planner.currentPlan
        #expect(before.allStops.map(\.stop.asked) == ["长隆海洋王国"])
        let a = Task { await rig.run(planCall("珠海四天", id: "call_a")) }
        await until { rig.model.count >= 4 }
        // A did one round and is in its second: the plan is still the one before.
        #expect(await rig.planner.currentPlan.allStops.map(\.stop.asked) == ["长隆海洋王国"])
        let change = ToolCall(id: CallID("call_b")!, name: "plan_trip", arguments: ["change": "换成日月贝"])
        let b = await rig.run(change)
        #expect(await a.value.code == .superseded)
        #expect(b.ok, "\(b)")
        // B's request was built from the plan saved before A (A saved nothing).
        let bFirst = rig.model.calls.withLock { $0 }[4].first?.content ?? ""
        #expect(bFirst.contains("长隆海洋王国") && !bFirst.contains("珠海渔女"), "\(bFirst)")
        #expect(await rig.planner.currentPlan.allStops.allSatisfy { $0.stop.asked != "珠海渔女" })
    }
}
