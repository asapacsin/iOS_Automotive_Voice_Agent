import Testing
@testable import NovaAgent
@testable import NovaTools

/// F-12 §18 rows 1–2 and §19 row 1.
@Suite("Tool purpose (F-12 §18, §19)")
struct ToolPurposeTests {
    static func model(_ name: String) -> String? {
        ToolCatalog.declarations(for: .model).first { $0.name == name }?.description
    }
    static func table(_ name: String) -> String? {
        ToolCatalog.declarations.first { $0.name == name }?.description
    }

    @Test("§18 row 1: model-mode window and climate begin with the purpose; the rest is today's")
    func modelDeclarations() throws {
        let windowHead = "控制车窗（模拟）。开窗能换入车外空气、散掉车内异味；关窗能隔绝噪音和车外空气。"
        let window = try #require(Self.model("control_window"))
        let windowToday = try #require(Self.table("control_window"))
        #expect(window.hasPrefix(windowHead))
        #expect("控制车窗（模拟）。" + String(window.dropFirst(windowHead.count)) == windowToday)

        let climateHead = "控制空调（模拟）。空调主要调节温度，风量让车内空气流动。"
        let climate = try #require(Self.model("control_climate"))
        #expect(climate.hasPrefix(climateHead))
        #expect(climate.dropFirst(climateHead.count).hasPrefix("「打开/关闭空调」power_on/power_off；"))
        #expect(!window.contains("闷") && !climate.contains("闷") && !window.contains("虫") && !climate.contains("虫"))
    }

    @Test("§18 row 2: table declarations and every other model-mode tool unchanged")
    func othersUnchanged() {
        #expect(ToolCatalog.declarations(for: .table) == ToolCatalog.declarations)
        #expect(Self.table("control_window")?.contains("开窗能换入") == false)
        #expect(Self.table("control_climate")?.contains("空调主要调节温度") == false)
        let changed: Set = ["control_window", "control_climate"]
        for d in ToolCatalog.declarations(for: .model) where !changed.contains(d.name) && d.name != "get_vehicle_state" {
            #expect(ToolCatalog.declarations.first { $0.name == d.name } == d, "\(d.name) changed")
        }
    }

    @Test("F-12 §20 row 1: sleepy driver gets no action and no reply in both modes")
    func sleepyRule() {
        let rule = PersonaInstruction.modelComfortRule
        #expect(rule.contains("司机只是说累、犯困：不要调用任何工具，不要操作车辆，也不要说话，不回应。"))
        #expect(!rule.contains("提神"))
        #expect(!rule.contains("服务区"))
        #expect(!rule.contains("有异味、困"))
        #expect(PersonaInstruction.base(for: .table) == PersonaInstruction.base)
        #expect(PersonaInstruction.base.contains("车内场景（有蚊子、闷）"))
        #expect(!PersonaInstruction.base.contains("闷、困"))
        #expect(PersonaInstruction.base.contains("5. 有点热、太热了：调低一度温度。"))
    }
}
