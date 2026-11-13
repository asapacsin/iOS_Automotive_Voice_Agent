import Testing
@testable import NovaAgent
@testable import NovaTools

/// F-13a §10 rows 13–15 (T-032i): which build is installed, which tools were declared, 音量 in her strict rules.
@Suite("T-032i F-13a §10 build stamp, declared tools, 音量 rule")
struct BuildStampTests {
    func header(_ app: String, tools: [String]? = nil) -> RecordHeader {
        RecordHeader(appVersion: app, comfortMode: "table", interruptible: false, speakingStyle: "default",
                     declaredTools: tools)
    }

    @Test("Row 13: header with commit b305c60, and with no NovaGitCommit")
    func stamp() {
        #expect(header(BuildStamp.appVersion(short: "0.1.0", build: "1", commit: "b305c60")).lines.first == "app 0.1.0(1) b305c60")
        #expect(header(BuildStamp.appVersion(short: "0.1.0", build: "1", commit: nil)).lines.first == "app 0.1.0(1) unknown")
        #expect(BuildStamp.commit("b305c60aa7e1f3") == "b305c60")
        #expect(BuildStamp.commit("") == "unknown" && BuildStamp.commit("$(NOVA_GIT_COMMIT)") == "unknown")
        #expect(BuildStamp.settingsLabel(short: "0.1.0", commit: "b305c60") == "版本 0.1.0 · b305c60")
        #expect(header("1").lines.allSatisfy { !$0.hasPrefix("tools ") })  // nil writes no line
    }

    @Test("Row 14: both catalogs declare set_volume, and the line says so")
    func declaredTools() {
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let names = ToolCatalog.declarations(for: mode, webSearch: false).map(\.name)
            #expect(header("1", tools: names).lines.last == "tools declared=\(names.count) set_volume=yes", "\(mode)")
        }
        #expect(header("1", tools: ["open_app"]).lines.last == "tools declared=1 set_volume=no")
    }

    @Test("Row 15: both bases name 音量 in the strict list, within maxBaseCharacters; the description starts with its trigger")
    func rule() {
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            for search in [false, true] {
                let text = PersonaInstruction.base(PersonaInstruction.base(for: mode), webSearch: search)
                #expect(text.contains("音乐、音量、"), "\(mode)")
                #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(search) \(text.count)")
            }
        }
        #expect(ToolCatalog.volumeSpec.declaration.description.hasPrefix("司机说音量、声音大小、大声、小声、静音、最大声时一定调用。"))
        #expect(!ToolCatalog.volumeSpec.declaration.description.contains("不是手机音量"))
    }
}
