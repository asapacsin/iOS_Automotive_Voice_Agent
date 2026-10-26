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
