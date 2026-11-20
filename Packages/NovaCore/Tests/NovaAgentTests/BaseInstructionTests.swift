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
        // Without web search there is no quoted phrase at all.
        #expect(!PersonaInstruction.base.contains("「"))
    }
}
