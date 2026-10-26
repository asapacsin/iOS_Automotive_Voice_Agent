import Synchronization
import Testing
import NovaKit
import NovaTools
import NovaVoice
@testable import NovaAgent

private final class EffectLog: Sendable {
    let effects = Mutex<[LifecycleEffect]>([])
    func record(_ new: [LifecycleEffect]) { effects.withLock { $0 += new } }
    var all: [LifecycleEffect] { effects.withLock { $0 } }
}

private func call(_ name: String, _ args: [String: JSONValue] = [:]) -> ToolCall {
    ToolCall(id: CallID("c1")!, name: name, arguments: .object(args))
}

private func lifecycle(_ log: EffectLog) -> ConversationLifecycle {
    ConversationLifecycle(clock: ManualClock()) { log.record($0) }
}

@Suite("F-02 end_conversation and set_speech_output")
struct ConversationToolsTests {
    @Test("end_conversation in ACTIVE sleeps and reports the read-back state")
    func endSleeps() async {
        let log = EffectLog()
        let life = lifecycle(log)
        await life.send(.wake)
        let result = await EndConversationHandler(lifecycle: life).execute(call(EndConversationHandler.tool))
        #expect(result.ok)
        #expect(result.data["state"] == .string("sleep"))
        #expect(life.state == .sleep)
        #expect(log.all.contains(.stateChanged(.sleep)))
    }

    @Test("end_conversation with no live conversation claims nothing (I-1)")
    func endWhileIdle() async {
        let log = EffectLog()
        let life = lifecycle(log)
        let result = await EndConversationHandler(lifecycle: life).execute(call(EndConversationHandler.tool))
        #expect(!result.ok)
        #expect(result.code == .actionNotAllowed)
        #expect(result.data["state"] == .string("deepIdle"))
        #expect(log.all.isEmpty)
    }

    @Test("set_speech_output silent then spoken changes the switch and reports it")
    func speechOutput() async {
        let seen = Mutex<[SpeechOutputMode]>([])
        let output = SpeechOutputSwitch { mode in seen.withLock { $0.append(mode) } }
        let handler = SpeechOutputHandler(output: output)
        let silent = await handler.execute(call(SpeechOutputHandler.tool, ["mode": .string("silent")]))
        #expect(silent.ok)
        #expect(silent.data["mode"] == .string("silent"))
        #expect(output.mode == .silent)
        let spoken = await handler.execute(call(SpeechOutputHandler.tool, ["mode": .string("spoken")]))
        #expect(spoken.data["mode"] == .string("spoken"))
        #expect(output.mode == .spoken)
        #expect(seen.withLock { $0 } == [.silent, .spoken])
    }

    @Test("an unknown mode is refused and changes nothing")
    func badMode() async {
        let output = SpeechOutputSwitch()
        let result = await SpeechOutputHandler(output: output).execute(call(SpeechOutputHandler.tool, ["mode": .string("loud")]))
        #expect(result.code == .modeNotAllowed)
        #expect(output.mode == .spoken)
    }

    @Test("modes match the catalog enum")
    func catalogModes() throws {
        let spec = try #require(ToolCatalog.declarations.first { $0.name == SpeechOutputHandler.tool })
        let modes = spec.parametersJSONSchema["properties"]?["mode"]?["enum"]
        #expect(modes == .array(SpeechOutputMode.allCases.map { .string($0.rawValue) }))
    }
}
