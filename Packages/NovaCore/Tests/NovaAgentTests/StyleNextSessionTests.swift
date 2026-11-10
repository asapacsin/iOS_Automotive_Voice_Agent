import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
import NovaTools
import NovaVoice
@testable import NovaAgent

private final class StyleSettings: SettingsStore {
    private let values = Mutex<[String: String]>([:])
    func string(_ key: String) -> String? { values.withLock { $0[key] } }
    func bool(_ key: String) -> Bool? { nil }
    func set(_ value: String?, for key: String) { values.withLock { $0[key] = value } }
    func set(_ value: Bool, for key: String) {}
}

private func toneCall(_ style: String) -> ToolCall {
    ToolCall(id: CallID("tone_1")!, name: SpeakingStyleHandler.tool, arguments: .object(["style": .string(style)]))
}

private func providerCommands(_ effects: [AgentEffect]) -> [ProviderCommand] {
    effects.compactMap { if case .provider(let c) = $0 { c } else { nil } }
}

/// F-21 §17 (T-034d): a tone change is saved and starts with the next conversation; nothing is sent mid-session.
@Suite("T-034d F-21 §17 tone starts with the next conversation")
struct StyleNextSessionTests {
    static let lines: [SpeakingStyle: String] = [
        .default: "好的，下次对话开始我恢复正常的说法。",
        .sweet: "好呀，下次对话开始我说话甜一点。",
        .tsundere: "哼，下次对话开始就换傲娇的说法。",
        .gentle: "好的，下次对话开始我说话温柔一点。",
        .lively: "好嘞，下次对话开始我说话元气一点！",
    ]

    @Test("F-21 §17 row 1: after set_speaking_style and the reply turn, only the tool response is sent")
    func onlyToolResponseSent() async {
        let settings = StyleSettings()
        let call = toneCall("gentle")
        let result = await SpeakingStyleHandler(settings: settings).execute(call)
        var d = Drive()
        d.connect()
        let before = d.effects.count
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.userTranscript("说温柔一点", isFinal: true))
        d.realtime(.responseStarted(TurnID(1)))
        d.realtime(.toolCalls(TurnID(1), [call]))
        d.send(.toolFinished(TurnID(1), call, result))
        d.realtime(.responseDone(TurnID(1), outcome: .completed))
        // A tone picked in 设置 afterwards only writes the setting; the core has no event for it.
        settings.set(SpeakingStyle.sweet.rawValue, for: SettingsKey.personaStyle)
        let sent = providerCommands(Array(d.effects[before...]))
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { if case .toolResponses = $0 { true } else { false } })
        #expect(SpeakingStyle.saved(in: settings) == .sweet)
    }

    @Test("F-21 §17 row 2: each style is saved and next is the item 3 line; no line mentions 声音")
    func confirmationLines() async {
        for style in SpeakingStyle.allCases {
            let settings = StyleSettings()
            let result = await SpeakingStyleHandler(settings: settings).execute(toneCall(style.rawValue))
            let line = "只说这一句：" + Self.lines[style]!
            #expect(result.ok)
            #expect(result.data["style"] == .string(style.rawValue))
            #expect(result.data["next"] == .string(line))
            #expect(result.data["instruction"] == .string(line))
            #expect(!line.contains("声音") && !line.contains("嗓音"))
            #expect(SpeakingStyle.saved(in: settings) == style)
        }
    }

    @Test("F-21 §17 row 3: tone gentle saved, a session set up without a handle carries the gentle block")
    func newSessionCarriesTone() {
        let settings = StyleSettings()
        settings.set(SpeakingStyle.gentle.rawValue, for: SettingsKey.personaStyle)
        let built = PersonaInstruction.build(base: PersonaInstruction.base, style: SpeakingStyle.saved(in: settings))
        #expect(built == PersonaInstruction.base + "\n" + SpeakingStyle.gentle.block)
        var state = AgentState()
        let connects = providerCommands(state.handle(.start, at: .zero))
        #expect(connects.contains { if case .connect(_, nil) = $0 { true } else { false } })
    }

    @Test("F-21 §17 row 4: a reconnect with a handle sends the setup as today and nothing after setupComplete")
    func resumedSetupSendsNothingExtra() {
        var state = AgentState(truthfulness: TruthfulnessTuning(), resume: SessionResume(handle: "h1"))
        let start = providerCommands(state.handle(.start, at: .zero))
        #expect(start.contains { if case .connect(_, "h1") = $0 { true } else { false } })
        let after = providerCommands(state.handle(.realtime(.setupComplete, connection: state.session.connection),
                                                  at: .zero))
        #expect(after.isEmpty)
    }

    @Test("F-21 §17 row 5: no contextUpdate encoder or StyleUpdates type is left in the sources")
    func removedFromSources() throws {
        let packages = URL(fileURLWithPath: #filePath).deletingLastPathComponent()  // NovaAgentTests
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()  // Packages
        let roots = [packages.appendingPathComponent("NovaCore/Sources"),
                     packages.appendingPathComponent("NovaRealtime/Sources"),
                     packages.deletingLastPathComponent().appendingPathComponent("App")]
        var hits: [String] = []
        for root in roots {
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let file as URL in walk where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                for word in ["contextUpdate", "StyleUpdates", "StyleUpdateLine", "style-update"] where text.contains(word) {
                    hits.append("\(file.lastPathComponent): \(word)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }
}
