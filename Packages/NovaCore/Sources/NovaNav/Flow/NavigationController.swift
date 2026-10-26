import NovaKit
import NovaPorts
import NovaTools

/// contracts/navigation.md phases. Cancel resets to idle; there is no cancelled phase.
public enum NavigationPhase: String, Sendable, Hashable {
    case idle, resolvingDestination, awaitingDestinationSelection, calculatingRoute, awaitingRouteSelection
    case navigating, arrived, error
}

/// What the screen and the guards see of the flow. A snapshot, not the flow's own state.
public struct NavigationFlowState: Sendable, Hashable {
    public var phase: NavigationPhase = .idle
    public var generation: Generation = .initial
    public var places: [Place] = []
    public var destination: Place?
    public var routes: [RouteSummary] = []
    public var selectedRoute: RouteID?
    public var info: NaviInfo?
    public var lastGuidance: String?
    /// Amap's id of `lastGuidance`: the same sentence twice is two prompts (F-14).
    public var lastGuidanceID: GuidanceID?
    /// An along-route list is open over the running guidance (contracts/navigation.md keepGuidance).
    public var alongRouteList = false

    public init() {}

    public var navigating: Bool { phase == .navigating }
    public var listOpen: Bool {
        phase == .awaitingDestinationSelection || phase == .awaitingRouteSelection || alongRouteList
    }
}

public struct NavigationTuning: Sendable, Hashable {
    /// Candidate lists older than this are refused (`OPTIONS_STALE`).
    public var choiceLifetime = NovaDuration.seconds(120)
    /// Dispatcher waits (contracts/navigation.md): route request 10 s, start 8 s.
    public var routeWait = NovaDuration.seconds(10)
    public var startWait = NovaDuration.seconds(8)
    public var maxCandidates = 5
    public var searchRadiusMeters = 50_000
    public var mode: NaviMode = .emulator
    public init() {}
}

/// F-15 flow: search → pick → route → navigate → cancel, for `navigate_to`, `choose_navigation_option`
/// and `exit_navigation_mode`. Every request raises the generation; engine events of an older one
/// are dropped. Never claims a step the engine did not confirm (I-1).
public actor NavigationController: ToolExecutor {
    public static let tools: Set<String> = ["navigate_to", "choose_navigation_option", "exit_navigation_mode"]

    private let search: any PlaceSearch
    /// F-16 home/work; nil leaves 家/公司 to the dispatcher guard.
    private let saved: SavedPlaces?
    private let engine: any NaviEngine
    private let location: any LocationProvider
    private let clock: any NovaClock
    private let tuning: NavigationTuning
    private let onChange: @Sendable (NavigationFlowState) -> Void
    private var snapshot = NavigationFlowState()
    private var listedAt: NovaInstant?
    /// A start is awaiting the engine; a second pick in the same turn must not start again.
    private var startInFlight = false
    private var waiting: (kind: Wait, continuation: CheckedContinuation<NaviEngineEvent?, Never>)?
    private var listener: Task<Void, Never>?
    /// An answer that came while the request was still being sent (the actor is free during that await).
    private var early: [Wait: NaviEngineEvent] = [:]

    private enum Wait { case routes, started }

    public init(search: any PlaceSearch, engine: any NaviEngine, location: any LocationProvider,
                clock: any NovaClock, tuning: NavigationTuning = NavigationTuning(), saved: SavedPlaces? = nil,
                onChange: @escaping @Sendable (NavigationFlowState) -> Void = { _ in }) {
        self.saved = saved
        self.search = search
        self.engine = engine
        self.location = location
        self.clock = clock
        self.tuning = tuning
        self.onChange = onChange
    }

    /// Starts consuming engine events. Call once.
    public func start() {
        guard listener == nil else { return }
        let events = engine.events
        listener = Task { [weak self] in
            for await envelope in events { await self?.engineEvent(envelope) }
        }
    }

    public var current: NavigationFlowState { snapshot }

    public func execute(_ call: ToolCall) async -> ToolResult {
        switch call.name {
        case "navigate_to": return await navigate(call.arguments["destination"]?.stringValue ?? "")
        case "choose_navigation_option": return await choose(call.arguments)
        case "exit_navigation_mode": return await exit()
        default: return .failure(.unknownTool)
        }
    }

    // MARK: navigate_to

    private func navigate(_ destination: String) async -> ToolResult {
        // F-16: 家/公司 (whole utterance, never 家乐福) is the saved place or a refusal, never a POI search.
        // An unset slot is refused before anything stops, so the current route keeps going (I-14).
        if let saved, let slot = PlaceSlot.slot(for: destination) {
            guard let place = saved.place(slot) else {
                let code: ToolErrorCode = slot == .home ? .homeNotSet : .workNotSet
                return .failure(code, advice: ToolFailureAdvice.forCode(code))
            }
            if snapshot.navigating { await engine.stop(generation: snapshot.generation) }
            snapshot.routes = []
            snapshot.info = nil
            return await route(to: place)
        }
        if snapshot.navigating { await engine.stop(generation: snapshot.generation) }
        let generation = advance(to: .resolvingDestination)
        snapshot.places = []
        snapshot.routes = []
        snapshot.destination = nil
        snapshot.info = nil
        publish()
        var places: [Place] = []
        do {
            // F-16: stripped query first, verbatim once if it found nothing; nearby and categories by
            // distance. A stale or coarse fix is not used (text search, no city); Amap wants GCJ-02.
            let query = DestinationQuery(destination)
            let center = await usableFix()
            for keywords in query.attempts where places.isEmpty {
                if let center {
                    places = try await search.around(keywords, center: center,
                                                     radiusMeters: tuning.searchRadiusMeters, sort: query.sort)
                } else {
                    places = try await search.text(keywords, city: nil)
                }
                guard generation == snapshot.generation else { return .failure(.optionsStale) }
            }
        } catch let error as AmapWebError {
            guard generation == snapshot.generation else { return .failure(.optionsStale) }
            reset()
            return error == .keyMissing || error == .keyRejected
                ? .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有查到。")
                : .failure(.liveInfoUnavailable, advice: "地点查询失败了，请如实说没查到，可以请用户再说一遍。")
        } catch {
            reset()
            return .failure(.liveInfoUnavailable, advice: "地点查询失败了，请如实说没查到。")
        }
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        let top = Array(places.prefix(tuning.maxCandidates))
        guard !top.isEmpty else {
            reset()
            return .failure(.noCandidates, advice: "没有找到这个地点。请如实说没找到，请用户换个说法。")
        }
        if top.count == 1 { return await route(to: top[0]) }
        snapshot.phase = .awaitingDestinationSelection
        snapshot.places = top
        listedAt = clock.now
        publish()
        return .success([
            "status": "candidates_listed",
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "next": .string("屏幕上列出了\(top.count)个地点。只说一句：找到\(top.count)个地点，请说第几个。不要念列表。"),
        ])
    }

    // MARK: choose_navigation_option

    private func choose(_ args: JSONValue) async -> ToolResult {
        if snapshot.alongRouteList {
            if let stale = staleList() { return stale }
            switch pick(snapshot.places, args, distance: { $0.distanceMeters }, name: { $0.name }) {
            case .success(let index):
                // An explicit pick replaces the route: the old guidance stops first.
                let place = snapshot.places[index]
                await engine.stop(generation: snapshot.generation)
                snapshot.alongRouteList = false
                snapshot.routes = []
                snapshot.info = nil
                return await route(to: place)
            case .failure(let box):
                return box.result
            }
        }
        switch snapshot.phase {
        case .awaitingDestinationSelection:
            if let stale = staleList() { return stale }
            switch pick(snapshot.places, args, distance: { $0.distanceMeters }, name: { $0.name }) {
            case .success(let index): return await route(to: snapshot.places[index])
            case .failure(let box): return box.result
            }
        case .awaitingRouteSelection:
            if let stale = staleList() { return stale }
            if startInFlight {
                return .failure(.optionsNotReady, advice: "导航正在启动。请如实说正在启动，稍等一下。")
            }
            switch pickRoute(args) {
            case .success(let index): return await startGuidance(snapshot.routes[index])
            case .failure(let box): return box.result
            }
        case .resolvingDestination, .calculatingRoute:
            return .failure(.optionsNotReady, advice: "路线还在计算。请如实说还在计算，稍等一下。")
        case .navigating:
            return .failure(.noOptionsOnScreen, advice: "已经在导航了，屏幕上没有候选。请如实说明。")
        case .idle, .arrived, .error:
            return .failure(.noOptionsOnScreen, advice: "现在屏幕上没有候选列表。请如实说明，不要假装已经选择。")
        }
    }

    private func route(to place: Place) async -> ToolResult {
        let generation = advance(to: .calculatingRoute)
        snapshot.destination = place
        snapshot.places = []
        publish()
        await engine.calculateRoutes(RouteRequest(destination: place.coordinate, destinationName: place.name),
                                     generation: generation)
        let event = await wait(.routes, within: tuning.routeWait)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        guard case .routesReady(let routes) = event, !routes.isEmpty else {
            reset()
            return .failure(.routeCalculationFailed, advice: "路线规划失败了。请如实说没有算出路线。")
        }
        snapshot.phase = .awaitingRouteSelection
        snapshot.routes = Array(routes.prefix(3))
        snapshot.selectedRoute = snapshot.routes[0].id
        listedAt = clock.now
        publish()
        return .success([
            "status": "destination_selected",
            "destination": .string(place.name),
            "route_count": .int(Int64(snapshot.routes.count)),
            "routes": .array(snapshot.routes.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "next": .string("不要念路线细节。只说一句：有\(snapshot.routes.count)条路线，说第几条或者说开始导航。导航还没有开始。"),
        ])
    }

    private func startGuidance(_ route: RouteSummary) async -> ToolResult {
        let generation = snapshot.generation
        snapshot.selectedRoute = route.id
        early[.started] = nil
        startInFlight = true
        defer { startInFlight = false }
        publish()
        await engine.selectRoute(route.id, generation: generation)
        await engine.start(tuning.mode, generation: generation)
        let event = await wait(.started, within: tuning.startWait)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        guard event == .naviStarted else {
            await engine.stop(generation: generation)
            reset()
            return .failure(.startFailed, advice: "导航没有启动成功。请如实说明，不要说已经开始。")
        }
        snapshot.phase = .navigating
        snapshot.routes = [route]
        listedAt = nil
        publish()
        return .success([
            "status": "navigation_started",
            "destination": .string(snapshot.destination?.name ?? ""),
            "distance_km": .double(Self.km(route.lengthMeters)),
            "duration_min": .int(Int64(max(1, route.durationSeconds / 60))),
            "simulated_movement": .bool(tuning.mode == .emulator),
            "next": .string("说一句：导航已开始，大约多少分钟到。"),
        ])
    }

    // MARK: exit_navigation_mode

    private func exit() async -> ToolResult {
        if snapshot.alongRouteList {
            // Cancel with a list over kept guidance closes the list only.
            closeAlongRouteList()
            return .success(["status": "list_closed_guidance_kept", "next": "说一句：好的，继续按原路线导航。"])
        }
        switch snapshot.phase {
        case .navigating, .arrived:
            let generation = snapshot.generation
            await engine.stop(generation: generation)
            reset()
            return .success(["status": "navigation_stopped", "next": "说一句：导航已结束。"])
        case .awaitingDestinationSelection, .awaitingRouteSelection, .resolvingDestination, .calculatingRoute:
            await engine.stop(generation: snapshot.generation)
            reset()
            return .success(["status": "navigation_selection_cancelled", "next": "说一句：好的，已取消。"])
        case .idle, .error:
            return .success(["status": "no_navigation_active", "next": "如实说当前没有在导航。"])
        }
    }

    // MARK: query_live_info route_traffic

    /// Remaining distance and time of the running guidance, from the engine's own numbers.
    public func routeStatus() -> ToolResult {
        guard snapshot.navigating, let route = snapshot.routes.first else {
            return .failure(.notNavigating, advice: "现在没有在导航。请如实说明。")
        }
        let meters = snapshot.info?.remainingMeters ?? route.lengthMeters
        let seconds = snapshot.info?.remainingSeconds ?? route.durationSeconds
        var data: [String: JSONValue] = [
            "destination": .string(snapshot.destination?.name ?? ""),
            "remaining_km": .double(Self.km(meters)),
            "remaining_min": .int(Int64(max(1, seconds / 60))),
            "next": "按 remaining_km 和 remaining_min 用一句话回答，时间是导航引擎的估计。没有实时拥堵数据，不要编造路况。",
        ]
        if let road = snapshot.info?.nextRoadName, !road.isEmpty { data["next_road"] = .string(road) }
        return .success(data)
    }

    // MARK: Engine events

    private func engineEvent(_ envelope: NaviEngineEnvelope) {
        guard envelope.generation == snapshot.generation else { return }
        switch envelope.event {
        case .routesReady, .routeCalculationFailed:
            resume(.routes, with: envelope.event)
        case .naviStarted:
            resume(.started, with: envelope.event)
        case .naviInfo(let info):
            snapshot.info = info
            publish()
        case .guidanceText(let text, let id):
            snapshot.lastGuidance = text
            snapshot.lastGuidanceID = id
            publish()
        case .arrived:
            snapshot.phase = .arrived
            publish()
        case .naviStopped:
            if snapshot.phase == .navigating { reset() }
        case .cameraInfo:
            break
        }
    }

    private func wait(_ kind: Wait, within limit: NovaDuration) async -> NaviEngineEvent? {
        if let event = early.removeValue(forKey: kind) { return event }
        let deadline = clock.now + limit
        let clock = clock
        let timeout = Task { [weak self] in
            do { try await clock.sleep(until: deadline) } catch { return }
            await self?.resume(kind, with: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            waiting?.continuation.resume(returning: nil)
            waiting = (kind, continuation)
        }
    }

    private func resume(_ kind: Wait, with event: NaviEngineEvent?) {
        guard let pending = waiting, pending.kind == kind else {
            if let event { early[kind] = event }
            return
        }
        waiting = nil
        pending.continuation.resume(returning: event)
    }

    // MARK: Helpers

    // MARK: query_live_info along_route / place_details (F-18, F-16)

    /// Category keywords for `/v3/place/polygon` (catalog enum: fuel, charging, service_area, toilet).
    static let categories = ["fuel": "加油站", "charging": "充电站", "service_area": "服务区", "toilet": "厕所"]

    /// Up to 5 places of `category` in the route corridor, listed over the running guidance.
    public func alongRoute(category: String?) async -> ToolResult {
        guard snapshot.navigating else {
            return .failure(.notNavigating, advice: "现在没有在导航，不能查沿途。请如实说明，可以问附近的。")
        }
        guard let category, let keywords = Self.categories[category] else {
            return .failure(.invalidArgument, advice: "沿途只能查加油站、充电站、服务区或厕所。请如实说明。")
        }
        let line = snapshot.routes.first?.polyline ?? []
        let polygon = AlongRouteCorridor.polygon(line)
        guard !polygon.isEmpty else {
            return .failure(.liveInfoUnavailable, advice: "拿不到当前路线的形状，没法查沿途。请如实说明，不要编造。")
        }
        let generation = snapshot.generation
        let places: [Place]
        do {
            places = try await search.polygon(keywords, vertices: polygon)
        } catch {
            return LiveInfoFailure.result(error, what: "沿途的\(keywords)")
        }
        guard generation == snapshot.generation, snapshot.navigating else { return .failure(.optionsStale) }
        let top = Array(places.prefix(tuning.maxCandidates))
        guard !top.isEmpty else {
            // 0 results: the guidance was never touched (keepGuidance).
            return .failure(.noResults, advice: "沿途没有找到\(keywords)。请如实说明，导航继续。")
        }
        snapshot.places = top
        snapshot.alongRouteList = true
        listedAt = clock.now
        publish()
        return .success([
            "status": "along_route_listed",
            "category": .string(category),
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "guidance_kept": true,
            "next": .string("只说一句：沿途找到\(top.count)个\(keywords)，说第几个可以改去那里，导航仍按原路线继续。"),
        ])
    }

    /// Details of the destination or of the n-th place on screen, from Amap's place detail only.
    public func placeDetails(target: JSONValue?) async -> ToolResult {
        let place: Place
        switch target {
        case .string("destination"):
            guard let destination = snapshot.destination else {
                return .failure(.noDestination, advice: "现在没有导航目的地。请如实说明。")
            }
            place = destination
        case .some(let value):
            guard let index = Self.index(["index": value]) else {
                return .failure(.invalidArgument, advice: "请用户说是目的地还是第几个。")
            }
            guard index >= 1, index <= snapshot.places.count else {
                return snapshot.places.isEmpty
                    ? .failure(.noOptionsOnScreen, advice: "屏幕上没有候选列表。请如实说明。")
                    : Self.outOfRange(snapshot.places.count).result
            }
            place = snapshot.places[index - 1]
        case .none:
            return .failure(.invalidArgument, advice: "请用户说是目的地还是第几个。")
        }
        let detail: Place?
        do {
            detail = try await search.detail(id: place.id)
        } catch {
            return LiveInfoFailure.result(error, what: "\(place.name)的详情")
        }
        guard let detail else {
            return .failure(.noResults, advice: "没有查到\(place.name)的详情。请如实说明，不要编造营业时间。")
        }
        var object: [String: JSONValue] = ["name": .string(detail.name)]
        if let address = detail.address { object["address"] = .string(address) }
        if let hours = detail.openingHours { object["opening_hours"] = .string(hours) }
        if let phone = detail.phone { object["phone"] = .string(phone) }
        object["next"] = .string(detail.openingHours == nil
            ? "高德没有给出营业时间。只按这些字段回答；问营业时间就如实说查不到，不要编造。"
            : "只按这些字段用一两句话回答，不要编造。")
        return .success(object)
    }

    private func closeAlongRouteList() {
        snapshot.alongRouteList = false
        snapshot.places = []
        listedAt = nil
        publish()
    }

    /// The latest fix if F-16 may use it, converted to GCJ-02 for Amap.
    private func usableFix() async -> GeoCoordinate? {
        guard let fix = await location.latestFix(), LocationQuality.of(fix, at: clock.now) != nil else { return nil }
        return CoordinateConverter.gcj02(fix.coordinate)
    }

    private func advance(to phase: NavigationPhase) -> Generation {
        snapshot.generation = snapshot.generation.next()
        snapshot.phase = phase
        early = [:]
        waiting?.continuation.resume(returning: nil)
        waiting = nil
        return snapshot.generation
    }

    private func reset() {
        snapshot.alongRouteList = false
        _ = advance(to: .idle)
        snapshot.places = []
        snapshot.routes = []
        snapshot.destination = nil
        snapshot.selectedRoute = nil
        snapshot.info = nil
        snapshot.lastGuidance = nil
        snapshot.lastGuidanceID = nil
        listedAt = nil
        publish()
    }

    private func publish() { onChange(snapshot) }

    private func staleList() -> ToolResult? {
        guard let listedAt, clock.now - listedAt > tuning.choiceLifetime else { return nil }
        if snapshot.alongRouteList { closeAlongRouteList() } else { reset() }
        return .failure(.optionsStale, advice: "候选列表已经过期。请如实说明，请用户重新说目的地。")
    }

    private func pick<T>(_ items: [T], _ args: JSONValue, distance: (T) -> Int?,
                         name: (T) -> String) -> Result<Int, ToolResultBox> {
        if let index = Self.index(args) {
            return index <= items.count ? .success(index - 1) : .failure(Self.outOfRange(items.count))
        }
        if let wanted = args["name"]?.stringValue {
            let matches = items.indices.filter { name(items[$0]).contains(wanted) || wanted.contains(name(items[$0])) }
            if matches.count == 1 { return .success(matches[0]) }
            return .failure(matches.isEmpty
                ? ToolResultBox(.failure(.noMatch, advice: "屏幕上没有这个名字。请如实说明，请用户说第几个。"))
                : ToolResultBox(.failure(.ambiguous, advice: "有多个候选都符合这个名字。请用户说第几个。")))
        }
        if args["preference"]?.stringValue == "nearest" {
            let known = items.indices.compactMap { i in distance(items[i]).map { (i, $0) } }
            guard let nearest = known.min(by: { $0.1 < $1.1 }) else {
                return .failure(ToolResultBox(.failure(.distanceUnknown, advice: "不知道距离。请用户说第几个。")))
            }
            return .success(nearest.0)
        }
        if args["preference"] != nil {
            return .failure(ToolResultBox(.failure(.preferenceNotForDestinations,
                                                   advice: "这是地点列表，不能按路线偏好选。请用户说第几个。")))
        }
        return .failure(ToolResultBox(.failure(.invalidFields)))
    }

    private func pickRoute(_ args: JSONValue) -> Result<Int, ToolResultBox> {
        let routes = snapshot.routes
        if let index = Self.index(args) {
            return index <= routes.count ? .success(index - 1) : .failure(Self.outOfRange(routes.count))
        }
        guard let preference = args["preference"]?.stringValue else {
            return .failure(ToolResultBox(.failure(.invalidFields, advice: "请用户说第几条路线。")))
        }
        let indices = Array(routes.indices)
        let chosen: Int? = switch preference {
        case "recommended": 0
        case "fastest": indices.min { routes[$0].durationSeconds < routes[$1].durationSeconds }
        case "shortest": indices.min { routes[$0].lengthMeters < routes[$1].lengthMeters }
        case "no_toll": indices.min { routes[$0].tollYuan < routes[$1].tollYuan }
        case "fewest_lights": indices.min { routes[$0].trafficLights < routes[$1].trafficLights }
        default: nil
        }
        guard let chosen else {
            return .failure(ToolResultBox(.failure(.preferenceNotForRoutes, advice: "请用户说第几条路线。")))
        }
        return .success(chosen)
    }

    private static func index(_ args: JSONValue) -> Int? {
        switch args["index"] {
        case .int(let v): Int(v)
        case .double(let v): Int(exactly: v)
        case .string(let s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    private static func outOfRange(_ count: Int) -> ToolResultBox {
        ToolResultBox(.failure(.outOfRange, advice: "没有这一项，屏幕上只有\(count)项。请如实说明。"))
    }

    static func km(_ meters: Int) -> Double { (Double(meters) / 100).rounded() / 10 }

    static func describe(_ place: Place, index: Int) -> JSONValue {
        var object: [String: JSONValue] = ["index": .int(Int64(index)), "name": .string(place.name)]
        if let address = place.address { object["address"] = .string(address) }
        if let meters = place.distanceMeters { object["distance_km"] = .double(km(meters)) }
        return .object(object)
    }

    static func describe(_ route: RouteSummary, index: Int) -> JSONValue {
        var object: [String: JSONValue] = [
            "index": .int(Int64(index)),
            "distance_km": .double(km(route.lengthMeters)),
            "duration_min": .int(Int64(max(1, route.durationSeconds / 60))),
            "toll_yuan": .int(Int64(route.tollYuan)),
            "traffic_lights": .int(Int64(route.trafficLights)),
        ]
        if let label = route.label { object["label"] = .string(label) }
        return .object(object)
    }
}

/// `Result` needs an `Error` failure; this carries the ready tool result.
struct ToolResultBox: Error {
    let result: ToolResult
    init(_ result: ToolResult) { self.result = result }
}
