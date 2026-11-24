import Foundation
import NovaKit
import NovaPorts

// MARK: The loop

public struct EventBrowseRequest: Sendable, Hashable {
    public let cities: [String]
    public let from: EventDay
    public let to: EventDay
    public let kinds: String
    public let today: EventDay
    /// F-18 §38 item 1: the car's city for 「在<城市>」; nil: the first of `cities`.
    public let here: String?
    public init(cities: [String], from: EventDay, to: EventDay, kinds: String, today: EventDay, here: String? = nil) {
        self.here = here
        self.cities = cities
        self.from = from
        self.to = to
        self.kinds = kinds
        self.today = today
    }
}

/// One event the model named, before the date check.
public struct EventCandidate: Sendable, Hashable {
    public let name, start, end, datesText, venue, city, sourceURL: String
}

public struct EventBrowseOutcome: Sendable, Hashable {
    public let kept: [EventEntry]
    public let dropped: Int
    /// The sites of the pages opened.
    public let sites: [String]
    public let steps: Int
    public let tokens: Int
    public let note: String
}

public enum EventBrowseFailure: String, Error, Sendable, Hashable {
    /// F-18 §38 item 7: `timeout` only when the time ran out; `http` a non-200; `json` an answer that does not
    /// parse; `tools` a reply to the last step that still has tool calls.
    case timeout, http, json, tools
}

/// F-18 §35 items 3, 6, 9 (T-046x) and §38 (T-046za): the browse loop, built as the PoC that worked
/// (`scripts/eval/event_browse_poc.py`). The model has two tools, `search` and `open_page`; at most `maxCalls` tool
/// calls and `limit` of time, then code sends the PoC's last-step line with `tool_choice: "none"`. Code keeps only
/// events whose start and end parse from the text of the opened `source_url` page and that overlap the window.
public struct EventBrowseLoop: Sendable {
    public static let maxCalls = 12
    public static let limit = NovaDuration.seconds(180)
    /// §38 item 4: `open_page` sends this much of the page text.
    public static let pageChars = 6000

    // MARK: Texts (§38: the PoC's, word for word; owner-approved exception to the 2026-11-05 rule for this loop only)

    /// §38 item 1 (replaces §35 item 3's ReAct sentence): the PoC's `SYSTEM`; only the date, weekday, city and the
    /// JSON shape (§35 item 3's fields) are filled in.
    public static func system(_ r: EventBrowseRequest) -> String {
        let t = r.today
        return "你是会上网查资料的助手，今天是\(t.year)年\(t.month)月\(t.day)日（周\(weekday(t))），在\(r.here ?? r.cities.first ?? "")。"
            + "你有两个工具：search 搜网页（返回标题、链接、摘要），open_page 打开一个链接读全文。"
            + "像人一样查：换不同说法多搜几次，打开活动列表页、主办方页、票务页读原文，顺着页面里的链接继续找。"
            + "日期只认你打开的页面里写的。查够了就只输出 JSON：" + shape + "。没找到就 events 为空。"
    }

    /// §35 item 3's fields in the PoC's shape (its value texts kept for the dates and the source).
    public static let shape = #"{"events": [{"name": "", "start": "YYYY-MM-DD", "end": "YYYY-MM-DD", "dates_text": "页面里写的日期原文", "venue": "", "city": "", "source_url": "你打开过的、写着这个日期的页面"}], "note": ""}"#

    /// 一 … 日 for Monday … Sunday.
    static func weekday(_ d: EventDay) -> String {
        // 2000-01-03 was a Monday.
        let n = EventDay(year: 2000, month: 1, day: 3)!.days(to: d)
        return ["一", "二", "三", "四", "五", "六", "日"][((n % 7) + 7) % 7]
    }

    /// §38 item 2: the PoC's `QUESTION` with the values filled in.
    public static func question(_ r: EventBrowseRequest) -> String {
        let to = r.to.month == r.from.month && r.to.year == r.from.year ? "\(r.to.day)日" : "\(r.to.month)月\(r.to.day)日"
        let kinds = r.kinds.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultKinds : r.kinds
        return "\(r.from.month)月\(r.from.day)日到\(to)（\(r.from.year)年）\(r.cities.joined(separator: "和"))有什么\(kinds)？只要这几天开放的。"
    }

    /// The PoC's kinds, for a refresh that names none.
    public static let defaultKinds = "展览、漫展、cosplay或AI活动"

    /// §38 item 6: the PoC's last-step line.
    public static let lastStep = "步数用完了，现在按要求只输出 JSON。"

    /// §38 item 3: the PoC's two tools with their descriptions.
    public static let tools: JSONValue = .array([
        ["type": "function", "function": ["name": "search", "description": "搜索网页，返回最多10条结果（标题、链接、摘要）。",
                                          "parameters": ["type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]],
        ["type": "function", "function": ["name": "open_page", "description": "打开一个网页链接，返回页面正文文字（最多6000字）和页面里的链接。",
                                          "parameters": ["type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]]],
    ])

    /// §38 item 4: what `open_page` returns: the page text (whitespace collapsed) cut to `pageChars`, and its links.
    public static func pageResult(_ page: PageText) -> JSONValue {
        ["text": .string(String(page.flatText.prefix(pageChars))),
         "links": .array(page.links.map { ["url": .string($0.url), "text": .string($0.text)] })]
    }

    private let model: any EventChatModel
    private let searcher: any EventSearcher
    private let fetcher: any EventPageFetcher
    private let clock: any NovaClock
    private let now: @Sendable () -> Date
    /// Item 8: after each tool call, the searches and pages so far.
    private let onStep: @Sendable (_ searches: Int, _ pages: Int) -> Void
    /// Item 9: the record lines.
    private let onLine: @Sendable (String) -> Void

    public init(model: any EventChatModel, searcher: any EventSearcher, fetcher: any EventPageFetcher, clock: any NovaClock,
                now: @escaping @Sendable () -> Date = { Date() },
                onStep: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.model = model
        self.searcher = searcher
        self.fetcher = fetcher
        self.clock = clock
        self.now = now
        self.onStep = onStep
        self.onLine = onLine
    }

    public func run(_ r: EventBrowseRequest) async throws(EventBrowseFailure) -> EventBrowseOutcome {
        let started = clock.now
        func ms() -> Int64 { (clock.now - started).milliseconds }
        func left() -> NovaDuration { Self.limit - (clock.now - started) }
        var messages = [EventChatMessage(role: .system, content: Self.system(r)),
                        EventChatMessage(role: .user, content: Self.question(r))]
        var pages: [String: String] = [:]
        var opened: [String] = []
        var calls = 0, searches = 0, tokens = 0
        var final: String?

        func fail(_ why: EventBrowseFailure) -> EventBrowseFailure {
            onLine("events failed reason=\(why.rawValue)")
            return why
        }

        while calls < Self.maxCalls, left() > .zero {
            let reply: EventChatReply
            do { reply = try await model.turn(messages, lastStep: false, timeout: left()) } catch {
                if Task.isCancelled || left() <= .zero || error is CancellationError { throw fail(.timeout) }
                throw fail(.http)
            }
            tokens += reply.tokens ?? 0
            messages.append(EventChatMessage(role: .assistant, content: reply.content, toolCalls: reply.toolCalls))
            guard !reply.toolCalls.isEmpty else {
                final = reply.content
                break
            }
            for call in reply.toolCalls {
                guard calls < Self.maxCalls, left() > .zero else {
                    messages.append(EventChatMessage(role: .tool, content: #"{"error":"limit"}"#, toolCallID: call.id))
                    continue
                }
                calls += 1
                let stepStart = clock.now
                let args = (try? JSONDecoder().decode(JSONValue.self, from: Data(call.arguments.utf8))) ?? .null
                var content = #"{"error":"unknown tool"}"#
                var ok = false
                var kind = "search"
                switch call.name {
                case "search":
                    searches += 1
                    let q = args["query"]?.stringValue ?? ""
                    if let hits = try? await searcher.search(q) {
                        ok = true
                        content = Self.encode(.array(hits.prefix(10).map {
                            ["title": .string($0.title), "url": .string($0.url), "site": .string($0.site)] }))
                    } else {
                        content = #"{"error":"search failed"}"#
                    }
                case "open_page":
                    kind = "open"
                    let url = args["url"]?.stringValue ?? ""
                    if let html = try? await fetcher.open(url) {
                        let page = PageText(html: html)
                        // §38 item 4: the whole text stays with code for §35 item 6's date check.
                        pages[url] = page.title + "\n" + page.text
                        if !opened.contains(url) { opened.append(url) }
                        ok = true
                        content = Self.encode(Self.pageResult(page))
                    } else {
                        content = #"{"error":"not opened"}"#
                    }
                default: break
                }
                messages.append(EventChatMessage(role: .tool, content: content, toolCallID: call.id))
                onLine("events browse step=\(calls) kind=\(kind) ms=\((clock.now - stepStart).milliseconds) ok=\(ok ? "yes" : "no")")
                onStep(searches, opened.count)
            }
        }
        if final == nil {
            // §38 item 6: the PoC's last-step line, with the tools and `tool_choice: "none"`, inside the 180 s.
            messages.append(EventChatMessage(role: .user, content: Self.lastStep))
            let budget = left()
            guard budget > .zero else { throw fail(.timeout) }
            let reply: EventChatReply
            do { reply = try await model.turn(messages, lastStep: true, timeout: budget) } catch {
                if Task.isCancelled || left() <= .zero || error is CancellationError { throw fail(.timeout) }
                throw fail(.http)
            }
            tokens += reply.tokens ?? 0
            guard reply.toolCalls.isEmpty else { throw fail(.tools) }
            final = reply.content
        }
        guard let final else { throw fail(.timeout) }
        guard let candidates = Self.candidates(final) else { throw fail(.json) }
        let (kept, dropped) = Self.check(candidates, pages: pages, request: r, at: now())
        let sites = opened.compactMap(Self.site).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        onLine("events browse done steps=\(calls) ms=\(ms()) tokens=\(tokens) found=\(candidates.count) kept=\(kept.count) dropped=\(dropped)")
        let note = (try? JSONDecoder().decode(JSONValue.self, from: Data(Self.jsonText(final).utf8)))?["note"]?.stringValue ?? ""
        return EventBrowseOutcome(kept: kept, dropped: dropped, sites: sites, steps: calls, tokens: tokens, note: note)
    }

    /// Item 6: kept only when the opened page states the start and end and the event overlaps the window.
    public static func check(_ candidates: [EventCandidate], pages: [String: String], request r: EventBrowseRequest,
                             at: Date) -> (kept: [EventEntry], dropped: Int) {
        var kept: [EventEntry] = []
        var dropped = 0
        for c in candidates {
            guard let start = EventDay(c.start), let end = EventDay(c.end), start <= end,
                  let page = pages[c.sourceURL],
                  EventDates.onPage(page, start: start, end: end, windowYear: r.from.year),
                  start <= r.to, end >= r.from else {
                dropped += 1
                continue
            }
            let city = r.cities.first { c.city.contains($0) || $0.contains(c.city) && !c.city.isEmpty } ?? r.cities[0]
            kept.append(EventEntry(name: c.name, start: c.start, end: c.end, datesText: c.datesText, venue: c.venue,
                                   city: city, sourceURL: c.sourceURL, sourceSite: site(c.sourceURL) ?? "", fetchedAt: at))
        }
        return (kept.sorted { ($0.start, $0.name) < ($1.start, $1.name) }, dropped)
    }

    /// The JSON object in the model's text (a fenced block or bare).
    static func jsonText(_ text: String) -> String {
        guard let a = text.firstIndex(of: "{"), let b = text.lastIndex(of: "}"), a < b else { return text }
        return String(text[a...b])
    }

    public static func candidates(_ text: String) -> [EventCandidate]? {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(jsonText(text).utf8)),
              case .array(let events)? = v["events"] else { return nil }
        return events.map { e in
            func s(_ k: String) -> String { e[k]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
            return EventCandidate(name: s("name"), start: s("start"), end: s("end").isEmpty ? s("start") : s("end"),
                                  datesText: s("dates_text"), venue: s("venue"), city: s("city"), sourceURL: s("source_url"))
        }.filter { !$0.name.isEmpty }
    }

    public static func site(_ url: String) -> String? { URL(string: url)?.host }

    static func encode(_ v: JSONValue) -> String {
        String(decoding: (try? JSONValue.canonicalEncoder().encode(v)) ?? Data(), as: UTF8.self)
    }
}
