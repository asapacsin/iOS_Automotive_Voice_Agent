import Foundation
import Testing
import NovaKit
import NovaPorts
@testable import NovaAgent
@testable import NovaTools

/// F-18 §25 (T-046n): every time question from the phone clock, for any place.
@Suite("T-046n F-18 §25 current_time for any place")
struct CurrentTimeZoneTests {
    /// 2026-11-06 01:15 UTC.
    static let instant = Date(timeIntervalSince1970: 1_793_927_700)
    func f(_ r: ToolResult, _ k: String) -> String? { r.data[k]?.stringValue }
    func run(_ zone: String?, phone: TimeZone = TimeZone(identifier: "Asia/Macau")!) -> ToolResult {
        var args: [String: JSONValue] = ["kind": "current_time"]
        if let zone { args["time_zone"] = .string(zone) }
        return CurrentTime.result(now: Self.instant, zone: phone, arguments: .object(args))
    }

    @Test("T-046n F-18 §25 row 1: Asia/Tokyo is 10:15 上午 2026年11月6日 星期五 +09:00, next names the place")
    func tokyo() {
        let r = run("Asia/Tokyo")
        #expect(r.ok && f(r, "time") == "10:15" && f(r, "period") == "上午" && f(r, "date") == "2026年11月6日")
        #expect(f(r, "weekday") == "星期五" && f(r, "timeZone") == "Asia/Tokyo" && f(r, "utcOffset") == "+09:00")
        #expect(f(r, "next") == "只按 time 和 date 回答，一句话，说出是哪里的时间。")
    }

    @Test("F-18 §25 row 2: Europe/Oslo 02:15 凌晨 +01:00; America/New_York 20:15 晚上 -05:00 2026年11月5日 星期四")
    func osloNewYork() {
        let oslo = run("Europe/Oslo")
        #expect(f(oslo, "time") == "02:15" && f(oslo, "period") == "凌晨" && f(oslo, "utcOffset") == "+01:00")
        #expect(f(oslo, "date") == "2026年11月6日")
        let ny = run("America/New_York")
        #expect(f(ny, "time") == "20:15" && f(ny, "period") == "晚上" && f(ny, "utcOffset") == "-05:00")
        #expect(f(ny, "date") == "2026年11月5日" && f(ny, "weekday") == "星期四")
    }

    @Test("F-18 §25 row 3: no time_zone uses the phone zone (Asia/Macau), next unchanged")
    func phoneZone() {
        let r = run(nil)
        #expect(f(r, "time") == "09:15" && f(r, "timeZone") == "Asia/Macau" && f(r, "utcOffset") == "+08:00")
        #expect(f(r, "next") == "只按 time 和 date 回答，一句话，比如「现在是晚上八点零八分」。")
    }

    @Test("F-18 §25 row 4: bad zones are INVALID_ARGUMENT with the item 2 advice; where/day still INVALID_ARGUMENT")
    func badZones() {
        for z in ["asia/tokyo", "仙台", "UTC+9", ""] {
            let r = run(z)
            #expect(!r.ok && r.code == .invalidArgument, "\(z)")
            #expect(r.advice == CurrentTime.zoneAdvice, "\(z)")
        }
        #expect(CurrentTime.zoneAdvice == "time_zone 要用 IANA 时区名，比如 Asia/Tokyo。")
        for extra in ["where", "day"] {
            let r = CurrentTime.result(now: Self.instant, zone: .current,
                                       arguments: .object(["kind": "current_time", extra: "here"]))
            #expect(!r.ok && r.code == .invalidArgument)
        }
        // A long valid IANA name passes catalog validation.
        #expect(ToolCatalog.validate(ToolCall(id: CallID("c")!, name: "query_live_info",
            arguments: ["kind": "current_time", "time_zone": "America/Argentina/ComodRivadavia"])) == nil)
    }

    static let blocked = ["日本仙台现在时间", "现在澳门时间", "现在澳门的具体时间", "澳门现在的时间", "奥斯陆现在几点", "几点了", "今天是几号"]
    static let allowed = ["香港迪士尼几点关门", "香港迪士尼现在几点关门", "故宫营业时间", "澳门现在的营业时间", "今天油价多少", "上海明天几点日出"]

    @Test("F-18 §25 row 5: current-time queries are blocked: no Qwen call, item 7 advice, search-blocked reason=current_time")
    func blockedQueries() async {
        for q in Self.blocked {
            #expect(CurrentTimeQuery.matches(q), "\(q)")
            let service = ScriptedSearch([.reply(reply("x"))])
            let o = Outcomes()
            let r = await WebSearchExecutor(service: service, clock: SystemClock(), onOutcome: o.add,
                                            now: { nov4 }, zone: { shanghai }).execute(searchCall(q))
            #expect(!r.ok && r.code == .invalidArgument && r.advice == CurrentTimeQuery.advice, "\(q)")
            #expect(service.queries.withLock { $0 }.isEmpty, "\(q)")
            #expect(o.list == [.blocked(reason: "current_time")], "\(q)")
            let line = ConversationRecorder.searchLine(.blocked(reason: "current_time"))
            #expect(line?.kind == "search-blocked" && line?.content == "reason=current_time")
        }
        #expect(CurrentTimeQuery.advice == "现在的时间和日期不用搜索：调用 query_live_info（kind=current_time），别的地方填 time_zone。")
    }

    @Test("F-18 §25 row 6: opening hours, sunrise and prices are not blocked and go to Qwen")
    func allowedQueries() async {
        for q in Self.allowed {
            #expect(!CurrentTimeQuery.matches(q), "\(q)")
            let service = ScriptedSearch([.reply(reply("x"))])
            _ = await WebSearchExecutor(service: service, clock: SystemClock(), now: { nov4 }, zone: { shanghai })
                .execute(searchCall(q))
            #expect(service.queries.withLock { $0 }.count == 1, "\(q)")
        }
    }

    @Test("F-18 §25 row 7: catalog, persona and web_search texts as items 1, 4, 5, 6; base within the limit")
    func texts() throws {
        let spec = try #require(ToolCatalog.specs.first { $0.declaration.name == "query_live_info" })
        #expect(spec.declaration.parametersJSONSchema["properties"]?["time_zone"]
            == ["type": "string", "description": "IANA 时区名（例如 Asia/Tokyo、Europe/Oslo）。不填就是手机所在的时区。"])
        #expect(spec.declaration.description.contains("current_time：任何地方现在的时间、日期、星期，如「现在几点」「仙台现在几点」「今天几号」；不是手机所在地时填 time_zone。只按返回结果回答，绝不自己猜时间。"))
        // §26 item 8 appends the forecast sentence after this one.
        #expect(ToolCatalog.webSearchSpec.declaration.description.hasSuffix("不用于查现在的时间、日期、星期（用 query_live_info 的 current_time）。不用于查现在的气温或10天内的天气预报（用 query_live_info 的 weather）。"))
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let base = PersonaInstruction.base(for: mode)
            #expect(base.contains("9. 问现在几点、今天几号、星期几，不管问哪里（包括澳门和外国城市）：调用 query_live_info（kind=current_time），不是手机所在地就填 time_zone（IANA 时区名，比如仙台 Asia/Tokyo）。只按返回的结果回答，不要用 web_search 查时间，不要自己猜。"))
            for search in [false, true] {
                let text = PersonaInstruction.base(base, webSearch: search)
                #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(search) \(text.count)")
            }
        }
    }
}
