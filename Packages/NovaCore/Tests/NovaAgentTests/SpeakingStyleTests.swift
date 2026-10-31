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
        #expect(result.advice?.contains("傲娇") == true)
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

    @Test("F-21 §14 row 1: both scopes in order, rules 2–7 kept, ≤ 1 500 characters, no one-or-two-sentence cap")
    func scopes() throws {
        let car = try #require(base.range(of: "【车辆与出行（严格）】"))
        let other = try #require(base.range(of: "【其他问题（自然回答）】"))
        let guardrails = try #require(base.range(of: "【注意】"))
        #expect(car.lowerBound < other.lowerBound && other.lowerBound < guardrails.lowerBound)
        for rule in ["2. 车辆控制是模拟车辆，结果以工具返回为准。",
                     "3. 工具返回 next 或 instruction 时照着做，只说一句。屏幕上已经显示的列表不要念出来。",
                     "4. 用户说「再低一点」「再高一点」这类没说明对象的话，也照常调用相应工具",
                     "5. 有点热、太热了：调低一度温度。有点冷：调高一度。座位有点高：座椅降低一级。",
                     "6. 导航：「导航去X」用 navigate_to；",
                     "7. 问「我现在在哪」「这是哪里」：调用 query_live_info（kind=current_location）"] {
            let range = try #require(base.range(of: rule), "\(rule)")
            #expect(range.lowerBound > car.lowerBound && range.lowerBound < other.lowerBound, "\(rule)")
        }
        #expect(base.count <= PersonaInstruction.maxBaseCharacters)
        #expect(!base.contains("一般一两句话") && !base.contains("不知道的事情如实说不知道"))
        #expect(base.contains("三到五句") && base.contains("查不了实时信息") && base.contains("绝不能说已经做好了"))
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
        "run_scenario": .phrase("车内场景（有蚊子、闷、困）"),
        "navigate_to": .phrase("navigate_to"),
        "choose_navigation_option": .phrase("choose_navigation_option"),
        "exit_navigation_mode": .phrase("exit_navigation_mode"),
        "query_live_info": .phrase("query_live_info"),
        "describe_camera_view": .phrase("describe_camera_view"),
        "play_music": .phrase("音乐"),
        "control_music": .phrase("音乐"),
        "place_call": .phrase("电话"),
        "open_app": .phrase("打开地图或设置"),
        "save_place": .phrase("常用地点"),
        "set_speaking_style": .phrase("说话方式"),
        "set_speech_output": .phrase("静音"),
        "end_conversation": .phrase("结束对话"),
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
        let car = try #require(base.range(of: "【车辆与出行（严格）】"))
        let other = try #require(base.range(of: "【其他问题（自然回答）】"))
        let topic = try #require(base.range(of: "摄像头画面"))
        let rule = try #require(base.range(of: "8. 问摄像头"))
        #expect(topic.lowerBound > car.lowerBound && topic.lowerBound < other.lowerBound)
        #expect(rule.lowerBound > car.lowerBound && rule.lowerBound < other.lowerBound)
        #expect(base.contains("一定调用 describe_camera_view（question 填用户原话；说后面、倒车时 camera=rear）"))
        #expect(base.contains("不用工具（要看画面的问题除外）"))
        #expect(base.count <= PersonaInstruction.maxBaseCharacters)
    }

    @Test("F-21 §15 row 7: every catalog tool is reached by the base (or marked notByVoice)")
    func coverage() {
        #expect(tools.count == Set(tools).count)
        let gaps = ToolPromptCoverage.gaps(tools: tools, base: base)
        #expect(gaps.isEmpty, "\(gaps)")
    }

    @Test("F-21 §15 row 8: dropping the camera from a copy of the base, or a new tool, fails and names it")
    func guardFails() {
        let stripped = base.replacingOccurrences(of: "describe_camera_view", with: "")
        #expect(ToolPromptCoverage.gaps(tools: tools, base: stripped).contains { $0.hasPrefix("describe_camera_view:") })
        let gaps = ToolPromptCoverage.gaps(tools: tools + ["fake_tool"], base: base)
        #expect(gaps.count == 1 && gaps[0].hasPrefix("fake_tool:"))
    }
}
