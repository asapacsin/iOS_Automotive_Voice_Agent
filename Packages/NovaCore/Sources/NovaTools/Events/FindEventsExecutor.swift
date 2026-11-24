import Foundation
import NovaKit
import NovaPorts

/// F-18 §35 items 1, 2, 5 (T-046x), §39 items 5-7 (T-046zb): `find_events`. Code checks the arguments; the store
/// answers when every city × kind was searched recently enough for a covering window; otherwise the keyword searches
/// and the extraction run (one call at a time), the store keeps what passed the checks, and the result is built.
public struct FindEventsExecutor: ToolExecutor {
    public static let tool = "find_events"
    /// Item 1: how far ahead a window may end.
    public static let maxDaysAhead = 60
    /// §39 item 6.
    public static let searchNext = "这些是网上查到的活动，日期以主办方为准。按日期跟司机说名字、日期、地点，一两句，提醒出发前核实；没有就说这几类在网上没查到，不要说一定没有。"
    public static func storeNext(minutes: Int) -> String { "这是\(minutes)分钟前查到的，" + searchNext }
    public static let failedNext = "活动没查完，跟司机说现在查不到，等一下再试；不要说没有活动。"
    /// §39 item 7.
    public static let handoffLine = "好，我查一下这几天的活动，半分钟左右。"
    public static let stepStart = "正在查活动"
    public static func stepProgress(done: Int, of total: Int) -> String { "已查\(done)/\(total)" }

    /// Item 1: a province is never a city.
    static let provinces: Set<String> = [
        "河北", "山西", "辽宁", "吉林", "黑龙江", "江苏", "浙江", "安徽", "福建", "江西", "山东", "河南", "湖北", "湖南", "广东",
        "海南", "四川", "贵州", "云南", "陕西", "甘肃", "青海", "台湾", "内蒙古", "广西", "西藏", "宁夏", "新疆",
    ]
    static func isProvince(_ name: String) -> Bool {
        var n = name
        for suffix in ["维吾尔自治区", "壮族自治区", "回族自治区", "自治区", "省"] where n.hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count))
            break
        }
        return provinces.contains(n)
    }

    private let finder: EventFinder
    private let onHandoff: @Sendable (String) async -> Void

    /// `onHandoff` says item 7's line (the guidance voice, as for `plan_trip`); not called on a store hit.
    public init(finder: EventFinder, onHandoff: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.finder = finder
        self.onHandoff = onHandoff
    }

    /// Item 1: read shape = write shape; a wrong field is refused by name.
    public static func refusal(_ args: JSONValue, today: EventDay) -> String? {
        guard case .array(let list)? = args["cities"], (1...3).contains(list.count) else { return "cities" }
        let cities = list.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        if cities.count != list.count || cities.contains(where: { $0.isEmpty || $0.count > 20 || isProvince($0) }) { return "cities" }
        guard let from = args["from"]?.stringValue.flatMap(EventDay.init), from >= today else { return "from" }
        guard let to = args["to"]?.stringValue.flatMap(EventDay.init), to >= from, today.days(to: to) <= maxDaysAhead else { return "to" }
        if let k = args["kinds"], (k.stringValue ?? "").count > 60 { return "kinds" }
        return nil
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        let today = await finder.store.today
        if let field = Self.refusal(call.arguments, today: today) {
            return .failure(.invalidArgument, advice: "find_events 的 \(field) 不对，改好再查。", data: ["field": .string(field)])
        }
        guard case .array(let list)? = call.arguments["cities"] else { return .failure(.invalidArgument) }
        let cities = list.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let from = EventDay(call.arguments["from"]?.stringValue ?? "")!, to = EventDay(call.arguments["to"]?.stringValue ?? "")!
        let kinds = call.arguments["kinds"]?.stringValue ?? ""
        let request = EventRequest(cities: cities, from: from, to: to, kinds: kinds, today: today)
        switch await finder.find(request, onMiss: onHandoff) {
        case .store(let events, let minutes):
            var data = Self.data(events, dropped: 0, source: "store", next: Self.storeNext(minutes: minutes))
            data["searched_minutes_ago"] = .int(Int64(minutes))
            return .success(data)
        case .searched(let events, let outcome):
            return .success(Self.data(events, dropped: outcome.dropped, source: "search", next: Self.searchNext))
        case .failed:
            return .failure(.eventsFailed, advice: Self.failedNext, data: ["next": .string(Self.failedNext)])
        }
    }

    static func data(_ events: [EventEntry], dropped: Int, source: String, next: String) -> [String: JSONValue] {
        let sites = events.map(\.sourceSite).filter { !$0.isEmpty }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return ["events": .array(events.map(\.json)), "dropped": .int(Int64(dropped)),
                "sites": .array(sites.map { .string($0) }), "source": .string(source), "next": .string(next)]
    }
}

/// The store and the searches together; at most one search runs at a time.
public actor EventFinder {
    public enum Found: Sendable {
        /// The store's events and how many minutes ago they were searched (§39 item 6).
        case store([EventEntry], minutes: Int)
        case searched([EventEntry], EventSearchOutcome)
        case failed(EventSearchFailure)
    }

    public let store: EventStore
    private let run: @Sendable (_ onProgress: @escaping @Sendable (Int, Int) -> Void) -> EventSearchRun
    private let work: WorkProgressBoard?
    private let onLine: @Sendable (String) -> Void
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `run` builds the search run with the progress callback the spinner reads; `work` is the spinner row (item 7).
    public init(store: EventStore, work: WorkProgressBoard?, onLine: @escaping @Sendable (String) -> Void = { _ in },
                run: @escaping @Sendable (_ onProgress: @escaping @Sendable (Int, Int) -> Void) -> EventSearchRun) {
        self.store = store
        self.work = work
        self.onLine = onLine
        self.run = run
    }

    /// The store, else the searches (`onMiss` says the handoff line first).
    public func find(_ r: EventRequest, onMiss: @Sendable (String) async -> Void) async -> Found {
        if let hit = await storeHit(r) { return hit }
        await onMiss(FindEventsExecutor.handoffLine)
        return await search(r, spinner: true)
    }

    /// F-15b §64 item 2 (T-040zq): `plan_trip`'s read: the store, else the searches inside its own run (no handoff
    /// line, no row of its own: the planner's row shows 「正在查活动」). nil when the search failed.
    public func events(for r: EventRequest) async -> [EventEntry]? {
        if case .store(let e, _)? = await storeHit(r) { return e }
        switch await search(r, spinner: false) {
        case .store(let e, _), .searched(let e, _): return e
        case .failed: return nil
        }
    }

    /// §35 item 5 with §39 item 5: the app-open refresh of the car's (or the open trip's) cities not searched with the
    /// default kinds for today…+30, in the background. No line, no spinner.
    public func refresh(_ cities: [String]) async {
        let stale = await store.stale(cities)
        guard !stale.isEmpty else { return }
        let today = await store.today
        _ = await search(EventRequest(cities: Array(stale.prefix(3)), from: today,
                                      to: today.adding(days: EventStore.refreshDays), kinds: "", today: today), spinner: false)
    }

    /// §39 item 8's store line; the store's events on a hit.
    private func storeHit(_ r: EventRequest) async -> Found? {
        let from = r.from.description, to = r.to.description
        let age = await store.age(cities: r.cities, kinds: r.kindList, from: from, to: to)
        onLine("events store \(age == nil ? "miss" : "hit") cities=\(r.cities.count) kinds=\(r.kindList.count) window=\(from)..\(to)")
        guard let age else { return nil }
        return .store(await store.events(cities: r.cities, from: from, to: to), minutes: Int(age / 60))
    }

    private func search(_ r: EventRequest, spinner: Bool) async -> Found {
        while running { await withCheckedContinuation { waiters.append($0) } }
        running = true
        defer {
            running = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        let from = r.from.description, to = r.to.description
        // A search that ran while this one waited may already cover it.
        if let age = await store.age(cities: r.cities, kinds: r.kindList, from: from, to: to) {
            return .store(await store.events(cities: r.cities, from: from, to: to), minutes: Int(age / 60))
        }
        let work = spinner ? work : nil
        work?.start(.handoff, step: FindEventsExecutor.stepStart, immediate: true)
        let onProgress: @Sendable (Int, Int) -> Void = { n, m in work?.step(FindEventsExecutor.stepProgress(done: n, of: m)) }
        do {
            let outcome = try await run(onProgress).run(r)
            await store.record(outcome.kept, searched: outcome.searched, from: from, to: to)
            work?.clear(.handoff)
            return .searched(await store.events(cities: r.cities, from: from, to: to), outcome)
        } catch {
            work?.finish("活动没查完", failed: true)
            return .failed(error)
        }
    }
}

/// F-18 §35 item 5 (T-046x): the city of a regeo address (「广东省珠海市香洲区…」 → 珠海) or of a trip city, for the
/// app-open refresh. Direct-administered cities and SARs come first; nil when no city is found.
public enum EventCity {
    static let whole = ["北京", "上海", "天津", "重庆", "澳门", "香港"]

    public static func from(address: String) -> String? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if let w = whole.first(where: { text.hasPrefix($0) || text.hasPrefix("中国" + $0) }) { return w }
        var rest = Substring(text)
        if let p = rest.range(of: "省") ?? rest.range(of: "自治区") { rest = rest[p.upperBound...] }
        if let c = rest.range(of: "市") {
            let city = String(rest[..<c.lowerBound])
            return city.isEmpty || city.count > 8 || FindEventsExecutor.isProvince(city) ? nil : city
        }
        // A bare city name (a trip's `city`, 「珠海」).
        return (1...8).contains(text.count) && !text.contains(",") && !FindEventsExecutor.isProvince(text) ? text : nil
    }
}
