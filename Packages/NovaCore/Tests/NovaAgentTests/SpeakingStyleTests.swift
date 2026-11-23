import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
@testable import NovaAgent

private final class MemorySettings: SettingsStore {
    private let values = Mutex<[String: String]>([:])
    private let flags = Mutex<[String: Bool]>([:])
    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func bool(_ key: String) -> Bool? { flags.withLock { $0[key] } }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func set(_ value: Bool, for key: String) { flags.withLock { $0[key] = value } }
}

private final class RecordingExecutor: ToolExecutor {
    let seen = Mutex<[String]>([])
    func execute(_ call: ToolCall) async -> ToolResult {
        seen.withLock { $0.append(call.name) }
        return .success()
    }
}

private func styleCall(_ style: String) -> ToolCall {
    ToolCall(id: CallID("s1")!, name: SpeakingStyleHandler.tool, arguments: .object(["style": .string(style)]))
}

@Suite("F-21 persona speaking style")
struct SpeakingStyleTests {
    @Test("styles are exactly the catalog enum; default is 正常")
    func catalogStyles() {
        #expect(SpeakingStyle.allCases.map(\.rawValue) == ToolCatalog.speakingStyles)
        #expect(SpeakingStyle.saved(in: MemorySettings()) == .default)
    }

    @Test("F-21 row 1: a style change persists and the next session reads it")
    func persists() async {
        let settings = MemorySettings()
        let result = await SpeakingStyleHandler(settings: settings).execute(styleCall("tsundere"))
        #expect(result.ok)
        #expect(result.data["style"] == "tsundere")
        #expect(result.data["next"]?.stringValue?.isEmpty == false)
        #expect(settings.string(SettingsKey.personaStyle) == "tsundere")
        #expect(SpeakingStyle.saved(in: settings) == .tsundere)
    }

    @Test("F-21 row 2: the instruction is capped at 4000 characters and the base is never cut")
    func capped() {
        let base = "规则：一定要调用工具。"
        for style in SpeakingStyle.allCases {
            let built = PersonaInstruction.build(base: base, style: style)
            #expect(built.count <= PersonaInstruction.maxCharacters)
            #expect(built.hasPrefix(base))
            #expect(built.contains("工具规则永远优先"))
        }
        let long = String(repeating: "规", count: 3990)
        let built = PersonaInstruction.build(base: long, style: .sweet)
        #expect(built.count == PersonaInstruction.maxCharacters)
        #expect(built.hasPrefix(long))
        let huge = String(repeating: "规", count: 4100)
        #expect(PersonaInstruction.build(base: huge, style: .sweet) == huge)
    }

    @Test("an unknown style is refused with the list of styles, and the saved style is unchanged")
    func unknownRefused() async {
        let settings = MemorySettings()
        settings.set("gentle", for: SettingsKey.personaStyle)
        let result = await SpeakingStyleHandler(settings: settings).execute(styleCall("bossy"))
        #expect(!result.ok)
        #expect(result.code == .styleNotAllowed)
        #expect(result.data["may"] == .array(["name_styles"]) && result.data["next"]?.stringValue?.contains("傲娇") == true)
        #expect(settings.string(SettingsKey.personaStyle) == "gentle")
        #expect(ToolCatalog.validate(styleCall("bossy")) == .styleNotAllowed)
    }

    @Test("F-21 row 3: after a style change an action request is still executed")
    func actionStillRuns() async {
        let settings = MemorySettings()
        let vehicle = RecordingExecutor()
        let runner = ToolRunner(executors: [SpeakingStyleHandler.tool: SpeakingStyleHandler(settings: settings),
                                            "set_temperature": vehicle])
        let results = AsyncStream.makeStream(of: ToolResult.self)
        let sink = results.continuation
        runner.start(styleCall("sweet")) { _ = sink.yield($0) }
        let action = ToolCall(id: CallID("a1")!, name: "set_temperature", arguments: .object([:]))
        runner.start(action) { _ = sink.yield($0) }
        var finished = 0
        for await result in results.stream {
            #expect(result.ok)
            finished += 1
            if finished == 2 { break }
        }
        #expect(vehicle.seen.withLock { $0 } == ["set_temperature"])
        let built = PersonaInstruction.build(base: "1. 一定要调用工具。", style: SpeakingStyle.saved(in: settings))
        #expect(built.hasPrefix("1. 一定要调用工具。"))
    }
}

@Suite("T-034a F-21 §14 base instruction scope")
struct BaseInstructionScopeTests {
    let base = PersonaInstruction.base

    @Test("F-21 §14 row 1 (as rewritten by F-09b §14 item 2): four parts in order, simulated car, ≤ 1 500 characters")
    func scopes() throws {
        // F-09b §14 item 2 (T-031q): the scopes and numbered rules became four parts (BaseInstructionTests row 5).
        let parts = try ["【你是谁】", "【你有什么】", "【怎么决定】", "【安全】"].map { try #require(base.range(of: $0)).lowerBound }
        #expect(parts == parts.sorted())
        #expect(base.contains("模拟车辆") && base.contains("AMBIGUOUS_REFERENT"))
        #expect(!base.contains("一两句话以内"))
        #expect(base.count <= 1500)
    }

    @Test("F-21 §14 item 5: the style is still appended after the whole base")
    func styleAppended() {
        let built = PersonaInstruction.build(base: base, style: .default)
        #expect(built.hasPrefix(base) && built.count > base.count && built.count <= PersonaInstruction.maxCharacters)
    }
}

/// F-21 §15 item 6: how the base instruction reaches each catalog tool. A new tool needs a row here (a phrase that
/// must stay in `PersonaInstruction.base`, or `notByVoice` with the reason).
enum ToolPromptCoverage: Sendable {
    case phrase(String)
    case notByVoice(String)

    static let table: [String: ToolPromptCoverage] = [
        "control_climate": .phrase("空调"),
        "control_window": .phrase("车窗"),
        "control_seat": .phrase("座椅"),
        // F-09b §5 item 3: the state arrives by note; the model reads it on its own only when it wants it again.
        "get_vehicle_state": .notByVoice("read by the model on its own; the state arrives by note (F-09b §5)"),
        // F-09b §4: rule 5 names it for 不用、改回去.
        "undo_last_change": .phrase("undo_last_change"),
        "navigate_to": .phrase("导航"),
        "choose_navigation_option": .phrase("导航"),
        "exit_navigation_mode": .phrase("导航"),
        "query_live_info": .phrase("位置和时间"),
        "describe_camera_view": .phrase("摄像头"),
        "play_music": .phrase("音乐"),
        "control_music": .phrase("音乐"),
        "place_call": .phrase("电话"),
        "open_app": .phrase("打开地图、设置"),
        "save_place": .phrase("常用地点"),
        "set_speaking_style": .phrase("说话方式"),
        "set_speech_output": .phrase("静音"),
        "end_conversation": .phrase("结束对话"),
        // F-13a §10 item 3 (T-032i): 音量 is in the strict scope.
        "set_volume": .phrase("音量"),
        // F-15b §5 (T-040i): the trip list is 要去的地方 in the strict scope; the tool texts carry the wording.
        // F-15b §49 (T-040u); §55 item 11 (T-040zh) removed make_trip_list and edit_trip_list.
        "set_trip_plan": .phrase("要去的地方"),
        "trip_next": .phrase("导航"),
        // F-15b §16 (T-040l): saved trips are 要去的地方 too.
        "trip_plans": .phrase("要去的地方"),
        // F-09b §16 item 8 (T-031za).
        "show_place": .phrase("地方卡片"),
        "show_on_map": .phrase("地图"),
    ]

    /// Failure messages for `tools` against `base`; empty when every tool is covered.
    static func gaps(tools: [String], base: String, table: [String: ToolPromptCoverage] = table) -> [String] {
        tools.compactMap { name in
            switch table[name] {
            case nil:
                "\(name): no coverage row; add it to the strict scope of PersonaInstruction.base or mark it notByVoice"
            case .phrase(let phrase)? where !base.contains(phrase):
                "\(name): 「\(phrase)」 is missing from PersonaInstruction.base; add it to the strict scope or mark it notByVoice"
            case .notByVoice(let why)? where why.isEmpty: "\(name): notByVoice needs a reason"
            default: nil
            }
        }
    }
}

@Suite("T-034b F-21 §15 camera questions use the camera tool")
struct CameraScopeTests {
    let base = PersonaInstruction.base
    let tools = ToolCatalog.declarations.map(\.name)

    @Test("F-21 §15 row 1: camera in the strict scope, rule 8, other scope excludes it, ≤ 1 500 characters")
    func cameraRule() throws {
        // F-09b §14 item 2 (T-031q): rule 8 left the base; the camera is named in 【你有什么】 and the
        // describe_camera_view description says when to use it.
        let has = try #require(base.range(of: "【你有什么】"))
        let decide = try #require(base.range(of: "【怎么决定】"))
        let camera = try #require(base.range(of: "看摄像头"))
        #expect(camera.lowerBound > has.lowerBound && camera.lowerBound < decide.lowerBound)
        #expect(!base.contains("8. 问摄像头"))
        #expect(base.count <= 1500)
    }

    @Test("F-21 §15 row 7: every catalog tool is reached by the base (or marked notByVoice)")
    func coverage() {
        #expect(tools.count == Set(tools).count)
        let gaps = ToolPromptCoverage.gaps(tools: tools, base: base)
        #expect(gaps.isEmpty, "\(gaps)")
    }

    @Test("F-21 §15 row 8: dropping the camera from a copy of the base, or a new tool, fails and names it")
    func guardFails() {
        let stripped = base.replacingOccurrences(of: "摄像头", with: "")
        #expect(ToolPromptCoverage.gaps(tools: tools, base: stripped).contains { $0.hasPrefix("describe_camera_view:") })
        let gaps = ToolPromptCoverage.gaps(tools: tools + ["fake_tool"], base: base)
        #expect(gaps.count == 1 && gaps[0].hasPrefix("fake_tool:"))
    }
}

@Suite("T-046b F-18 §14 item 3 time rule in the persona")
struct TimeRuleTests {
    @Test("Row 7: the time rule is in the base, 时间 in the strict scope, base within 1700 characters (§25 item 5)")
    func rule() {
        // F-09b §14 item 2 (T-031q): rule 9 left the base (time is in the query_live_info description and code
        // blocks time questions to web_search, F-18 §25 item 7); 时间 stays among what her tools can look up.
        #expect(!PersonaInstruction.base.contains("9. 问现在几点"))
        #expect(PersonaInstruction.base.contains("位置和时间"))
        #expect(PersonaInstruction.base.count <= PersonaInstruction.maxBaseCharacters)
    }
}
