import Foundation
import Synchronization
import Testing
import NovaKit
import NovaPorts
@testable import NovaAgent
@testable import NovaTools

/// 2026-11-04 08:00 in Asia/Shanghai.
let nov4 = Date(timeIntervalSince1970: 1_793_750_400)
let shanghai = TimeZone(identifier: "Asia/Shanghai")!

func day(_ y: Int, _ m: Int, _ d: Int) -> SearchDate.Day { SearchDate.Day(year: y, month: m, day: d) }

/// An executor on the phone date 2026-11-04 with `destination`, collecting its outcomes.
func searcher(_ service: ScriptedSearch, destination: String? = nil,
              collect: (@Sendable (WebSearchOutcome) -> Void)? = nil) -> WebSearchExecutor {
    WebSearchExecutor(service: service, clock: SystemClock(), onOutcome: collect ?? { _ in },
                      now: { nov4 }, zone: { shanghai }, destination: { destination })
}

final class Outcomes: @unchecked Sendable {
    let all = Mutex<[WebSearchOutcome]>([])
    var add: @Sendable (WebSearchOutcome) -> Void { { o in self.all.withLock { $0.append(o) } } }
    var list: [WebSearchOutcome] { all.withLock { $0 } }
    var end: WebSearchOutcome? { list.last(where: isEnd) }
    var dates: [WebSearchOutcome] { list.filter { if case .date = $0 { true } else { false } } }
    var places: [WebSearchOutcome] { list.filter { if case .place = $0 { true } else { false } } }
}

func reply(_ answer: String) -> WebSearchReply {
    WebSearchReply(answer: answer, sources: [WebSearchSource(title: "t", host: "weather.com.cn")])
}

@Suite("T-046f F-18 §18 the record shows what went to Qwen and what came back")
struct SearchRecordTests {
    func lines(_ event: RecordEvent) -> [String] {
        var r = ConversationRecorder()
        return r.add(event, atMs: 5)
    }

    @Test("Rows 1, 5: request and response lines; parser counts; an error reply")
    func exchangeLines() {
        let x = WebSearchExchange(attempt: 1, requestBody: #"{"model":"qwen3.7-flash"}"#, status: 200, ms: 812, bytes: 40,
                                  responseBody: "data:{}", error: nil, urlError: nil, chunks: 3, answerChars: 12,
                                  sources: 2, searchCount: 1)
        #expect(lines(.searchExchange(x)) == [
            #"5 search-request attempt=1 body={"model":"qwen3.7-flash"}"#,
            "5 search-response attempt=1 status=200 ms=812 bytes=40 chunks=3 answerChars=12 sources=2 searchCount=1 body=data:{}",
        ])
        let none = WebSearchExchange(attempt: 2, requestBody: "{}", status: 200, ms: 1, bytes: 0, responseBody: "",
                                     error: nil, urlError: nil)
        #expect(lines(.searchExchange(none)).last?.contains("searchCount=none") == true)
        for (error, code, text) in [("timeout", -1001, "-1001"), ("network", -1009, "-1009"), ("cancelled", nil as Int?, "none")] {
            let failed = WebSearchExchange(attempt: 1, requestBody: "{}", status: nil, ms: 9, bytes: 0, responseBody: nil,
                                           error: error, urlError: code)
            #expect(lines(.searchExchange(failed)).last == "5 search-response attempt=1 error=\(error) ms=9 urlError=\(text)")
        }
    }

    @Test("Row 3, item 3: result lines; header searchKey saved / missing, none with the setting off")
    func resultLines() {
        #expect(lines(.searchOutcome(.used(ms: 900, attempts: 1, query: "q", answer: "小雨", sources: ["a.com", "b.com"])))
            == ["5 search-result ok ms=900 attempts=1 answer=小雨 sources=a.com,b.com"])
        #expect(lines(.searchOutcome(.failed(reason: "no_key", ms: 0)))
            == ["5 search-result failed reason=no_key ms=0 code=none"])
        #expect(lines(.searchOutcome(.failed(reason: "http_403", ms: 50, code: "AllocationQuota.FreeTierOnly")))
            == ["5 search-result failed reason=http_403 ms=50 code=AllocationQuota.FreeTierOnly"])
        let header = { (key: Bool?) in
            RecordHeader(appVersion: "1", comfortMode: "table", interruptible: false, speakingStyle: "d",
                         webSearch: key != nil, searchKey: key).lines
        }
        #expect(header(true).last == "searchKey saved")
        #expect(header(false).last == "searchKey missing")
        #expect(header(nil).last == "webSearch off")
    }

    @Test("Row 6: a 100,000-character body keeps the first 8,000 and the last 24,000")
    func cut() {
        let body = String(repeating: "a", count: 8_000) + String(repeating: "m", count: 68_000) + String(repeating: "z", count: 24_000)
        let cut = ConversationRecorder.cut(body)
        #expect(cut == String(repeating: "a", count: 8_000) + "…" + String(repeating: "z", count: 24_000))
        let exact = String(repeating: "b", count: 32_000)
        #expect(ConversationRecorder.cut(exact) == exact)
    }

    @Test("Row 3: no key: failed no_key, and the service sent nothing")
    func noKey() async {
        let o = Outcomes()
        let service = ScriptedSearch([.fail(.notConfigured)])
        let result = await searcher(service, collect: o.add).execute(searchCall())
        #expect(!result.ok && result.code == ToolErrorCode.liveInfoUnavailable)
        #expect(o.end == .failed(reason: "no_key", ms: o.end.map { if case .failed(_, let ms, _) = $0 { ms } else { -1 } } ?? -1))
        #expect(service.calls.withLock { $0 } == 1)
    }

    @Test("Row 4: cancelled before or during the request: reason=cancelled, nothing ok")
    func cancelled() async {
        let before = Outcomes()
        let quiet = ScriptedSearch([.reply(grounded)])
        let executor = searcher(quiet, collect: before.add)
        let early = Task {
            while !Task.isCancelled { await Task.yield() }
            return await executor.execute(searchCall())
        }
        early.cancel()
        let r1 = await early.value
        #expect(!r1.ok)
        if case .failed(let reason, _, _)? = before.end { #expect(reason == "cancelled") } else { Issue.record("no outcome") }
        #expect(quiet.calls.withLock { $0 } == 0)

        let during = Outcomes()
        let hang = ScriptedSearch([.hang])
        let running = searcher(hang, collect: during.add)
        let task = Task { await running.execute(searchCall()) }
        while hang.calls.withLock({ $0 }) == 0 { await Task.yield() }
        task.cancel()
        let r2 = await task.value
        #expect(!r2.ok && r2.code == ToolErrorCode.liveInfoUnavailable)
        if case .failed(let reason, _, _)? = during.end { #expect(reason == "cancelled") } else { Issue.record("no outcome") }
    }

    @Test("Row 9: the result to her is the same with the record on and off")
    func sameResult() async {
        let on = await searcher(ScriptedSearch([.reply(grounded)]), collect: Outcomes().add).execute(searchCall())
        let off = await searcher(ScriptedSearch([.reply(grounded)])).execute(searchCall())
        #expect(on == off && on.ok)
    }
}

@Suite("T-046g F-18 §19 the app works out the date of a search")
struct SearchDateTests {
    func resolve(_ q: String, _ now: Date = nov4) -> SearchDate.Resolved { SearchDate.resolve(q, now: now, zone: shanghai) }

    @Test("Row 1: relative words, 大后天 before 后天, across a month end and a year end")
    func relative() {
        for (word, d) in [("今天", 4), ("今日", 4), ("明天", 5), ("明日", 5), ("后天", 6), ("大后天", 7)] {
            #expect(resolve("上海\(word)天气").target == day(2026, 11, d), "\(word)")
        }
        let nov30 = Date(timeIntervalSince1970: 1_795_996_800)  // 2026-11-30 08:00 Shanghai
        #expect(resolve("后天天气", nov30).target == day(2026, 12, 2))
        let dec31 = Date(timeIntervalSince1970: 1_798_675_200)  // 2026-12-31 08:00 Shanghai
        #expect(resolve("明天天气", dec31).target == day(2027, 1, 1))
        #expect(resolve("大后天天气", dec31).target == day(2027, 1, 3))
    }

    @Test("Row 2: the bracket; written dates unchanged; two days or 周五 have no target")
    func rewrite() {
        let a = resolve("上海后天天气怎么样")
        #expect(a.query == "上海后天（2026年11月6日）天气怎么样" && a.added && a.target == day(2026, 11, 6))
        let b = resolve("2026年11月6日上海天气")
        #expect(b.query == "2026年11月6日上海天气" && !b.added && b.target == day(2026, 11, 6))
        let c = resolve("上海后天11月6日天气")
        #expect(c.query == "上海后天11月6日天气" && !c.added && c.target == day(2026, 11, 6))
        let d = resolve("今天和明天的天气")
        #expect(d.query == "今天和明天的天气" && d.target == nil && !d.added)
        let e = resolve("上海周五天气")
        #expect(e.query == "上海周五天气" && e.target == nil)
        #expect(SearchDate.check("11月3日晴", d, zone: shanghai) == .skipped)
        #expect(resolve("上海6号天气").target == nil)  // a bare 号 without 月 is not a date
        #expect(resolve("11月6号天气").target == day(2026, 11, 6))
    }

    @Test("Row 3: a passed date with no year is next year's; the target follows the phone's date at midnight")
    func years() {
        let dec31 = Date(timeIntervalSince1970: 1_798_675_200)
        #expect(resolve("12月30日天气", dec31).target == day(2027, 12, 30))
        let late = Date(timeIntervalSince1970: 1_793_807_940)  // 2026-11-04 23:59 Shanghai
        let early = Date(timeIntervalSince1970: 1_793_808_060)  // 2026-11-05 00:01 Shanghai
        #expect(resolve("明天天气", late).target == day(2026, 11, 5))
        #expect(resolve("明天天气", early).target == day(2026, 11, 6))
    }

    @Test("Answer dates: single days, ranges in both forms, 号")
    func answerDates() {
        let r = resolve("上海后天天气")
        #expect(SearchDate.check("11月6日小雨", r, zone: shanghai) == .match)
        #expect(SearchDate.check("11月6号小雨", r, zone: shanghai) == .match)
        #expect(SearchDate.check("11月5日至7日有雨", r, zone: shanghai) == .match)
        #expect(SearchDate.check("11月5日到11月7日有雨", r, zone: shanghai) == .match)
        #expect(SearchDate.check("11月5日阴", r, zone: shanghai) == .mismatch)
        #expect(SearchDate.check("小雨，16到21度", r, zone: shanghai) == .noDate)
        #expect(SearchDate.check("11月3日晴", resolve("今天油价"), zone: shanghai) == .skipped)
    }

    @Test("Rows 4-5: the rewritten query is sent and retried; two wrong dates fail wrong_date without the text")
    func wrongDate() async {
        let o = Outcomes()
        let service = ScriptedSearch([.reply(reply("上海11月5日阴，14到19度")), .reply(reply("上海11月5日阴，14到19度"))])
        let result = await searcher(service, collect: o.add).execute(searchCall("上海后天天气怎么样"))
        #expect(!result.ok && result.code == ToolErrorCode.liveInfoUnavailable)
        #expect(!"\(result)".contains("11月5日"))
        #expect(service.calls.withLock { $0 } == 2)
        #expect(service.queries.withLock { $0 } == Array(repeating: "上海后天（2026年11月6日）天气怎么样", count: 2))
        if case .failed(let reason, _, _)? = o.end { #expect(reason == "wrong_date") } else { Issue.record("no outcome") }
        #expect(o.dates == Array(repeating: .date(query: "上海后天天气怎么样", target: "2026-11-06", added: true, check: .mismatch), count: 2))
    }

    @Test("Row 6: passes, target_date and the date next only for future days")
    func passes() async throws {
        let retry = ScriptedSearch([.reply(reply("11月5日阴")), .reply(reply("11月6日小雨"))])
        let o = Outcomes()
        let ok = await searcher(retry, collect: o.add).execute(searchCall("上海后天天气怎么样"))
        #expect(ok.ok && ok.data["target_date"] == "11月6日" && ok.data["next"] == .string(WebSearchExecutor.dateNext))
        let checks: [SearchDate.Check] = o.dates.map { if case .date(_, _, _, let c) = $0 { c } else { .skipped } }
        #expect(checks == [.mismatch, .match])
        guard case .used(_, let attempts, _, _, _)? = o.end else { Issue.record("no outcome"); return }
        #expect(attempts == 2)
        for answer in ["11月5日至7日有雨", "11月6号小雨", "小雨"] {
            let r = await searcher(ScriptedSearch([.reply(reply(answer))])).execute(searchCall("上海后天天气怎么样"))
            #expect(r.ok && r.data["target_date"] == "11月6日", "\(answer)")
        }
        let today = await searcher(ScriptedSearch([.reply(reply("11月3日油价下调"))])).execute(searchCall("今天油价多少"))
        #expect(today.ok && today.data["target_date"] == nil && today.data["next"] == .string(WebSearchExecutor.next))
    }

    @Test("Item 3: the system text sentence is in the client (NovaRealtime row 4); the log line has no words")
    func logFields() {
        // AgentRuntime logs `webSearchDate added=<yes|no> check=<...>` from these fields only.
        let o = WebSearchOutcome.date(query: "上海后天天气", target: "2026-11-06", added: true, check: .match)
        guard case .date(_, _, let added, let check) = o else { return }
        #expect(added && check.rawValue == "match")
        #expect(SearchDate.Check.noDate.rawValue == "no_date")
    }
}

@Suite("T-046h F-18 §20 every call to Qwen must search")
struct ForcedSearchTests {
    @Test("Row 2: no sources twice with forced search: two requests, no_sources, no answer text")
    func noSources() async {
        let o = Outcomes()
        let bare = WebSearchReply(answer: "凭记忆：油价7元", sources: [])
        let service = ScriptedSearch([.reply(bare), .reply(bare)])
        let result = await searcher(service, collect: o.add).execute(searchCall("今天油价多少"))
        #expect(!result.ok && service.calls.withLock { $0 } == 2 && !"\(result)".contains("凭记忆"))
        if case .failed(let reason, _, _)? = o.end { #expect(reason == "no_sources") } else { Issue.record("no outcome") }
    }

    @Test("Row 3: HTTP 400 with a code: one request, the code reported, LIVE_INFO_UNAVAILABLE")
    func refused() async {
        let o = Outcomes()
        let service = ScriptedSearch([.fail(.http(400, code: "InvalidParameter")), .reply(grounded)])
        let result = await searcher(service, collect: o.add).execute(searchCall("今天油价多少"))
        #expect(!result.ok && result.code == ToolErrorCode.liveInfoUnavailable && service.calls.withLock { $0 } == 1)
        if case .failed(let reason, _, let code)? = o.end { #expect(reason == "http_400" && code == "InvalidParameter") }
        else { Issue.record("no outcome") }
    }
}

@Suite("T-046i F-18 §21 the destination in the search")
struct SearchPlaceTests {
    let dest = "横琴文化艺术中心"

    @Test("Row 5: 目的地 and 终点 become the name, before the date; no destination, unchanged")
    func substitute() async {
        for (q, sent) in [("目的地几点关门", "横琴文化艺术中心几点关门"), ("终点几点关门", "横琴文化艺术中心几点关门"),
                          ("横琴文化艺术中心目的地几点关门", "横琴文化艺术中心目的地几点关门"),
                          ("目的地明天几点关门", "横琴文化艺术中心明天（2026年11月5日）几点关门")] {
            let service = ScriptedSearch([.reply(reply("周三9点到17点"))])
            let o = Outcomes()
            _ = await searcher(service, destination: dest, collect: o.add).execute(searchCall(q))
            #expect(service.queries.withLock { $0 } == [sent], "\(q)")
            guard case .place(let query, _, let added, _)? = o.places.first else { Issue.record("no place"); continue }
            #expect(query == q && added == (q != "横琴文化艺术中心目的地几点关门"))
        }
        let none = ScriptedSearch([.reply(reply("x"))])
        _ = await searcher(none).execute(searchCall("目的地几点关门"))
        #expect(none.queries.withLock { $0 } == ["目的地几点关门"])
        #expect(SearchPlace.substitute("目的地几点关门", destination: "终点站咖啡").query == "终点站咖啡几点关门")
    }

    @Test("Row 6: hints only with a destination, a query without its name, and an hours word")
    func hints() async {
        let ok = await searcher(ScriptedSearch([.reply(reply("ODD晚上10点关门"))]), destination: dest).execute(searchCall("ODD几点关门"))
        #expect(ok.ok && ok.data["current_destination"] == .string(dest))
        #expect(ok.data["next"] == .string(WebSearchExecutor.next + WebSearchExecutor.placeNext(dest)))
        let failed = await searcher(ScriptedSearch([.fail(.http(503)), .fail(.http(503))]), destination: dest)
            .execute(searchCall("ODD几点关门"))
        #expect(!failed.ok && failed.code == ToolErrorCode.liveInfoUnavailable)
        #expect("\(failed)".contains(WebSearchExecutor.placeAdvice(dest)))
        for (q, d) in [("美元汇率多少", dest as String?), ("横琴文化艺术中心几点关门", dest), ("ODD几点关门", nil)] {
            let o = Outcomes()
            let r = await searcher(ScriptedSearch([.reply(reply("x"))]), destination: d, collect: o.add).execute(searchCall(q))
            #expect(r.data["current_destination"] == nil && r.data["next"] == .string(WebSearchExecutor.next), "\(q)")
            guard case .place(_, _, _, let hint)? = o.places.first else { Issue.record("no place"); continue }
            #expect(!hint)
        }
        // The name is cleaned before use (item 1).
        #expect(SearchPlace.clean("「横琴」[文化]{中心}\n") == "横琴文化中心")
        #expect(SearchPlace.clean(String(repeating: "长", count: 80))?.count == 60)
        #expect(SearchPlace.clean(" 「」 ") == nil && SearchPlace.clean(nil) == nil)
    }

    @Test("Row 7: record and log fields; the log has no words")
    func recordLines() {
        var r = ConversationRecorder()
        #expect(r.add(.searchOutcome(.place(query: "目的地几点关门", sent: "横琴文化艺术中心几点关门", added: true, hint: false)), atMs: 1)
            == ["1 search-place query=目的地几点关门 sent=横琴文化艺术中心几点关门 added=yes hint=no"])
        #expect(r.add(.searchOutcome(.date(query: "后天天气", target: nil, added: false, check: .skipped)), atMs: 2)
            == ["2 search-date query=后天天气 target=none added=no check=skipped"])
        #expect(r.add(.contextNote(destination: dest), atMs: 3) == ["3 context-note destination=横琴文化艺术中心"])
        #expect(r.add(.contextNote(destination: nil), atMs: 4) == ["4 context-note destination=none"])
        #expect(DiagnosticEvent.destinationNote.logLine == "destinationNote")
    }
}

@Suite("T-046i F-18 §21 item 2 silent destination notes")
struct DestinationNoteTests {
    let dest = "横琴文化艺术中心"

    func notes(_ effects: [AgentEffect]) -> [String] {
        effects.compactMap {
            if case .provider(.text(let turns, turnComplete: false)) = $0 { turns.first?.text } else { nil }
        }
    }

    func drive(notes: Bool = true) -> Drive {
        var d = Drive()
        d.state = AgentState(truthfulness: .session(webSearch: true), destinationNotes: notes)
        return d
    }

    @Test("Row 2: waits while her reply is open and a tool runs; latest note only; user role, turnComplete false")
    func waitsForIdle() {
        var d = drive()
        d.connect()
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        let t1 = TurnID(1)
        d.realtime(.responseStarted(t1))
        let call = searchCall("目的地几点关门")
        d.realtime(.toolCalls(t1, [call]))
        #expect(notes(d.send(.destination("旧地方"))).isEmpty)
        #expect(notes(d.send(.destination(dest))).isEmpty)
        #expect(notes(d.send(.toolFinished(t1, call, .success(["answer": "x"])))).isEmpty)
        let done = d.realtime(.responseDone(t1, outcome: .completed))
        // The tool result owes an answer: still not idle.
        #expect(notes(done).isEmpty)
        let t2 = TurnID(2)
        d.realtime(.responseStarted(t2))
        let sent = d.realtime(.responseDone(t2, outcome: .completed))
        #expect(notes(sent) == [AgentState.destinationNote(dest)])
        #expect(sent.contains(.diagnostic(.destinationNote)))
        #expect(sent.contains(.provider(.text([TextTurn(role: .user, text: AgentState.destinationNote(dest))], turnComplete: false))))
        #expect(notes(d.effects).count == 1)
        // The driver speaking holds a new note back.
        d.send(.speechStarted(recentSpeech: true))
        #expect(notes(d.send(.destination("新地方"))).isEmpty)
    }

    @Test("Row 3: a completed turn sends one; no turn, no duplicate; reconnect sends; the end note once")
    func when() {
        var d = drive()
        d.connect()
        #expect(notes(d.send(.destination(dest))) == [AgentState.destinationNote(dest)])
        // A second idle moment with no turn: nothing.
        #expect(notes(d.send(.manoeuvreDistance(meters: 300))).isEmpty)
        // A completed turn: one note.
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(1)))
        #expect(notes(d.realtime(.responseDone(TurnID(1), outcome: .completed))) == [AgentState.destinationNote(dest)])
        #expect(notes(d.send(.manoeuvreDistance(meters: 200))).isEmpty)
        // Reconnect: a note on the new socket.
        #expect(notes(d.realtime(.setupComplete)) == [AgentState.destinationNote(dest)])
        // Exit navigation: the end note once, then none.
        #expect(notes(d.send(.destination(nil))) == [AgentState.destinationNote(nil)])
        #expect(notes(d.send(.destination(nil))).isEmpty)
        d.send(.speechStarted(recentSpeech: true))
        d.send(.speechStopped)
        d.realtime(.responseStarted(TurnID(2)))
        #expect(notes(d.realtime(.responseDone(TurnID(2), outcome: .completed))).isEmpty)
        #expect(AgentState.destinationNote(dest) == "[系统] 现在的导航目的地是「横琴文化艺术中心」。司机没说清地点时，指的可能是这里。这句不用回答。")
        #expect(AgentState.destinationNote(nil) == "[系统] 导航已结束，现在没有目的地。这句不用回答。")
    }

    @Test("Row 4: notes off: none; the search results do not depend on them")
    func off() {
        var d = drive(notes: false)
        d.connect()
        d.send(.destination(dest))
        d.realtime(.setupComplete)
        d.send(.destination(nil))
        #expect(notes(d.effects).isEmpty)
        // An end note with no destination note before it is not sent.
        var early = drive()
        early.connect()
        early.send(.speechStarted(recentSpeech: true))
        early.send(.destination(dest))
        early.send(.destination(nil))
        early.send(.speechStopped)
        early.realtime(.responseStarted(TurnID(1)))
        early.realtime(.responseDone(TurnID(1), outcome: .completed))
        #expect(notes(early.effects).isEmpty)
        var plain = Drive()
        plain.connect()
        plain.send(.destination(dest))
        #expect(notes(plain.effects).isEmpty)
    }

    @Test("Row 7: the new sentence is in both comfort modes, within maxBaseCharacters")
    func instruction() {
        for mode in [ToolCatalog.ComfortMode.table, .model] {
            let base = PersonaInstruction.base(for: mode)
            let text = PersonaInstruction.base(base, webSearch: true)
            #expect(text.contains("问目的地或屏幕上某地的营业时间：用它的名字查。地名听不清或不像真实地点：不要查，问一句「是问X吗？」（X 是目的地）；没导航就问是哪里。"))
            #expect(!text.contains("问目的地或屏幕上某个地点的营业时间"))
            #expect(text.count <= PersonaInstruction.maxBaseCharacters, "\(mode) \(text.count)")
            #expect(PersonaInstruction.base(base, webSearch: false) == base)
        }
    }
}
