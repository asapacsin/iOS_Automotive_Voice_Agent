import NovaKit
import NovaPorts
import NovaTools

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
    public static let tools: Set<String> = ["make_trip_list", "edit_trip_list", "route_trip"]

    private let search: any PlaceSearch
    private let navigation: NavigationController
    private let origin: @Sendable () async -> GeoCoordinate?
    private let clock: any NovaClock
    private let tuning: TripTuning
    private let onLine: @Sendable (String) -> Void
    private let onChange: @Sendable (TripList) -> Void
    private var list = TripList()

    /// `origin`: the same as `navigate_to`'s (the usable fix, or the demo origin in 模拟导航), GCJ-02.
    public init(search: any PlaceSearch, navigation: NavigationController, origin: @escaping @Sendable () async -> GeoCoordinate?,
                clock: any NovaClock, tuning: TripTuning = TripTuning(), onLine: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (TripList) -> Void = { _ in }) {
        self.search = search
        self.navigation = navigation
        self.origin = origin
        self.clock = clock
        self.tuning = tuning
        self.onLine = onLine
        self.onChange = onChange
    }

    public var current: TripList { list }

    public func execute(_ call: ToolCall) async -> ToolResult {
        // The dispatcher validated the call (ToolCatalog.validate); this is the backstop for direct callers.
        if let code = ToolCatalog.validate(call) { return .failure(code) }
        switch call.name {
        case "make_trip_list": return await make(call.arguments)
        case "edit_trip_list": return await edit(call.arguments)
        case "route_trip": return await route(call.arguments)
        default: return .failure(.unknownTool)
        }
    }

    // MARK: make_trip_list

    private func make(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        guard case .array(let raw)? = args["places"] else { return .failure(.invalidFields) }
        let names = raw.compactMap(\.stringValue).map(TranscriptText.normalize)
        let city = args["city"]?.stringValue
        let generation = list.generation
        let here = await origin()
        let lookups = await resolve(names, city: city)
        guard list.generation == generation else { return .failure(.optionsStale) }
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
        list.replace(entries)
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
        onLine("trip list stops=\(list.count) not_found=\(result.code == .notFound ? 1 : 0) duplicates=0 ms=\(ms(since: started)) action=\(action) ok=\(result.ok ? "yes" : "no")")
        return result
    }

    private func editAction(_ action: String, _ args: JSONValue) async -> ToolResult {
        let index = Self.int(args["index"]), toIndex = Self.int(args["to_index"])
        let name = args["name"]?.stringValue.map(TranscriptText.normalize)
        let n = list.count
        if list.isEmpty, action != "add", action != "clear" { return failure(.noTripList) }
        switch action {
        case "read":
            return listResult(changed: "none", next: "按 stops 的顺序念清单，每个只念序号和名字。")
        case "clear":
            list.clear()
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
            return listResult(changed: "removed", next: "只说一句：去掉了\(removed)，现在清单有\(list.count)个地点。")
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
            let generation = list.generation
            let here = await origin()
            let lookup = await resolve([name], city: nil).first ?? .missing("failed")
            // §3 item 4: a newer change while this lookup ran wins; this one changes nothing.
            guard list.generation == generation else { return .failure(.optionsStale) }
            let place: Place
            switch lookup {
            case .found(let found): place = found
            case .keyMissing: return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有改清单。")
            case .missing(let reason):
                onLine("trip lookup index=1 ok=no reason=\(reason)")
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
        let asListed = args["order"]?.stringValue == "as_listed"
        let start = args["start"]?.boolValue ?? false
        guard !list.isEmpty else { return failure(.noTripList) }
        guard list.count >= 2 else {
            return .failure(.tripTooShort, advice: "清单里只有一个地点，串不成路线。请如实说明；要去这一个地方就用 navigate_to。")
        }
        if !asListed {
            let order = TripOrder.nearest(from: await origin(), list.stops.map(\.place.coordinate))
            list.reorder(order)
            changed()
        }
        let generation = list.generation
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
            guard list.generation == generation else {
                await navigation.dropKeptTrip()
                logLine(nil, started: false)
                return .failure(.optionsStale, advice: "清单在规划时改了，这条路线不算数。请如实说明，需要时再说串成路线。")
            }
            logLine(route, started: false)
            let (km, time) = Self.distanceAndTime(route)
            return routeResult(route, started: false,
                               next: "只说一句：经过\(stops.count)个地点，全程约\(km)公里，大约\(time)，问要不要开始导航；不要念每个地点，司机问时再念。")
        case .started(let route, let mode), .alreadyRunning(let route, let mode):
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
                    group.addTask { feed.yield((i, await Self.lookup(names[i], city: city, search: search))) }
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

    private func listResult(changed: String?, notFound: [String] = [], duplicates: [String] = [], next: String) -> ToolResult {
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

    private func changed() { onChange(list) }

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
