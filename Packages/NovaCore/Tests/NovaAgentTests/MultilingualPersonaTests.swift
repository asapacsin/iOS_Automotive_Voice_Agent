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

    @Test("T-016l F-05a §14 item 5: heard-local carries lang and asr; asr-model state lines")
    func record() {
        var r = ConversationRecorder()
        #expect(r.add(.heardLocal("What time is it", language: .en), atMs: 5) == ["5 heard-local What time is it lang=en asr=sensevoice"])
        var s = ConversationRecorder()
        #expect(s.add(.heardLocal("现在几点"), atMs: 5) == ["5 heard-local 现在几点 lang=stream asr=stream"])
        var m = ConversationRecorder()
        #expect(m.add(.asrModel(.ready), atMs: 7) == ["7 asr-model state=ready"])
    }
}
