import Testing
@testable import NovaAgent
@testable import NovaTools

/// F-12 §18 rows 1–2 and §19 row 1.
@Suite("Tool purpose (F-12 §18, §19)")
struct ToolPurposeTests {
    static func model(_ name: String) -> String? {
        ToolCatalog.declarations.first { $0.name == name }?.description
    }
    /// The Android text, before the iOS purpose sentence (F-12 §18 item 1).
    static func android(_ name: String) -> String? {
        ToolCatalog.generatedSpecs.first { $0.name == name }?.declaration.description
    }

    @Test("§18 row 1: window and climate begin with the purpose; the rest of the window text is Android's")
    func modelDeclarations() throws {
        let windowHead = "控制车窗（模拟）。开窗能换入车外空气、散掉车内异味；关窗能隔绝噪音和车外空气。"
        let window = try #require(Self.model("control_window"))
        let windowAndroid = try #require(Self.android("control_window"))
        #expect(window.hasPrefix(windowHead))
        #expect("控制车窗（模拟）。" + String(window.dropFirst(windowHead.count)) == windowAndroid)

        let climateHead = "控制空调（模拟）。空调主要调节温度，风量让车内空气流动。"
        let climate = try #require(Self.model("control_climate"))
        #expect(climate.hasPrefix(climateHead))
        #expect(climate.dropFirst(climateHead.count).hasPrefix("「打开/关闭空调」power_on/power_off；"))
        #expect(!window.contains("闷") && !climate.contains("闷") && !window.contains("虫") && !climate.contains("虫"))
    }

    @Test("F-09b §3 item 3, §12 item 4: rule 5 rewritten; the sleepy sentence is §12's, not F-12 §20's silence")
    func sleepyRule() {
        let rule = PersonaInstruction.comfortRule
        #expect(!rule.contains("不要说话，不回应"))
        #expect(!rule.contains("提神") && !rule.contains("有异味、困"))
        #expect(!PersonaInstruction.base.contains("车内场景（有蚊子、闷）"))
        #expect(!PersonaInstruction.base.contains("闷、困"))
        #expect(!PersonaInstruction.base.contains("有点热、太热了：调低一度温度"))
        #expect(PersonaInstruction.base.contains("座位有点高：座椅降低一级。"))
    }
}
