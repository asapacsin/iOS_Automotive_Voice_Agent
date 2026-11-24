import Foundation
import NovaKit
import NovaPorts

/// F-18 §35 items 1, 2, 5, 7, 8, 9 (T-046x): `find_events`. Code checks the arguments; the store answers when every
/// city was browsed less than 24 h ago for a window covering the asked one; otherwise the browse loop runs (one at a
/// time), the store keeps what passed the date check, and the result is built from it.
public struct FindEventsExecutor: ToolExecutor {
    public static let tool = "find_events"
    /// Item 1: how far ahead a window may end.
    public static let maxDaysAhead = 60
    /// Item 7.
    public static func next(sites: [String]) -> String {
        let where_ = sites.isEmpty ? "网上" : sites.joined(separator: "、")
        return "这些是页面上写着日期的活动。按日期跟司机说名字、日期、地点，一两句；没有就说在\(where_)上没找到这几天的，不要说一定没有。"
    }
    public static let failedNext = "活动没查完，跟司机说现在查不到，等一下再试；不要说没有活动。"
    /// Item 8.
    public static let handoffLine = "好，我去查一下这几天的活动，要一两分钟，好了告诉你。"
    public static let stepStart = "正在查活动"
    public static func stepProgress(searches: Int, pages: Int) -> String { "已搜索\(searches)次，读了\(pages)个页面" }

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

    private let browser: EventBrowser
    private let onHandoff: @Sendable (String) async -> Void

    /// `onHandoff` says item 8's line (the guidance voice, as for `plan_trip`); not called on a store hit.
    public init(browser: EventBrowser, onHandoff: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.browser = browser
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
        let today = await browser.store.today
        if let field = Self.refusal(call.arguments, today: today) {
            return .failure(.invalidArgument, advice: "find_events 的 \(field) 不对，改好再查。", data: ["field": .string(field)])
        }
        guard case .array(let list)? = call.arguments["cities"] else { return .failure(.invalidArgument) }
        let cities = list.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
        let from = EventDay(call.arguments["from"]?.stringValue ?? "")!, to = EventDay(call.arguments["to"]?.stringValue ?? "")!
        let kinds = call.arguments["kinds"]?.stringValue ?? ""
        let request = EventBrowseRequest(cities: cities, from: from, to: to, kinds: kinds, today: today)
        switch await browser.find(request, onMiss: onHandoff) {
        case .store(let events):
            return Self.result(events, dropped: 0, sites: Array(Set(events.map(\.sourceSite))).sorted(), source: "store")
        case .browsed(let events, let outcome):
            return Self.result(events, dropped: outcome.dropped, sites: outcome.sites, source: "browse")
        case .failed:
            return .failure(.eventsFailed, advice: Self.failedNext, data: ["next": .string(Self.failedNext)])
        }
    }

    static func result(_ events: [EventEntry], dropped: Int, sites: [String], source: String) -> ToolResult {
        .success(["events": .array(events.map(\.json)), "dropped": .int(Int64(dropped)),
                  "sites": .array(sites.map { .string($0) }), "source": .string(source),
                  "next": .string(next(sites: sites))])
    }
}

/// The store and the loop together; at most one loop runs at a time (item 5).
public actor EventBrowser {
    public enum Found: Sendable {
        case store([EventEntry])
        case browsed([EventEntry], EventBrowseOutcome)
        case failed(EventBrowseFailure)
    }

    public let store: EventStore
    private let loop: @Sendable (_ onStep: @escaping @Sendable (Int, Int) -> Void) -> EventBrowseLoop
    private let work: WorkProgressBoard?
    private let onLine: @Sendable (String) -> Void
    private var running = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// `loop` builds the browse loop with the step callback the spinner reads; `work` is the spinner row (item 8).
    public init(store: EventStore, work: WorkProgressBoard?, onLine: @escaping @Sendable (String) -> Void = { _ in },
                loop: @escaping @Sendable (_ onStep: @escaping @Sendable (Int, Int) -> Void) -> EventBrowseLoop) {
        self.store = store
        self.work = work
        self.onLine = onLine
        self.loop = loop
    }

    /// Item 2, then item 3 on a miss.
    public func find(_ r: EventBrowseRequest, onMiss: @Sendable (String) async -> Void) async -> Found {
        let window = "\(r.from)..\(r.to)"
        if await store.covers(cities: r.cities, from: r.from.description, to: r.to.description) {
            onLine("events store hit cities=\(r.cities.count) window=\(window)")
            return .store(await store.events(cities: r.cities, from: r.from.description, to: r.to.description))
        }
        onLine("events store miss cities=\(r.cities.count) window=\(window)")
        await onMiss(FindEventsExecutor.handoffLine)
        return await browse(r, spinner: true)
    }

    /// Item 5: the app-open refresh of the car's (or the open trip's) cities browsed more than 24 h ago, today…+30,
    /// in the background. No line, no spinner.
    public func refresh(_ cities: [String]) async {
        let stale = await store.stale(cities)
        guard !stale.isEmpty else { return }
        let today = await store.today
        _ = await browse(EventBrowseRequest(cities: Array(stale.prefix(3)), from: today,
                                            to: today.adding(days: EventStore.refreshDays), kinds: "", today: today), spinner: false)
    }

    private func browse(_ r: EventBrowseRequest, spinner: Bool) async -> Found {
        while running { await withCheckedContinuation { waiters.append($0) } }
        running = true
        defer {
            running = false
            if !waiters.isEmpty { waiters.removeFirst().resume() }
        }
        // A loop that ran while this one waited may already cover it.
        if await store.covers(cities: r.cities, from: r.from.description, to: r.to.description) {
            return .store(await store.events(cities: r.cities, from: r.from.description, to: r.to.description))
        }
        let work = spinner ? work : nil
        work?.start(.handoff, step: FindEventsExecutor.stepStart, immediate: true)
        let onStep: @Sendable (Int, Int) -> Void = { s, p in work?.step(FindEventsExecutor.stepProgress(searches: s, pages: p)) }
        do {
            let outcome = try await loop(onStep).run(r)
            for city in r.cities {
                await store.replace(city: city, from: r.from.description, to: r.to.description,
                                    with: outcome.kept.filter { $0.city == city })
            }
            work?.clear(.handoff)
            return .browsed(await store.events(cities: r.cities, from: r.from.description, to: r.to.description), outcome)
        } catch {
            work?.finish("活动没查完", failed: true)
            return .failed(error)
        }
    }
}
