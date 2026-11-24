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
    public init(cities: [String], from: EventDay, to: EventDay, kinds: String, today: EventDay) {
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
    case timeout, http, json
}

/// F-18 §35 items 3, 4, 6, 9 (T-046x): the browse loop. The model has two tools, `search` and `open_page`; at most
/// `maxCalls` tool calls and `limit` of time, then code asks once for the final JSON. Code keeps only events whose
/// start and end parse from the text of the opened `source_url` page and that overlap the window.
public struct EventBrowseLoop: Sendable {
    public static let maxCalls = 12
    public static let limit = NovaDuration.seconds(180)
    /// Item 4: an opened page's tool message after the next model turn.
    public static func readMarker(_ url: String) -> String { "（已读：\(url)）" }

    // MARK: System text (owner rule 2026-11-05: copied, never our own wording)

    /// Copied from ReAct (Yao et al., "ReAct: Synergizing Reasoning and Acting in Language Models", ICLR 2023): the
    /// first sentence of the HotpotQA prompt's instruction in the authors' code (github.com/ysymyth/ReAct,
    /// hotpotqa.ipynb). Its actions are this loop's declared tools (`search`, `open_page`) instead of the text list.
    /// Only the values below (date, cities, window, JSON shape) are added, as §35 item 3 says.
    public static let reactInstruction = "Solve a question answering task with interleaving Thought, Action, Observation steps."
    /// Item 3's JSON shape.
    public static let shape = #"{"events":[{"name":"","start":"YYYY-MM-DD","end":"YYYY-MM-DD","dates_text":"","venue":"","city":"","source_url":""}],"note":""}"#

    public static func system(_ r: EventBrowseRequest) -> String {
        reactInstruction + "\ntoday: \(r.today)\ncities: \(r.cities.joined(separator: ", "))\nwindow: \(r.from)..\(r.to)\noutput JSON: " + shape
    }

    /// The question as values only.
    public static func question(_ r: EventBrowseRequest) -> String {
        let v: JSONValue = ["cities": .array(r.cities.map { .string($0) }), "from": .string(r.from.description),
                            "to": .string(r.to.description), "kinds": .string(r.kinds)]
        return String(decoding: (try? JSONValue.canonicalEncoder().encode(v)) ?? Data(), as: UTF8.self)
    }

    /// The final ask after the calls or the time ran out.
    public static let finalAsk = "output JSON: " + shape

    /// The two tools in the OpenAI-compatible `tools` shape (parameter names only; no text of ours).
    public static let tools: JSONValue = .array([
        ["type": "function", "function": ["name": "search", "parameters": [
            "type": "object", "properties": ["query": ["type": "string"]], "required": ["query"]]]],
        ["type": "function", "function": ["name": "open_page", "parameters": [
            "type": "object", "properties": ["url": ["type": "string"]], "required": ["url"]]]],
    ])

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
        var unread: [(index: Int, url: String)] = []
        var calls = 0, searches = 0, tokens = 0
        var final: String?

        func fail(_ why: EventBrowseFailure) -> EventBrowseFailure {
            onLine("events failed reason=\(why.rawValue)")
            return why
        }

        while calls < Self.maxCalls, left() > .zero {
            let reply: EventChatReply
            do { reply = try await model.turn(messages, tools: true, timeout: left()) } catch {
                if Task.isCancelled || left() <= .zero || error is CancellationError { throw fail(.timeout) }
                throw fail(.http)
            }
            tokens += reply.tokens ?? 0
            // Item 4: pages already returned are replaced once the model has read them.
            for u in unread { messages[u.index].content = Self.readMarker(u.url) }
            unread = []
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
                        pages[url] = page.title + "\n" + page.text
                        if !opened.contains(url) { opened.append(url) }
                        ok = true
                        content = Self.encode(["title": .string(page.title), "excerpt": .string(page.excerpt),
                                               "links": .array(page.links.map { ["url": .string($0.url), "text": .string($0.text)] })])
                        unread.append((messages.count, url))
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
            // Item 3: then code asks once for the final JSON.
            for u in unread { messages[u.index].content = Self.readMarker(u.url) }
            messages.append(EventChatMessage(role: .user, content: Self.finalAsk))
            // Review fix: the final ask stays inside item 3's 180 s.
            let budget = left()
            if budget > .zero, let reply = try? await model.turn(messages, tools: false, timeout: budget), reply.toolCalls.isEmpty,
               !reply.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                tokens += reply.tokens ?? 0
                final = reply.content
            }
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
