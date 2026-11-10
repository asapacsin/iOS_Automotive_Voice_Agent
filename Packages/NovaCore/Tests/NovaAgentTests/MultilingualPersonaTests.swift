import Testing
import NovaKit
import NovaPorts
import NovaVoice
import NovaTools
@testable import NovaAgent

/// F-05a §14 items 4-5 (T-016l): her language follows the driver's; the record says which recognizer gave the line.
@Suite("T-016l F-05a §14 persona, setup and record")
struct MultilingualPersonaTests {
    @Test("T-016l F-05a §14 row 7: no languageCode in the session config; persona texts exactly as item 4")
    func row7() {
        #expect(SessionConfig(systemInstruction: "x", tools: []).languageCode == nil)
        let base = PersonaInstruction.base
        #expect(base.contains("用自然的口语，句子短") && !base.contains("用自然的普通话口语"))
        #expect(base.contains("用户说中文就用普通话回答，说英文就用英文，说日语就用日语；只用这三种语言。") && !base.contains("只说普通话。"))
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            for search in [false, true] {
                #expect(PersonaInstruction.base(PersonaInstruction.base(for: mode), webSearch: search).count <= PersonaInstruction.maxBaseCharacters)
            }
        }
    }

    @Test("T-016n F-05a §16 item 3: heard-local keeps the words with asr=stream and no lang; asr-model removed bytes=")
    func record() {
        var s = ConversationRecorder()
        #expect(s.add(.heardLocal("现在几点"), atMs: 5) == ["5 heard-local 现在几点 asr=stream"])
        var n = ConversationRecorder()
        #expect(n.add(.heardLocal(nil), atMs: 6) == ["6 heard-local （没听清） asr=stream"])
        var m = ConversationRecorder()
        #expect(m.add(.asrModelRemoved(bytes: 239_549_735), atMs: 7) == ["7 asr-model removed bytes=239549735"])
    }
}
