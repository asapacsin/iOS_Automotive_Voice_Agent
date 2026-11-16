import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §13 item 1 (T-040j): a tap on the trip cards, the same tool call the voice path makes.
public enum TripTap: Sendable, Hashable {
    case remove(index: Int)
    case move(from: Int, to: Int)
    case route(start: Bool)
    /// 「加入清单」 on a row of an open destination list: that already-found place, no new lookup.
    case add(Place)
    /// §11 item 5, §15: a day tab (`edit_trip_list action=read day`).
    case day(Int)
    /// §16 item 6: 「我的行程」: a tap opens a saved plan; a swipe, confirmed on screen, deletes one.
    case openPlan(String)
    case deletePlan(String)

    var action: String {
        switch self {
        case .remove: "remove"
        case .move: "move"
        case .route(let start): start ? "start" : "route"
        case .add: "add"
        case .day: "day"
        case .openPlan: "open"
        case .deletePlan: "delete"
        }
    }
}

public struct TripTuning: Sendable, Hashable {
    /// §4 item 4: lookups at once, and the limit of a whole `make_trip_list`.
    public var parallelLookups = 4
    public var resolveLimit = NovaDuration.seconds(15)
    public init() {}
}

/// F-15b (T-040i): `make_trip_list`, `edit_trip_list` and `route_trip`. Owns the app's one trip list (§3), resolves
/// the model's names through 高德 (§4, never taken as places), and routes the list through `NavigationController`
/// (§5.3). Record lines are codes and numbers only (§7, I-8).
public actor TripPlanner: ToolExecutor {
    public static let tools: Set<String> = ["make_trip_list", "edit_trip_list", "route_trip", "trip_plans"]

    private let search: any PlaceSearch
    private let navigation: NavigationController
    private let origin: @Sendable () async -> GeoCoordinate?
    private let clock: any NovaClock
    private let tuning: TripTuning
    private let onLine: @Sendable (String) -> Void
    private let onChange: @Sendable (TripList) -> Void
    private let onPlans: @Sendable (TripPlansSummary) -> Void
    /// §15: the current plan; `list` is its current day.
    private var plan = TripPlan()
    private var list: TripList {
        get { plan.current }
        set { plan.current = newValue }
    }
    /// §16: the saved plans and the 「上一个清单」 slot.
    private var saved = SavedTripPlans()
    private let files: (any TripFiles)?
    private let now: @Sendable () -> Date
    /// §12 item 5: photo lookups per place this launch; a failed one is tried again at most once.
    private var photoTries: [String: Int] = [:]
    private var photoFailed: Set<String> = []
    private var photoTask: Task<Void, Never>?

    /// `origin`: the same as `navigate_to`'s (the usable fix, or the demo origin in 模拟导航), GCJ-02.
    public init(search: any PlaceSearch, navigation: NavigationController, origin: @escaping @Sendable () async -> GeoCoordinate?,
                clock: any NovaClock, tuning: TripTuning = TripTuning(), files: (any TripFiles)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                onLine: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (TripList) -> Void = { _ in },
                onPlans: @escaping @Sendable (TripPlansSummary) -> Void = { _ in }) {
        self.onPlans = onPlans
        self.files = files
        self.now = now
        self.search = search
        self.navigation = navigation
        self.origin = origin
        self.clock = clock
        self.tuning = tuning
        self.onLine = onLine
        self.onChange = onChange
    }

    public var current: TripList { list }
    public var currentPlan: TripPlan { plan }
    public var savedPlans: SavedTripPlans { saved }

    // MARK: Files (§14)

    static let currentFile = "current.json"
    static let plansFile = "plans.json"

    /// §14 item 1: at launch, the plan and the saved plans come back from the files, with no lookups. An unreadable
    /// file or an unknown version starts empty and is moved aside (§14 item 4). `trip load ok= days= stops=`.
    public func restore() {
        guard let files else { return }
        var ok = true
        if let data = files.read(Self.currentFile) {
            if let restored = TripPlanFile.current(from: data) {
                plan.load(restored)
            } else {
                ok = false
                files.moveAside(Self.currentFile)
            }
        }
        if let data = files.read(Self.plansFile) {
            if let restored = SavedTripPlans(data: data) { saved = restored } else { files.moveAside(Self.plansFile) }
        }
        onLine("trip load ok=\(ok ? "yes" : "no") days=\(plan.dayCount) stops=\(plan.stopCount)")
        onChange(list)
        onPlans(TripPlansSummary(plan, saved))
        photos()
    }

    private func persist() {
        files?.write(Self.currentFile, TripPlanFile.current(plan))
        onPlans(TripPlansSummary(plan, saved))
    }

    private func persistSaved() {
        files?.write(Self.plansFile, saved.data())
        onPlans(TripPlansSummary(plan, saved))
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        // The dispatcher validated the call (ToolCatalog.validate); this is the backstop for direct callers.
        if let code = ToolCatalog.validate(call) { return .failure(code) }
        let before = plan.revision
        let result: ToolResult
        switch call.name {
        case "make_trip_list": result = await make(call.arguments)
        case "edit_trip_list": result = await edit(call.arguments)
        case "route_trip": return await route(call.arguments)
        case "trip_plans": result = await plans(call.arguments)
        default: return .failure(.unknownTool)
        }
        await listChanged(since: before)
        return result
    }

    /// §5.3 item 5: a kept trip route is kept only until the list changes.
    private func listChanged(since before: Int) async {
        guard plan.revision != before else { return }
        await navigation.dropKeptTrip(unless: plan.revision)
    }

    // MARK: make_trip_list

    private func make(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        guard case .array(let raw)? = args["places"] else { return .failure(.invalidFields) }
        let names = raw.compactMap(\.stringValue).map(TranscriptText.normalize)
        let city = args["city"]?.stringValue
        let day = Self.int(args["day"])
        // §15 item 2: a day may be at most the number of days + 1.
        if let day, !(1...min(plan.dayCount + 1, TripPlan.maxDays)).contains(day) { return dayOutOfRange() }
        let generation = plan.revision
        let here = await origin()
        let lookups = await resolve(names, city: city)
        // A cancelled call (barge-in) or a newer change while the lookups ran: this one changes nothing.
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        if lookups.contains(where: { if case .keyMissing = $0 { true } else { false } }) {
            line(stops: list.count, notFound: names.count, duplicates: 0, since: started)
            return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有做成清单。")
        }
        var entries: [(asked: String, place: Place, distanceMeters: Int?)] = []
        var notFound: [String] = []
        var duplicates: [String] = []
        for (offset, lookup) in lookups.enumerated() {
            switch lookup {
            case .found(let place):
                if entries.contains(where: { $0.place.id == place.id }) {
                    duplicates.append(names[offset])
                } else {
                    entries.append((names[offset], place, distance(here, place)))
                }
            case .missing(let reason):
                notFound.append(names[offset])
                onLine("trip lookup index=\(offset + 1) ok=no reason=\(reason)")
            case .keyMissing: break
            }
        }
        guard !entries.isEmpty else {
            line(stops: list.count, notFound: notFound.count, duplicates: duplicates.count, since: started)
            return .failure(.noCandidates, advice: "清单里的地点都没有找到，清单没有改。请如实说没找到这些地方。")
        }
        var made = TripList()
        made.replace(entries)
        if let day { _ = plan.replaceDay(day, with: made) } else { plan.replaceAll(with: made) }
        changed()
        line(stops: list.count, notFound: notFound.count, duplicates: duplicates.count, since: started)
        let missed = notFound.isEmpty ? "" : "；没找到：\(notFound.joined(separator: "、"))"
        return listResult(changed: nil, notFound: notFound, duplicates: duplicates,
                          next: "只说一句：清单有\(list.count)个地点\(missed)。不要念整张清单，司机问时再念。")
    }

    // MARK: edit_trip_list

    private func edit(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        let action = args["action"]?.stringValue ?? ""
        let result = await editAction(action, args)
        // not_found counts only a lookup that found nothing (add, replace); duplicates an add of a listed place.
        let lookedUp = (action == "add" || action == "replace") && result.code == .notFound
        let duplicates: Int = if case .array(let d)? = result.data["duplicates"] { d.count } else { 0 }
        onLine("trip list stops=\(list.count) not_found=\(lookedUp ? 1 : 0) duplicates=\(duplicates) ms=\(ms(since: started)) action=\(action) ok=\(result.ok ? "yes" : "no")")
        return result
    }

    private func editAction(_ action: String, _ args: JSONValue) async -> ToolResult {
        let index = Self.int(args["index"]), toIndex = Self.int(args["to_index"])
        let name = args["name"]?.stringValue.map(TranscriptText.normalize)
        let day = Self.int(args["day"])
        if let day {
            if action == "clear" {
                guard plan.removeDay(day) else { return dayOutOfRange() }
                changed()
                return listResult(changed: "cleared", next: "只说一句：第\(day)天已删掉，现在行程有\(plan.dayCount)天。")
            }
            guard plan.select(day) else { return dayOutOfRange() }
            // The current day is the last one made, edited, read or routed (§15 item 1).
            onChange(list)
            persist()
        }
        let n = list.count
        if list.isEmpty, action != "add", action != "clear" { return failure(.noTripList) }
        switch action {
        case "read":
            return listResult(changed: "none", next: "按 stops 的顺序念清单，每个只念序号和名字。")
        case "clear":
            plan.clearAll()
            changed()
            return listResult(changed: "cleared", next: "只说一句：清单已清空。")
        case "remove":
            let target: Int
            if let index {
                guard (1...n).contains(index) else { return outOfRange() }
                target = index
            } else {
                let found = list.matches(name ?? "")
                guard found.count <= 1 else { return failure(.ambiguous) }
                guard let only = found.first else { return failure(.notFound) }
                target = only
            }
            let removed = list.stops[target - 1].place.name
            list.remove(at: target)
            changed()
            return listResult(changed: "removed", next: "只说一句：去掉了\(removed)，现在清单有\(list.count)个地点。",
                              extra: ["removed": .string(removed)])
        case "move":
            guard let index, let toIndex, (1...n).contains(index), (1...n).contains(toIndex) else { return outOfRange() }
            let moved = list.stops[index - 1].place.name
            list.move(from: index, to: toIndex)
            changed()
            return listResult(changed: "moved", next: "只说一句：\(moved)放到了第\(toIndex)个，现在清单有\(list.count)个地点。")
        case "add", "replace":
            guard let name else { return .failure(.invalidFields) }
            if action == "add" {
                if let index, !(1...(n + 1)).contains(index) { return outOfRange() }
                guard n < TripList.maxStops else { return failure(.tripTooLong) }
            } else {
                guard let index, (1...n).contains(index) else { return outOfRange() }
            }
            let generation = plan.revision
            let here = await origin()
            let lookup = await resolve([name], city: nil).first ?? .missing("failed")
            // §3 item 4: a newer change while this lookup ran wins; this one changes nothing.
            guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
            let place: Place
            switch lookup {
            case .found(let found): place = found
            case .keyMissing: return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有改清单。")
            case .missing(let reason):
                // The stop's place in the list: the add position (the end when none) or the replaced index.
                onLine("trip lookup index=\(index ?? (n + 1)) ok=no reason=\(reason)")
                return failure(.notFound)
            }
            let replacing = action == "replace" ? index : nil
            if list.stops.contains(where: { $0.place.id == place.id && $0.index != replacing }) {
                return listResult(changed: "none", duplicates: [name],
                                  next: "只说一句：\(place.name)已经在清单里了，现在清单有\(list.count)个地点。")
            }
            let stop = TripStop(index: 0, asked: name, place: place, distanceMeters: distance(here, place))
            if let replacing {
                list.set(stop, at: replacing)
                changed()
                return listResult(changed: "replaced", next: "只说一句：第\(replacing)个换成了\(place.name)，现在清单有\(list.count)个地点。")
            }
            list.insert(stop, at: index)
            changed()
            return listResult(changed: "added", next: "只说一句：加上了\(place.name)，现在清单有\(list.count)个地点。")
        default:
            return .failure(.invalidFields)
        }
    }

    // MARK: route_trip

    private func route(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        let start = args["start"]?.boolValue ?? false
        // §15 item 4: one route is one day.
        if let day = Self.int(args["day"]) {
            guard plan.select(day) else { return dayOutOfRange() }
            onChange(list)
            persist()
        }
        guard !list.isEmpty else { return failure(.noTripList) }
        guard list.count >= 2 else {
            return .failure(.tripTooShort, advice: "清单里只有一个地点，串不成路线。请如实说明；要去这一个地方就用 navigate_to。")
        }
        // 「开始导航」 after 「按清单顺序走」: with no order given, the kept route of this list keeps its order.
        let keptThisList = await navigation.keptTripList == plan.revision
        let asListed = args["order"]?.stringValue == "as_listed" || (args["order"] == nil && keptThisList)
        if !asListed {
            let order = TripOrder.nearest(from: await origin(), list.stops.map(\.place.coordinate))
            list.reorder(order)
            changed()
        }
        let generation = plan.revision
        let stops = list.stops.map(\.place)
        let outcome = await navigation.routeTrip(stops, list: generation, start: start)
        let order = asListed ? "as_listed" : "nearest"
        func logLine(_ route: RouteSummary?, started yes: Bool) {
            let km = route.map { NavigationController.km($0.lengthMeters) } ?? 0
            let min = route.map { max(1, $0.durationSeconds / 60) } ?? 0
            onLine("trip route stops=\(stops.count) order=\(order) km=\(km) min=\(min) started=\(yes ? "yes" : "no") ms=\(ms(since: started))")
        }
        switch outcome {
        case .failed(let result):
            logLine(nil, started: false)
            return result
        case .kept(let route):
            // §3 item 4: the list changed while the route was calculated: the route is not this list's.
            guard plan.revision == generation else {
                await navigation.dropKeptTrip(unless: plan.revision)
                logLine(nil, started: false)
                return .failure(.optionsStale, advice: "清单在规划时改了，这条路线不算数。请如实说明，需要时再说串成路线。")
            }
            logLine(route, started: false)
            let (km, time) = Self.distanceAndTime(route)
            return routeResult(route, started: false,
                               next: "只说一句：经过\(stops.count)个地点，全程约\(km)公里，大约\(time)，问要不要开始导航；不要念每个地点，司机问时再念。")
        case .started(let route, let mode), .alreadyRunning(let route, let mode):
            // B3: the list changed while this trip started; it is not this list's, so its guidance stops.
            guard plan.revision == generation else {
                await navigation.stopTrip(list: generation)
                logLine(nil, started: false)
                return .failure(.optionsStale, advice: "清单在启动导航时改了，导航没有开始。请如实说明，需要时再说开始导航。")
            }
            logLine(route, started: true)
            let (km, _) = Self.distanceAndTime(route)
            let said = mode == .emulator ? "已开始模拟导航" : "已开始导航"
            return routeResult(route, started: true,
                               next: "只说一句：\(said)，第一站是\(stops[0].name)，全程约\(km)公里。")
        }
    }

    // MARK: Resolving (§4)

    enum Lookup: Sendable {
        case found(Place)
        case missing(String)
        case keyMissing
    }

    /// Each name through `PlaceSearch.text`, at most `parallelLookups` at once, all within `resolveLimit`; a lookup
    /// still running then is `timeout`. Results are in `names` order.
    private func resolve(_ names: [String], city: String?) async -> [Lookup] {
        let search = search, limit = tuning.parallelLookups, clock = clock
        let deadline = clock.now + tuning.resolveLimit
        let (stream, feed) = AsyncStream.makeStream(of: (Int, Lookup)?.self)
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < names.count else { return }
                    let i = next
                    next += 1
                    _ = group.addTaskUnlessCancelled { feed.yield((i, await Self.lookup(names[i], city: city, search: search))) }
                }
                for _ in 0..<min(limit, names.count) { add() }
                while await group.next() != nil { add() }
            }
            feed.yield(nil)
        }
        let timer = Task {
            try? await clock.sleep(until: deadline)
            if !Task.isCancelled { feed.yield(nil) }
        }
        var results = [Lookup?](repeating: nil, count: names.count)
        for await item in stream {
            guard let (i, lookup) = item else { break }
            results[i] = lookup
        }
        work.cancel()
        timer.cancel()
        feed.finish()
        return results.map { $0 ?? .missing("timeout") }
    }

    private static func lookup(_ name: String, city: String?, search: any PlaceSearch) async -> Lookup {
        do {
            let places = try await search.text(name, city: city, cityLimit: city != nil)
            guard let first = places.first, TripNameMatch.accepts(asked: name, found: first.name) else { return .missing("nomatch") }
            return .found(first)
        } catch let error as AmapWebError where error == .keyMissing || error == .keyRejected {
            return .keyMissing
        } catch {
            return .missing("failed")
        }
    }

    // MARK: Results

    private func listResult(changed: String?, notFound: [String] = [], duplicates: [String] = [], next: String,
                            extra: [String: JSONValue] = [:]) -> ToolResult {
        var data: [String: JSONValue] = [
            "status": "trip_list",
            "count": .int(Int64(list.count)),
            "stops": .array(list.stops.map { stop in
                var o: [String: JSONValue] = ["index": .int(Int64(stop.index)), "name": .string(stop.place.name)]
                o["district"] = stop.place.district.map(JSONValue.string) ?? .null
                o["distance_km"] = stop.distanceMeters.map { .double(NavigationController.km($0)) } ?? .null
                return .object(o)
            }),
            "not_found": .array(notFound.map { .string($0) }),
            "duplicates": .array(duplicates.map { .string($0) }),
            "next": .string(next),
        ]
        if let changed { data["changed"] = .string(changed) }
        data["day"] = .int(Int64(plan.currentDay))
        data["days"] = .int(Int64(plan.dayCount))
        data.merge(extra) { _, new in new }
        return .success(data)
    }

    private func routeResult(_ route: RouteSummary, started: Bool, next: String) -> ToolResult {
        .success([
            "status": "trip_route",
            "stops": .array(list.stops.map { .object(["index": .int(Int64($0.index)), "name": .string($0.place.name)]) }),
            "count": .int(Int64(list.count)),
            "distance_km": .double(NavigationController.km(route.lengthMeters)),
            "duration_min": .int(Int64(max(1, route.durationSeconds / 60))),
            "tolls_yuan": .int(Int64(route.tollYuan)),
            "started": .bool(started),
            "day": .int(Int64(plan.currentDay)),
            "days": .int(Int64(plan.dayCount)),
            "next": .string(next),
        ])
    }

    static func distanceAndTime(_ route: RouteSummary) -> (String, String) {
        let km = NavigationController.km(route.lengthMeters)
        let kmText = km == km.rounded() ? String(Int(km)) : String(km)
        let minutes = max(1, route.durationSeconds / 60)
        let time = minutes >= 60 ? "\(minutes / 60)小时\(minutes % 60 == 0 ? "" : "\(minutes % 60)分钟")" : "\(minutes)分钟"
        return (kmText, time)
    }

    private func failure(_ code: ToolErrorCode) -> ToolResult { .failure(code, advice: ToolFailureAdvice.forCode(code)) }

    private func outOfRange() -> ToolResult {
        .failure(.outOfRange, advice: "清单里没有这一项，现在一共\(list.count)个地点。请如实说明。")
    }

    private func distance(_ here: GeoCoordinate?, _ place: Place) -> Int? {
        here.map { Int(SelfPosition.distanceMeters($0, place.coordinate).rounded()) }
    }

    private func changed() {
        onChange(list)
        persist()
        photos()
    }

    private func dayOutOfRange() -> ToolResult {
        .failure(.outOfRange, advice: "没有这一天，现在行程有\(plan.dayCount)天。请如实说明。")
    }

    // MARK: trip_plans (§16)

    private func plans(_ args: JSONValue) async -> ToolResult {
        let action = args["action"]?.stringValue ?? ""
        let result = plansAction(action, args)
        onLine("trip plan action=\(action) ok=\(result.ok ? "yes" : "no") days=\(plan.dayCount) stops=\(plan.stopCount)")
        return result
    }

    private func find(_ name: String) -> Result<Int, ToolResultBox> {
        switch saved.match(name) {
        case .found(let i): .success(i)
        case .ambiguous: .failure(ToolResultBox(failure(.ambiguous)))
        case .none: .failure(ToolResultBox(failure(.planNotFound)))
        }
    }

    private func plansAction(_ action: String, _ args: JSONValue) -> ToolResult {
        let name = args["name"]?.stringValue.map(TranscriptText.normalize) ?? ""
        switch action {
        case "save":
            guard !plan.isEmpty else { return failure(.noTripList) }
            let exists = { if case .found(let i) = self.saved.match(name), TranscriptText.normalize(self.saved.entries[i].name) == name { true } else { false } }()
            guard exists || saved.entries.count < SavedTripPlans.maxPlans else { return failure(.plansFull) }
            let replaced = saved.save(plan, as: name, at: now())
            plan.name = name
            persist()
            persistSaved()
            return .success(["status": "plan_saved", "name": .string(name), "replaced": .bool(replaced),
                             "days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)),
                             "next": .string("只说一句：已存成「\(name)」\(replaced ? "（替换了同名的）" : "")。")])
        case "open":
            let index: Int
            if TranscriptText.normalize(name) == SavedTripPlans.previousName, let previous = saved.previous {
                return open(previous, named: SavedTripPlans.previousName)
            }
            switch find(name) {
            case .success(let i): index = i
            case .failure(let box): return box.result
            }
            return open(saved.entries[index].plan, named: saved.entries[index].name)
        case "list":
            return .success(["status": "plan_list", "count": .int(Int64(saved.entries.count)),
                             "plans": .array(saved.entries.map { .object(["name": .string($0.name),
                                                                         "days": .int(Int64($0.plan.dayCount)),
                                                                         "stops": .int(Int64($0.plan.stopCount))]) }),
                             "next": .string(saved.entries.isEmpty ? "只说一句：还没有存过行程。"
                                             : "只说一句：存了\(saved.entries.count)个行程，按顺序说名字。")])
        case "delete":
            switch find(name) {
            case .success(let i):
                let gone = saved.entries[i].name
                saved.delete(at: i)
                persistSaved()
                return .success(["status": "plan_deleted", "name": .string(gone), "next": .string("只说一句：删掉了「\(gone)」。")])
            case .failure(let box): return box.result
            }
        case "rename":
            let newName = args["new_name"]?.stringValue.map(TranscriptText.normalize) ?? ""
            switch find(name) {
            case .success(let i):
                let old = saved.entries[i].name
                if let other = saved.entries.firstIndex(where: { TranscriptText.normalize($0.name) == newName }), other != i {
                    return .failure(.invalidFields, advice: "已经有一个叫「\(newName)」的行程了，没有改名。请如实说明。")
                }
                saved.rename(at: i, to: newName)
                if plan.name == old { plan.name = newName; persist() }
                persistSaved()
                return .success(["status": "plan_renamed", "name": .string(newName), "next": .string("只说一句：改名叫「\(newName)」了。")])
            case .failure(let box): return box.result
            }
        default:
            return .failure(.invalidFields)
        }
    }

    /// §16 items 3 and 7: opening keeps an unnamed current plan with stops as 「上一个清单」; a kept trip route is
    /// dropped (by `execute`'s list-change check); guidance on a running route goes on.
    private func open(_ other: TripPlan, named name: String) -> ToolResult {
        var kept = false
        if plan.name == nil, !plan.isEmpty {
            saved.previous = plan
            kept = true
            persistSaved()
        }
        var opened = other
        opened.name = name == SavedTripPlans.previousName ? nil : name
        plan.load(opened)
        changed()
        let note = kept ? "原来的清单已经存为「上一个清单」，" : ""
        return .success(["status": "plan_opened", "name": .string(name), "kept_previous": .bool(kept),
                         "days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)),
                         "next": .string("只说一句：打开了「\(name)」，\(note)有\(plan.dayCount)天\(plan.stopCount)个地点。要导航就说开始导航。")])
    }

    // MARK: Screen taps (§13)

    /// §13 item 1 (I-6): the tap becomes the tool call of the voice path, through the same validation and executor.
    /// While moving it is refused with `NOT_WHILE_MOVING` and changes nothing. `note` is the §13 item 4 silent note
    /// for a connected session, nil when nothing changed.
    public func tap(_ tap: TripTap, moving: Bool) async -> (result: ToolResult, note: String?) {
        let result: ToolResult
        if moving {
            result = failure(.notWhileMoving)
        } else {
            switch tap {
            case .remove(let index):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "edit_trip_list",
                                                arguments: ["action": "remove", "index": .int(Int64(index))]))
            case .move(let from, let to):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "edit_trip_list",
                                                arguments: ["action": "move", "index": .int(Int64(from)), "to_index": .int(Int64(to))]))
            case .route(let start):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "route_trip", arguments: ["start": .bool(start)]))
            case .day(let day):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "edit_trip_list",
                                                arguments: ["action": "read", "day": .int(Int64(day))]))
            case .openPlan(let name):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_plans",
                                                arguments: ["action": "open", "name": .string(name)]))
            case .deletePlan(let name):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_plans",
                                                arguments: ["action": "delete", "name": .string(name)]))
            case .add(let place):
                let before = plan.revision
                result = add(place)
                await listChanged(since: before)
            }
        }
        onLine("trip tap action=\(tap.action) ok=\(result.ok ? "yes" : "no")")
        guard result.ok else { return (result, nil) }
        let what: String
        switch tap {
        case .day, .deletePlan:
            // Only the screen changed (a day tab, a saved plan gone): no note.
            return (result, nil)
        case .openPlan(let name): what = "打开了行程「\(result.data["name"]?.stringValue ?? name)」"
        case .remove(let index): what = "去掉了第\(index)个：\(Self.removedName(result) ?? "")"
        case .move(let from, let to): what = "把第\(from)个移到了第\(to)个"
        case .route(let start): what = start ? "开始了导航" : "串成了路线"
        case .add(let place): what = "加入了\(place.name)"
        }
        return (result, "[系统] 司机在屏幕上\(what)，现在清单有\(list.count)个地点。这句不用回答。")
    }

    /// §13 item 3: an already-found place added at the end, with no new lookup.
    private func add(_ place: Place) -> ToolResult {
        guard list.count < TripList.maxStops else { return failure(.tripTooLong) }
        if list.contains(placeID: place.id) {
            return listResult(changed: "none", duplicates: [place.name],
                              next: "只说一句：\(place.name)已经在清单里了，现在清单有\(list.count)个地点。")
        }
        list.insert(TripStop(index: 0, asked: place.name, place: place, distanceMeters: place.distanceMeters))
        changed()
        return listResult(changed: "added", next: "只说一句：加上了\(place.name)，现在清单有\(list.count)个地点。")
    }

    private static func removedName(_ result: ToolResult) -> String? { result.data["removed"]?.stringValue }

    // MARK: Photos (§12)

    /// After a change: one detail call per stop without a photo link, at most 4 at once, after the tool result,
    /// so it never delays her reply. A stop that already has a link (a saved plan) makes no call.
    private func photos() {
        let wanted = plan.days.flatMap(\.stops).map(\.place).filter { place in
            place.photoURL == nil && !place.id.hasPrefix("saved_")
                && (photoTries[place.id] ?? 0) < (photoFailed.contains(place.id) ? 2 : 1)
        }
        guard !wanted.isEmpty else { return }
        for place in wanted { photoTries[place.id, default: 0] += 1 }
        let search = search, clock = clock, limit = tuning.parallelLookups
        let previous = photoTask
        photoTask = Task { [weak self] in
            await previous?.value
            let started = clock.now
            var found: [(String, URL?, Bool)] = []
            await withTaskGroup(of: (String, URL?, Bool).self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let place = wanted[next]
                    next += 1
                    group.addTask {
                        do {
                            let detail = try await search.detail(id: place.id)
                            return (place.id, detail?.photoURL, true)
                        } catch {
                            return (place.id, nil, false)
                        }
                    }
                }
                for _ in 0..<min(limit, wanted.count) { add() }
                while let item = await group.next() {
                    found.append(item)
                    add()
                }
            }
            await self?.photosArrived(found, since: started)
        }
    }

    private func photosArrived(_ found: [(String, URL?, Bool)], since started: NovaInstant) {
        var ok = 0, none = 0, failed = 0
        for (id, url, reached) in found {
            if !reached {
                failed += 1
                photoFailed.insert(id)
            } else if let url {
                ok += 1
                photoFailed.remove(id)
                plan.setPhoto(placeID: id, url: url)
            } else {
                none += 1
                photoFailed.remove(id)
            }
        }
        onLine("trip photo ok=\(ok) none=\(none) failed=\(failed) ms=\(ms(since: started))")
        // Saved plans keep the link, not the image (§12 item 4).
        if ok > 0 { persist() }
        onChange(list)
    }

    /// Tests: the photo lookups of the last change have finished.
    public func photosSettled() async { await photoTask?.value }

    private func line(stops: Int, notFound: Int, duplicates: Int, since: NovaInstant) {
        onLine("trip list stops=\(stops) not_found=\(notFound) duplicates=\(duplicates) ms=\(ms(since: since))")
    }

    private func ms(since: NovaInstant) -> Int64 { max(0, (clock.now - since).milliseconds) }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let v): Int(v)
        case .double(let v): Int(exactly: v)
        default: nil
        }
    }
}
