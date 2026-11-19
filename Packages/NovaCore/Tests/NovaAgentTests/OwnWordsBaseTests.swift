import NovaAgent
import Testing

@Suite("T-031l F-09b §13 item 2: the base instruction lets her say it in her own words")
struct OwnWordsBaseTests {
    @Test("F-09b §13 row 2: no 只说一句 in the car section; rule 3 as item 2; no comfort example; within maxBaseCharacters")
    func base() throws {
        let base = PersonaInstruction.base
        let car = try #require(base.range(of: "【车辆与出行（严格）】"))
        let other = try #require(base.range(of: "【其他问题（自然回答）】"))
        let section = String(base[car.lowerBound..<other.lowerBound])
        #expect(!section.contains("只说一句"))
        #expect(section.contains("只按工具返回的结果回答，用自己的话，简短自然，一般一两句。"))
        #expect(section.contains("3. 工具返回的 next 是规则，不是台词：照规则做，用自己的话说，不要照念。屏幕上已经显示的列表不要念出来。"))
        #expect(!base.contains("空调调到24度了") && !base.contains("照着做"))
        for search in [false, true] {
            let text = PersonaInstruction.base(base, webSearch: search)
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(search) \(text.count)")
        }
    }
}
