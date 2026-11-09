import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaAgent
@testable import NovaTools

/// F-18 §27 items 5-6 (T-046p, in T-046q): 现在几度 is never searched, and her texts.
@Suite("F-18 §27 the temperature now is not searched")
struct CurrentTemperatureSearchTests {
    /// 2026-11-06 12:00 in Asia/Shanghai.
    static let now = Date(timeIntervalSince1970: 1_793_937_600)
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test("F-18 §27 row 5: 奥斯陆现在几度 and 东京现在多少度 are blocked with no Qwen call; 下个月澳门温度几度 goes to Qwen")
    func row5() async {
        for q in ["奥斯陆现在几度", "东京现在多少度"] {
            let service = ScriptedSearch([.reply(grounded)])
            let outcomes = Mutex<[WebSearchOutcome]>([])
            let ex = WebSearchExecutor(service: service, clock: ManualClock(), onOutcome: { o in outcomes.withLock { $0.append(o) } },
                                       now: { Self.now }, zone: { Self.zone })
            let r = await ex.execute(searchCall(q))
            #expect(r.code == .invalidArgument, "\(q)")
            #expect(r.advice == "16天内的天气预报不用搜索：调用 query_live_info（kind=weather），国外地点用英文名并填 country。")
            #expect(service.calls.withLock { $0 } == 0)
            #expect(outcomes.withLock { $0 } == [.blocked(reason: "weather")])
        }
        let service = ScriptedSearch([.reply(grounded)])
        let ex = WebSearchExecutor(service: service, clock: ManualClock(), now: { Self.now }, zone: { Self.zone })
        _ = await ex.execute(searchCall("下个月澳门温度几度"))
        #expect(service.calls.withLock { $0 } == 1)
        #expect(WeatherForecastQuery.weatherWords.suffix(2) == ["几度", "多少度"])
    }

    @Test("F-18 §27 row 6: catalog, officialFirst, web_search description and persona are exactly item 5; base within the limit")
    func row6() {
        #expect(ToolCatalog.weatherPart == "weather：任何地方现在的天气，和今后16天内任何一天、上午下午晚上的天气预报。「现在天气怎么样」「外面几度」→where=here, day=now；「今天天气怎么样」→day=today；「下午会下雨吗」→part=afternoon；「目的地会下雨吗」→destination；「珠海天气」→珠海；明天、后天、大后天用 day；说几号或星期几用 date（yyyy-MM-dd），不知道今天几号先调用 current_time；国外地点用英文名并填 country：「奥斯陆11月12日天气」→where=Oslo, country=NO, date=2026-11-12。")
        #expect(ToolCatalog.officialFirst == "现在的气温和天气预报（今后16天内）只用 query_live_info，不用 web_search。地点营业时间先用 query_live_info；它没有数据时再用 web_search。")
        #expect(ToolCatalog.webSearchSpec.declaration.description.hasSuffix("不用于查现在的气温或16天内的天气预报（用 query_live_info 的 weather）。"))
        let s = PersonaInstruction.webSearchSentence
        #expect(s.contains("用返回的 answer 回答，一两句话。现在的气温和天气预报用 query_live_info（今后16天内，国外地点用英文名并填 country）。问很久以后的天气时"))
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let d = ToolCatalog.declarations(for: mode, webSearch: true).first { $0.name == "query_live_info" }!
            #expect(d.description.contains(ToolCatalog.weatherPart) && d.description.contains(ToolCatalog.officialFirst))
            for search in [false, true] {
                let text = PersonaInstruction.base(PersonaInstruction.base(for: mode), webSearch: search)
                #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(search) \(text.count)")
            }
        }
    }
}
