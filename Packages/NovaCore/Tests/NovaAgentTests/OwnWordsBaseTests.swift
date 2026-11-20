import NovaAgent
import Testing

@Suite("T-031l F-09b §13 item 2: the base instruction lets her say it in her own words")
struct OwnWordsBaseTests {
    @Test("F-09b §13 row 2: no 只说一句 in the car section; rule 3 as item 2; no comfort example; within maxBaseCharacters")
    func base() throws {
        let base = PersonaInstruction.base
        // F-09b §14 item 2 (T-031q): the sections became four parts; the own-words rule is in 【你有什么】.
        let has = try #require(base.range(of: "【你有什么】"))
        let decide = try #require(base.range(of: "【怎么决定】"))
        let section = String(base[has.lowerBound..<decide.lowerBound])
        #expect(!base.contains("只说一句"))
        #expect(section.contains("工具返回的 next 是要遵守的规则，不是台词，用自己的话说；屏幕上已经显示的列表不要念。"))
        #expect(!base.contains("空调调到24度了") && !base.contains("照着做"))
        for search in [false, true] {
            let text = PersonaInstruction.base(base, webSearch: search)
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(search) \(text.count)")
        }
    }
}
