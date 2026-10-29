import Testing
@testable import NovaKit
@testable import NovaPorts
@testable import NovaTools

// Tables ported from the Android `ToolCallGuard*Test` files (commit 9c53929). The word-based guard tables
// (sunroof, driver-side window, nearby question, vague exit, speech output, named media, ambiguous referent) are
// superseded by F-05a §6 (owner rule 2026-10-29: no tool guard reads the transcript) and were removed with them.

func call(_ name: String, _ args: [String: JSONValue] = [:], id: String = "c1") -> ToolCall {
    ToolCall(id: CallID(id)!, name: name, arguments: .object(args))
}

/// A call in driver turn `turn`, after `closed` closed utterances, at `seconds`.
func ctx(turn: Int = 1, closed: Int = 1, seconds: Int64 = 0, navigating: Bool = false, guidance: Bool = false,
         listOpen: Bool = false, routeList: Int? = nil, tap: Bool = false) -> GuardContext {
    GuardContext(turn: turn, closedTurns: closed, now: NovaInstant(milliseconds: seconds * 1000), navigating: navigating,
                 guidanceRunning: guidance, listOpen: listOpen, routeChoiceOpen: routeList != nil,
                 routeListTurn: routeList ?? 0, fromTap: tap)
}

@Suite("T-017 F-09 guard: repeatedInTurn")
struct RepeatAndMediaGuardTests {
    @Test("F-09 an identical repeat-sensitive call twice in one turn is dropped")
    func repeats() {
        let firsts = [call("place_call", ["contact": "张三"]), call("navigate_to", ["destination": "中交汇通"]),
                      call("open_app", ["app": "maps"]), call("save_place", ["slot": "home", "address": "中交汇通"]),
                      call("exit_navigation_mode"),
                      call("control_climate", ["action": "adjust_temperature", "value": -2]),
                      call("control_music", ["action": "play"]), call("query_live_info", ["kind": "weather", "where": "北京"])]
        for first in firsts {
            var d = ToolDispatcher()
            // Words that ask for each of these (F-15a: navigate_to needs go words).
            let c = ctx()
            if case .refuse(let r) = d.decide(first, context: c), r.code == .duplicateInTurn { Issue.record("\(first.name)") }
            guard case .refuse(let r) = d.decide(first, context: c) else { Issue.record("\(first.name) ran twice"); continue }
            #expect(r.code == .duplicateInTurn, "\(first.name)")
        }
    }

    @Test("F-09 different arguments, a new turn, a pure read or no speech onset are not repeats")
    func notRepeats() {
        var d = ToolDispatcher()
        let c = ctx()
        #expect(d.decide(call("navigate_to", ["destination": "A"]), context: c) != .refuse(ToolDispatcher.failure(.duplicateInTurn)))
        guard case .execute = d.decide(call("navigate_to", ["destination": "B"]), context: c) else { Issue.record("B"); return }
        guard case .execute = d.decide(call("navigate_to", ["destination": "A"]), context: ctx(turn: 2, closed: 2)) else {
            Issue.record("new turn"); return
        }
        let look = call("describe_camera_view", ["question": "前面是什么"])
        for _ in 0..<2 { guard case .execute = d.decide(look, context: c) else { Issue.record("look"); return } }
        var fresh = ToolDispatcher()
        let dial = call("place_call", ["contact": "张三"])
        for _ in 0..<2 { guard case .execute = fresh.decide(dial, context: GuardContext()) else { Issue.record("no onset"); return } }
    }
}

@Suite("T-017 F-09 saved places, power advice, validation, catalog")
struct DispatchTests {
    @Test("F-09 回家 with no home saved is HOME_NOT_SET; 家乐福 is a search")
    func savedPlaces() {
        let none = GuardContext(savedPlaces: [])
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "回家"]), none) == .homeNotSet)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "带我去公司吧"]), none) == .workNotSet)
        // Unknown saved places: the navigation executor decides from the store.
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "回家"]), GuardContext()) == nil)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "回家"]), GuardContext(savedPlaces: [.home])) == nil)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "家乐福"]), none) == nil)
        #expect(ToolCallGuards.savedPlaceMissing(call("navigate_to", ["destination": "公司附近的星巴克"]), GuardContext()) == nil)
    }

    @Test("F-09 a temperature change with the climate off carries the CLIMATE_OFF advice")
    func powerAdvice() {
        let adjust = call("control_climate", ["action": "adjust_temperature", "value": -1])
        let off = ToolResult.success(["power_on": false, "temperature_c": 22])
        #expect(ToolDispatcher().finish(adjust, off).advice == ToolFailureAdvice.climateOff)
        #expect(ToolDispatcher().finish(adjust, .success(["power_on": true])).advice == nil)
        #expect(ToolDispatcher().finish(call("control_climate", ["action": "get_state"]), off).advice == nil)
    }

    @Test("F-09 validation codes from each domain")
    func validation() {
        let cases: [(ToolCall, ToolErrorCode?)] = [
            (call("open_app", ["app": "x"]), .appNotAllowed),
            (call("navigate_to", ["destination": .string(String(repeating: "a", count: 4097))]), .argumentsTooLarge),
            (call("no_such_tool"), .unknownTool),
            (call("navigate_to", ["destination": "  "]), .blankDestination),
            // Kotlin length is UTF-16: 61 astral characters are 122 units, over 120.
            (call("navigate_to", ["destination": .string(String(repeating: "𠀀", count: 61))]), .destinationTooLong),
            (call("navigate_to", ["destination": 1]), .invalidFieldType),
            (call("choose_navigation_option", ["index": 11]), .invalidIndex),
            (call("choose_navigation_option", ["index": "2"]), nil),
            (call("choose_navigation_option", ["index": 2, "name": "x"]), .invalidFields),
            (call("choose_navigation_option", ["preference": "cheapest"]), .preferenceNotAllowed),
            (call("control_climate", ["action": "set_temperature"]), .missingValue),
            (call("control_climate", ["action": "set_temperature", "value": "22"]), .invalidFieldType),
            (call("control_climate", ["action": "set_temperature", "value": 22]), nil),
            (call("control_climate", ["action": "on"]), .actionNotAllowed),
            (call("control_window", ["action": "adjust", "value": 0]), .invalidValue),
            (call("control_window", ["action": "open", "window": "sunroof"]), .invalidFieldValue),
            (call("control_seat", ["action": "adjust_height"]), .missingValue),
            (call("play_music", ["exclude_title": "x"]), .missingValue),
            (call("play_music", ["mood": "提神"]), nil),
            (call("query_live_info", ["kind": "news"]), .invalidKind),
            (call("query_live_info", ["kind": "weather", "where": .string(String(repeating: "北", count: 21))]), .invalidArgument),
            (call("set_speaking_style", ["style": "bossy"]), .styleNotAllowed),
            (call("exit_navigation_mode", ["x": 1]), .invalidFields),
            (ToolCall(id: CallID("c")!, name: "open_app", arguments: "maps"), .malformedJson),
        ]
        for (c, code) in cases { #expect(ToolCatalog.validate(c) == code, "\(c.name) \(c.arguments)") }
        #expect(ToolErrorCode.validationError.rawValue == "_validation_error")
    }

    @Test("F-09 the catalog has the 17 Android tools in domain order")
    func catalog() {
        #expect(ToolCatalog.specs.map(\.name) == [
            "navigate_to", "choose_navigation_option", "exit_navigation_mode", "save_place", "open_app",
            "control_music", "play_music", "control_climate", "control_window", "control_seat", "run_scenario",
            "describe_camera_view", "place_call", "query_live_info", "end_conversation", "set_speech_output",
            "set_speaking_style"])
        #expect(ToolCatalog.spec("describe_camera_view")?.repeatSensitive == false)
        #expect(ToolCatalog.spec("set_speaking_style")?.repeatSensitive == true)
        #expect(ToolCatalog.spec("play_music")?.declaration.parametersJSONSchema["required"] == nil)
        #expect(ToolCatalog.spec("control_window")?.declaration.parametersJSONSchema["properties"]?["window"]?["enum"]
                == .array(ToolCatalog.windows.map(JSONValue.string)))
    }

    @Test("F-09 every refusal code a guard returns has advice; NotYetExecutor is honest")
    func advice() async {
        for code: ToolErrorCode in [.navigationNotRequested, .confirmRequired, .duplicateInTurn, .mediaLibraryUnsupported,
                                    .homeNotSet, .workNotSet, .notAvailableOnIOSYet] {
            #expect(ToolFailureAdvice.forCode(code)?.isEmpty == false, "\(code)")
        }
        let r = await NotYetExecutor().execute(call("describe_camera_view", ["question": "x"]))
        #expect(!r.ok && r.code == .notAvailableOnIOSYet && r.advice != nil)
        let wire = ToolDispatcher.failure(.duplicateInTurn).wireObject(tool: "navigate_to")
        #expect(wire["ok"] == false && wire["error"] == "DUPLICATE_IN_TURN" && wire["tool"] == "navigate_to")
    }
}

@Suite("T-016d F-05a §6 guards never read the transcript")
struct NoTranscriptGuardTests {
    @Test("F-05a row 4 (revised): GuardContext has no transcript; the former word guards let the call run")
    func formerWordGuards() {
        // P56, P57, P61, P66, ambiguous referent, named media: the call runs as the model made it.
        let calls = [call("control_window", ["action": "open", "window": "all"]),
                     call("set_speech_output", ["mode": "silent"]),
                     call("navigate_to", ["destination": "附近的加油站"]),
                     call("control_seat", ["action": "adjust_height", "value": -1]),
                     call("control_music", ["action": "play"])]
        for c in calls {
            var d = ToolDispatcher()
            #expect(d.decide(c, context: ctx(navigating: true, guidance: true)) == .execute(c), "\(c.name)")
        }
        // The window is never rewritten from words (P57): what the call says is what runs.
        var d = ToolDispatcher()
        #expect(d.decide(calls[0], context: ctx()) == .execute(calls[0]))
    }

    @Test("F-05a §6: ending the running guidance asks once; a second call in a later turn within 15 s ends it")
    func confirmExit() {
        let exit = call("exit_navigation_mode")
        var d = ToolDispatcher()
        #expect(d.decide(exit, context: ctx(closed: 3, seconds: 0, guidance: true)) == .refuse(ToolDispatcher.failure(.confirmRequired)))
        // The same turn again: still asks (the model repeating itself is not the driver's yes).
        #expect(d.decide(exit, context: ctx(closed: 3, seconds: 1, guidance: true)) == .refuse(ToolDispatcher.failure(.confirmRequired)))
        #expect(d.decide(exit, context: ctx(closed: 4, seconds: 10, guidance: true)) == .execute(exit))
        // Too late: asks again.
        var late = ToolDispatcher()
        _ = late.decide(exit, context: ctx(closed: 3, seconds: 0, guidance: true))
        #expect(late.decide(exit, context: ctx(closed: 4, seconds: 16, guidance: true)) == .refuse(ToolDispatcher.failure(.confirmRequired)))
        // Not guiding, a list open (算了 closes the list), or a tap: no question.
        for context in [ctx(), ctx(guidance: true, listOpen: true), ctx(guidance: true, tap: true)] {
            var other = ToolDispatcher()  // fresh: exit is repeat-sensitive within a turn
            #expect(other.decide(exit, context: context) == .execute(exit))
        }
        #expect(ToolFailureAdvice.forCode(.confirmRequired)?.contains("要结束导航吗？") == true)
    }
}

@Suite("T-040e F-15a start guard on driver turns")
struct NavigationStartTurnTests {
    let pick = call("choose_navigation_option", ["index": 1])
    let fastest = call("choose_navigation_option", ["preference": "fastest"])

    @Test("F-15a row 4 (revised): a pick in a later driver turn than the list starts; in the same turn it is refused")
    func turns() {
        for c in [pick, fastest] {
            var d = ToolDispatcher()
            #expect(d.decide(c, context: ctx(closed: 2, routeList: 1)) == .execute(c))
            #expect(ToolCallGuards.navigationNotRequested(c, ctx(closed: 1, routeList: 1)) == .navigationNotRequested)
        }
        // Taps are never refused; picking a destination (no route list yet) is not this guard's.
        #expect(ToolCallGuards.navigationNotRequested(pick, ctx(closed: 1, routeList: 1, tap: true)) == nil)
        #expect(ToolCallGuards.navigationNotRequested(pick, ctx(closed: 1, listOpen: true)) == nil)
        // navigate_to is never refused by it.
        #expect(ToolCallGuards.navigationNotRequested(call("navigate_to", ["destination": "机场"]), ctx(closed: 1, routeList: 1)) == nil)
        #expect(ToolFailureAdvice.forCode(.navigationNotRequested)?.contains("要走哪一条") == true)
    }
}
