import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaAgent
@testable import NovaTools

/// F-18 §26 rows 8-9 (T-046o): the item 9 check before search, and her texts.
@Suite("T-046o F-18 §26 forecasts are not searched")
struct ForecastSearchTests {
    /// 2026-11-06 12:00 in Asia/Shanghai.
    static let now = Date(timeIntervalSince1970: 1_793_937_600)
    static let zone = TimeZone(identifier: "Asia/Shanghai")!

    @Test("F-18 §26 row 08: forecasts within 16 days are blocked with no Qwen call; months, far dates, 下周, oil go to Qwen")
    func row08() async {
        for q in ["上海天气怎么样", "奥斯陆11月12日天气", "横琴后天会下雨吗"] {
            let service = ScriptedSearch([.reply(grounded)])
            let outcomes = Mutex<[WebSearchOutcome]>([])
            let ex = WebSearchExecutor(service: service, clock: ManualClock(), onOutcome: { o in outcomes.withLock { $0.append(o) } },
                                       now: { Self.now }, zone: { Self.zone })
            let r = await ex.execute(searchCall(q))
            #expect(r.code == .invalidArgument, "\(q)")
            #expect(r.advice == "16天内的天气预报不用搜索：调用 query_live_info（kind=weather），国外地点用英文名并填 country。")
            #expect(service.calls.withLock { $0 } == 0)
            #expect(outcomes.withLock { $0 } == [.blocked(reason: "weather")])
            #expect(ConversationRecorder.searchLine(WebSearchOutcome.blocked(reason: "weather"))?.kind == "search-blocked")
        }
        for q in ["下个月澳门温度几度", "2026年12月25日上海天气", "上海下周三天气", "今天油价多少"] {
            #expect(!WeatherForecastQuery.matches(q, now: Self.now, zone: Self.zone), "\(q)")
            let service = ScriptedSearch([.reply(grounded)])
            let ex = WebSearchExecutor(service: service, clock: ManualClock(), now: { Self.now }, zone: { Self.zone })
            _ = await ex.execute(searchCall(q))
            #expect(service.calls.withLock { $0 } == 1, "\(q)")
        }
        // The window ends 15 days after the phone's today.
        #expect(WeatherForecastQuery.matches("上海11月21日天气", now: Self.now, zone: Self.zone))
        #expect(!WeatherForecastQuery.matches("上海11月22日天气", now: Self.now, zone: Self.zone))
    }

    @Test("F-18 §26 row 09: officialFirst, web_search description and persona are exactly item 8; base within the limit")
    func row09() {
        #expect(ToolCatalog.officialFirst == "现在的气温和天气预报（今后16天内）只用 query_live_info，不用 web_search。地点营业时间先用 query_live_info；它没有数据时再用 web_search。")
        let ws = ToolCatalog.webSearchSpec.declaration.description
        #expect(ws == "查网上的信息：新闻、营业时间、价格、油价、汇率、比分等会变的信息。query 写完整的中文问题，带上地点和日期。不用于控制车辆。只按返回的 answer 回答。不用于查现在的时间、日期、星期（用 query_live_info 的 current_time）。不用于查现在的气温或16天内的天气预报（用 query_live_info 的 weather）。")
        let s = PersonaInstruction.webSearchSentence
        #expect(s.contains("（新闻、营业时间、价格、油价、汇率、比分等）") && !s.contains("任何一天的天气"))
        #expect(s.contains("现在的气温和天气预报用 query_live_info（今后16天内，国外地点用英文名并填 country）。问很久以后的天气时"))
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let on = ToolCatalog.declarations(for: mode, webSearch: true).first { $0.name == "query_live_info" }!
            #expect(on.description.contains(ToolCatalog.officialFirst))
            let text = PersonaInstruction.base(PersonaInstruction.base(for: mode), webSearch: true)
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(text.count)")
        }
    }
}
