import Foundation
import Testing
@testable import NovaAgent
@testable import NovaTools

@Suite("T-031q F-09b §14 stage B base instruction")
struct BaseInstructionTests {
    @Test("T-031q F-09b §14 row 5: four parts; no quoted driver phrase mapped to a tool; no 不要反问; length recorded")
    func row5() {
        for search in [false, true] {
            let base = PersonaInstruction.base(PersonaInstruction.base, webSearch: search)
            let parts = ["【你是谁】", "【你有什么】", "【怎么决定】", "【安全】"]
            let at = parts.map { base.range(of: $0)?.lowerBound }
            #expect(at.allSatisfy { $0 != nil })
            #expect(zip(at, at.dropFirst()).allSatisfy { $0! < $1! }, "parts out of order")
            #expect(!base.contains("不要反问"))
            #expect(base.count <= PersonaInstruction.maxBaseCharacters, "\(search) \(base.count)")
            // No 「…」 driver phrase sits in the same sentence as a tool name (a phrase → tool script).
            let tools = ToolCatalog.declarations.map(\.name)
            for sentence in base.split(whereSeparator: { "。\n".contains($0) }) where sentence.contains("「") {
                #expect(!tools.contains { sentence.contains($0) }, "phrase script: \(sentence)")
            }
        }
        // 【安全】 keeps its rules (review of T-031q): never done without a tool result, say what failed, stop when
        // told, short during guidance; and the other-questions rules the old base had.
        let safety = String(PersonaInstruction.base[PersonaInstruction.base.range(of: "【安全】")!.lowerBound...])
        for rule in ["没有调用工具或工具失败时，绝不能说已经做好了", "没做成的要说", "司机让你停就马上停", "导航正在播报或要转弯时说短一点",
                     "只用这三种语言"] {
            #expect(safety.contains(rule), "\(rule)")
        }
        for rule in ["三到五句", "查不了实时信息", "不编造数字、名字和事实", "只有工具返回的结果才说明事情做成了", "AMBIGUOUS_REFERENT"] {
            #expect(PersonaInstruction.base.contains(rule), "\(rule)")
        }
        // Without web search there is no quoted phrase at all.
        #expect(!PersonaInstruction.base.contains("「"))
    }
}
