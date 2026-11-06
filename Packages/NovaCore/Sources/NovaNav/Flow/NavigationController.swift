import NovaKit
import NovaPorts
import NovaTools

/// contracts/navigation.md phases. Cancel resets to idle; there is no cancelled phase.
public enum NavigationPhase: String, Sendable, Hashable {
    case idle, resolvingDestination, awaitingDestinationSelection, calculatingRoute, awaitingRouteSelection
    case navigating, arrived, error
}

/// One tap target on the trip's screen: `row` is the route's 0-based place in the calculation (`UIIntent.choose`).
public struct AlternativeRoute: Sendable, Hashable {
    public let row: Int
    public let route: RouteSummary
    /// 「第2条 · 约20分钟」, with 更快 / 更短 / 不收费 against the running route.
    public let text: String
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
    /// F-15a: a recalculation is running (the HUD shows 「重新规划中」); the phase stays `navigating`.
    public var rerouting = false
    /// F-15a: the running trip's mode (read when guidance starts). The map and HUD draw by it.
    public var mode: NaviMode = .emulator
    /// F-15a §2.5 (T-040h): the other routes of the trip's calculation while navigating, for a tap that changes the
    /// route (I-6: the same `choose_navigation_option` index as 「换第N条」).
    public var alternatives: [AlternativeRoute] = []
    /// The route buttons on screen: none while a list is open (a tap there picks a list row), and in 真实导航 only
    /// 「第N条」, since a change recalculates from here and the earlier minutes no longer hold.
    public var routeTapTargets: [AlternativeRoute] {
        guard phase == .navigating, !alongRouteList else { return [] }
        guard mode == .gps else { return alternatives }
        return alternatives.map { AlternativeRoute(row: $0.row, route: $0.route, text: "第\($0.row + 1)条") }
    }

    public init() {}

    public var navigating: Bool { phase == .navigating }
    public var listOpen: Bool {
        phase == .awaitingDestinationSelection || phase == .awaitingRouteSelection || alongRouteList
    }
}

extension NavigationFlowState {
    /// F-18 §21 item 1 (T-046i): the destination's cleaned name while navigating (a list over guidance keeps it)
    /// or arrived; nil otherwise.
    public var currentDestination: String? {
        guard phase == .navigating || phase == .arrived else { return nil }
        return SearchPlace.clean(destination?.name)
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

/// F-16 §14 (T-042c): near-first search, sound-alike match and confirm by score for named places. Without it
/// (`nearFirst: nil`) the F-16 §4 search is used. Reads app state and the uplink gate's turn count only, never a
/// transcript (F-05a §6).
public struct NearFirstSearch: Sendable {
    let match: DestinationMatch
    let geocoder: (any ReverseGeocoder)?
    let driverTurns: @Sendable () async -> Int
    let onLine: @Sendable (DestinationSearchLine) -> Void

    /// `driverTurns` is the count of driver utterances the uplink gate closed (F-04a, `GuardContext.closedTurns`).
    /// `onLine` gets one item 9 line per call.
    public init(match: DestinationMatch, geocoder: (any ReverseGeocoder)?, driverTurns: @escaping @Sendable () async -> Int,
                onLine: @escaping @Sendable (DestinationSearchLine) -> Void = { _ in }) {
        self.match = match
        self.geocoder = geocoder
        self.driverTurns = driverTurns
        self.onLine = onLine
    }

    /// Item 6: what she is told after the second no.
    public static let rejectedText = "这个地名刚被否定了，请问司机要去哪里。"
    /// Item 3: no fit.
    public static let noFitText = "没有找到和这个名字相符的地点。请只问一句司机要去哪里，不要重复刚才听到的地名。"
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
    /// F-15a §2.1: 设置 → 导航方式, read when a route is requested and when guidance starts.
    private let mode: @Sendable () -> NaviMode
    private let onChange: @Sendable (NavigationFlowState) -> Void
    private var snapshot = NavigationFlowState()
    private var listedAt: NovaInstant?
    /// A start is awaiting the engine; a second pick in the same turn must not start again.
    private var startInFlight = false
    /// F-15a §2.5 (T-040h): every route of the trip's calculation, recommended first; the driver may change to
    /// one of them while navigating.
    private var calculated: [RouteSummary] = []
    private var waiting: (kind: Wait, continuation: CheckedContinuation<NaviEngineEvent?, Never>)?
    private var listener: Task<Void, Never>?
    /// An answer that came while the request was still being sent (the actor is free during that await).
    private var early: [Wait: NaviEngineEvent] = [:]

    private enum Wait { case routes, started }

    private let nearFirst: NearFirstSearch?
    /// F-16 §14 item 6: the last listed named-place search, for a no and the next candidate.
    private struct Asked {
        let destination: String
        let ranked: [ScoredPlace]
        let step: DestinationSearchStep
        var offered = 0
        var advanced = false
    }
    private var asked: Asked?
    private var rejectedName: String?
    /// F-16 §14 item 5: listed place ids that need a yes on a later driver turn, and the turn count when listed.
    private var confirm: (ids: Set<String>, turn: Int)?

    public init(search: any PlaceSearch, engine: any NaviEngine, location: any LocationProvider,
                clock: any NovaClock, tuning: NavigationTuning = NavigationTuning(), saved: SavedPlaces? = nil,
                mode: (@Sendable () -> NaviMode)? = nil, nearFirst: NearFirstSearch? = nil,
                onChange: @escaping @Sendable (NavigationFlowState) -> Void = { _ in }) {
        self.nearFirst = nearFirst
        self.saved = saved
        self.search = search
        self.engine = engine
        self.location = location
        self.clock = clock
        self.tuning = tuning
        let fixed = tuning.mode
        self.mode = mode ?? { fixed }
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
        case "choose_navigation_option": return await choose(call.arguments, fromTap: call.id.rawValue.hasPrefix("ui"))
        case "exit_navigation_mode": return await exit()
        default: return .failure(.unknownTool)
        }
    }

    // MARK: navigate_to

    private func navigate(_ destination: String) async -> ToolResult {
        confirm = nil
        // F-05a §6 (replaces the P61 word guard): while guiding, a new place is listed over the running route;
        // the route changes only when the driver picks one.
        if snapshot.navigating {
            // F-16 §14: a named place while guiding goes through the same near-first match (item 10 exempts only
            // along-route search); a saved slot and categories keep the list over guidance.
            let slot = saved == nil ? nil : PlaceSlot.slot(for: destination)
            if let nearFirst, slot == nil, DestinationQuery(destination).sort == .weight {
                return await nearFirstNavigate(DestinationQuery(destination), nearFirst)
            }
            return await listOverGuidance(destination)
        }
        // F-16: 家/公司 (whole utterance, never 家乐福) is the saved place or a refusal, never a POI search.
        // An unset slot is refused before anything stops, so the current route keeps going (I-14).
        if let saved, let slot = PlaceSlot.slot(for: destination) {
            guard let place = saved.place(slot) else {
                let code: ToolErrorCode = slot == .home ? .homeNotSet : .workNotSet
                return .failure(code, advice: ToolFailureAdvice.forCode(code))
            }
            snapshot.routes = []
            snapshot.info = nil
            return await route(to: place)
        }
        // F-16 §14 item 10: 附近的X and category searches keep the F-16 §4 search.
        if let nearFirst, DestinationQuery(destination).sort == .weight {
            return await nearFirstNavigate(DestinationQuery(destination), nearFirst)
        }
        let generation = advance(to: .resolvingDestination)
        snapshot.places = []
        snapshot.routes = []
        snapshot.destination = nil
        snapshot.info = nil
        publish()
        let found = await findPlaces(destination, current: { [generation] in generation == self.snapshot.generation })
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        let top: [Place]
        switch found {
        case .success(let places): top = places
        case .failure(let box):
            reset()
            return box.result
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

    /// Up to `maxCandidates` places for `destination`, or the failure to return. F-16: stripped query first,
    /// verbatim once if it found nothing; nearby and categories by distance. A stale or coarse fix is not used
    /// (text search, no city); Amap wants GCJ-02. `current` is false once a newer request owns the flow.
    private func findPlaces(_ destination: String, current: () -> Bool) async -> Result<[Place], ToolResultBox> {
        var places: [Place] = []
        do {
            let query = DestinationQuery(destination)
            let center = await usableFix()
            for keywords in query.attempts where places.isEmpty {
                if let center {
                    places = try await search.around(keywords, center: center,
                                                     radiusMeters: tuning.searchRadiusMeters, sort: query.sort)
                } else {
                    places = try await search.text(keywords, city: nil)
                }
                guard current() else { return .failure(ToolResultBox(.failure(.optionsStale))) }
            }
        } catch {
            return .failure(Self.searchFailure(error))
        }
        let top = Array(places.prefix(tuning.maxCandidates))
        guard !top.isEmpty else {
            return .failure(ToolResultBox(.failure(.noCandidates, advice: "没有找到这个地点。请如实说没找到，请用户换个说法。")))
        }
        return .success(top)
    }

    private static func searchFailure(_ error: any Error) -> ToolResultBox {
        guard let error = error as? AmapWebError else {
            return ToolResultBox(.failure(.liveInfoUnavailable, advice: "地点查询失败了，请如实说没查到。"))
        }
        return ToolResultBox(error == .keyMissing || error == .keyRejected
            ? .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有查到。")
            : .failure(.liveInfoUnavailable, advice: "地点查询失败了，请如实说没查到，可以请用户再说一遍。"))
    }

    // MARK: F-16 §14 near-first search

    private func nearFirstNavigate(_ query: DestinationQuery, _ near: NearFirstSearch) async -> ToolResult {
        let key = query.stripped
        let match = near.match
        let exhausted = asked.map { $0.destination == key && ($0.advanced || $0.offered + 1 >= $0.ranked.count) } ?? false
        if rejectedName == key || exhausted {
            let step = asked?.step ?? .country
            if snapshot.alongRouteList { closeAlongRouteList() } else if !snapshot.navigating, snapshot.listOpen { reset() }
            asked = nil
            rejectedName = key
            near.onLine(DestinationSearchLine(destination: key, step: step, count: 0, top: nil, score: 0, km: 0,
                                              check: .rejected))
            return .failure(.destinationRejected, advice: NearFirstSearch.rejectedText)
        }
        if var again = asked, again.destination == key {
            // Item 6: she asked and the driver said no; the same name once more is the next candidate.
            again.offered += 1
            again.advanced = true
            asked = again
            let next = again.ranked[again.offered]
            let guiding = snapshot.navigating
            let turn = await near.driverTurns()
            guard guiding == snapshot.navigating else { return .failure(.optionsStale) }
            if guiding {
                snapshot.alongRouteList = true
            } else {
                _ = advance(to: .awaitingDestinationSelection)
                snapshot.routes = []
                snapshot.destination = nil
            }
            snapshot.places = [next.place]
            listedAt = clock.now
            confirm = ([next.place.id], turn)
            publish()
            let check: DestinationCheck = match.isFar(next) ? .farOnly : .ask
            near.onLine(Self.line(key, again.step, [next], check))
            return .success([
                "status": .string(check == .farOnly ? "far_only" : "next_candidate"),
                "check": .string(check.rawValue),
                "count": 1,
                "candidates": .array([Self.describe(next, index: 1)]),
                "next": .string(Self.question(next, check: check, destination: key)),
            ])
        }
        asked = nil
        rejectedName = nil
        // While guiding nothing stops: the list goes over the running route (F-05a §6).
        let guiding = snapshot.navigating
        let generation: Generation
        if guiding {
            generation = snapshot.generation
        } else {
            generation = advance(to: .resolvingDestination)
            snapshot.places = []
            snapshot.routes = []
            snapshot.destination = nil
            snapshot.info = nil
            publish()
        }
        let current = { [generation] in generation == self.snapshot.generation && self.snapshot.navigating == guiding }
        let found: (step: DestinationSearchStep, places: [Place], center: GeoCoordinate?)
        do {
            found = try await nearSearch(query, near, current: current)
        } catch is CancellationError {
            return .failure(.optionsStale)
        } catch {
            if !guiding { reset() }
            return Self.searchFailure(error).result
        }
        guard current() else { return .failure(.optionsStale) }
        let top = Array(match.rank(found.places, destination: key, from: found.center).prefix(tuning.maxCandidates))
        let check = match.check(top)
        near.onLine(Self.line(key, found.step, top, check))
        if check == .none {
            if !guiding { reset() }
            return .failure(.noCandidates, advice: NearFirstSearch.noFitText)
        }
        if check == .sure, top.count == 1, !guiding { return await route(to: top[0].place) }
        // Item 5: the turn is read after the search, so an utterance during the search is not the later turn.
        let turn = await near.driverTurns()
        guard current() else { return .failure(.optionsStale) }
        if guiding {
            snapshot.alongRouteList = true
        } else {
            snapshot.phase = .awaitingDestinationSelection
        }
        snapshot.places = top.map(\.place)
        listedAt = clock.now
        // Item 5: only the sure top candidate goes without a separate yes.
        let ids = top.enumerated().filter { $0.offset != 0 || check != .sure || match.isFar($0.element) }
            .map(\.element.place.id)
        confirm = (Set(ids), turn)
        asked = Asked(destination: key, ranked: top, step: found.step)
        publish()
        let status = switch check {
        case _ where guiding: "candidates_listed_over_guidance"
        case .sure: "candidates_listed"
        case .farOnly: "far_only"
        default: "confirm_candidate"
        }
        return .success([
            "status": .string(status),
            "guidance_kept": .bool(guiding),
            "check": .string(check.rawValue),
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "next": .string(Self.question(top[0], check: check, destination: key)),
        ])
    }

    /// Item 1: around 50 km, city text with `citylimit`, the place-type word around; nationwide only when another
    /// region is named or all of those found nothing. Stripped query first, verbatim after (F-16 §4).
    private func nearSearch(_ query: DestinationQuery, _ near: NearFirstSearch, current: () -> Bool) async throws
        -> (step: DestinationSearchStep, places: [Place], center: GeoCoordinate?) {
        let center = await usableFix()
        var region: PlaceRegion?
        if let center, let geocoder = near.geocoder { region = try? await geocoder.region(at: center) }
        guard current() else { throw CancellationError() }
        let radius = near.match.tuning.aroundRadiusMeters
        var near: [(DestinationSearchStep, String)] = []
        if center != nil {
            for keywords in query.attempts {
                near += DestinationMatch.nearSteps(keywords, hasCity: region?.adcode != nil).map { ($0, keywords) }
            }
        }
        let found = try await run(near, center: center, region: region, radius: radius, current: current)
        // Nationwide only after the near steps: when they found nothing, or another province or city is named
        // (then both are ranked together, so 中山路 nearby still wins).
        guard found.places.isEmpty
            || DestinationMatch.namesOtherRegion(query.stripped, carAddress: region?.formatted) else {
            return (found.step, found.places, center)
        }
        let country = try await run(query.attempts.map { (.country, $0) }, center: center, region: region,
                                    radius: radius, current: current)
        if country.places.isEmpty { return (found.places.isEmpty ? .country : found.step, found.places, center) }
        let nearIDs = Set(found.places.map(\.id))
        return (.country, found.places + country.places.filter { !nearIDs.contains($0.id) }, center)
    }

    private func run(_ plan: [(DestinationSearchStep, String)], center: GeoCoordinate?, region: PlaceRegion?, radius: Int,
                     current: () -> Bool) async throws -> (step: DestinationSearchStep, places: [Place]) {
        for (step, keywords) in plan {
            let places: [Place]
            switch (step, center) {
            case (.around, let center?):
                places = try await search.aroundOnly(keywords, center: center, radiusMeters: radius, sort: .weight)
            case (.type, let center?):
                places = try await search.aroundOnly(DestinationMatch.typeWord(keywords) ?? keywords, center: center,
                                                     radiusMeters: radius, sort: .weight)
            case (.city, _):
                places = try await search.text(keywords, city: region?.adcode, cityLimit: true)
            default:
                places = try await search.text(keywords, city: nil)
            }
            guard current() else { throw CancellationError() }
            if !places.isEmpty { return (step, places) }
        }
        return (.country, [])
    }

    private static func line(_ destination: String, _ step: DestinationSearchStep, _ ranked: [ScoredPlace],
                             _ check: DestinationCheck) -> DestinationSearchLine {
        DestinationSearchLine(destination: destination, step: step, count: ranked.count, top: ranked.first?.place.name,
                              score: ranked.first?.score ?? 0, km: ranked.first?.km ?? 0, check: check)
    }

    /// Items 3–4: what she says about the top candidate.
    private static func question(_ top: ScoredPlace, check: DestinationCheck, destination: String) -> String {
        let km = DestinationMatch.kmText(top.km ?? 0)
        switch check {
        case .sure: return "找到\(top.place.name)，在\(km)公里外，说第一个就去，或说第几个。"
        case .farOnly:
            return "附近没找到\(destination)，最近的在\(km)公里外的\(top.place.city ?? top.place.district ?? "外地")，要去那里吗？"
        default: return "是去\(top.place.name)吗？在\(km)公里外。"
        }
    }

    /// Item 5: an unsure, far or no-fit candidate is refused until a later driver turn. A tap is itself the yes (I-6).
    private func confirmRefusal(_ place: Place, fromTap: Bool) async -> ToolResult? {
        guard let nearFirst, !fromTap, let pending = confirm, pending.ids.contains(place.id) else { return nil }
        let now = await nearFirst.driverTurns()
        guard now <= pending.turn else { return nil }
        return .failure(.confirmFirst,
                        advice: "还没有得到司机的确认。只问一句是不是去\(place.name)，等司机回答后再选，不要说已经开始导航。")
    }

    /// While guiding: the places are listed over the running route (as along-route results); nothing stops
    /// until a pick, which replaces the route (`choose` on the along-route list).
    private func listOverGuidance(_ destination: String) async -> ToolResult {
        let generation = snapshot.generation
        let top: [Place]
        if let saved, let slot = PlaceSlot.slot(for: destination) {
            guard let place = saved.place(slot) else {
                let code: ToolErrorCode = slot == .home ? .homeNotSet : .workNotSet
                return .failure(code, advice: ToolFailureAdvice.forCode(code))
            }
            top = [place]
        } else {
            let found = await findPlaces(destination, current: { [generation] in
                generation == self.snapshot.generation && self.snapshot.navigating
            })
            switch found {
            case .success(let places): top = places
            case .failure(let box): return box.result
            }
        }
        guard generation == snapshot.generation, snapshot.navigating else { return .failure(.optionsStale) }
        snapshot.places = top
        snapshot.alongRouteList = true
        listedAt = clock.now
        publish()
        return .success([
            "status": "candidates_listed_over_guidance",
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "guidance_kept": true,
            "next": .string("屏幕上列出了\(top.count)个地点，导航仍按原路线继续。只说一句：找到\(top.count)个，说第几个可以改去那里。不要说已经改了路线。"),
        ])
    }

    // MARK: choose_navigation_option

    private func choose(_ args: JSONValue, fromTap: Bool = false) async -> ToolResult {
        if snapshot.alongRouteList {
            if let stale = staleList() { return stale }
            switch pick(snapshot.places, args, distance: { $0.distanceMeters }, name: { $0.name }) {
            case .success(let index):
                // An explicit pick replaces the route: the old guidance stops first.
                // Capture the pick and close the list before suspending, so an exit during the stop
                // does not treat it as an open list.
                let place = snapshot.places[index]
                let generation = snapshot.generation
                if let refusal = await confirmRefusal(place, fromTap: fromTap) { return refusal }
                guard generation == snapshot.generation, snapshot.alongRouteList else { return .failure(.optionsStale) }
                asked = nil
                confirm = nil
                snapshot.alongRouteList = false
                await engine.stop(generation: generation)
                // 算了 or a new request while the old guidance stopped: this pick is stale.
                guard generation == snapshot.generation else { return .failure(.optionsStale) }
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
            case .success(let index):
                let place = snapshot.places[index]
                let generation = snapshot.generation
                if let refusal = await confirmRefusal(place, fromTap: fromTap) { return refusal }
                guard generation == snapshot.generation else { return .failure(.optionsStale) }
                asked = nil
                confirm = nil
                return await route(to: place)
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
            return await changeRoute(args)
        case .idle, .arrived, .error:
            return .failure(.noOptionsOnScreen, advice: "现在屏幕上没有候选列表。请如实说明，不要假装已经选择。")
        }
    }

    private func route(to place: Place) async -> ToolResult {
        // F-15a §2.2 (OQ-NAVM-2): 真实导航 starts only from a usable fix; never the demo origin.
        if mode() == .gps, let refusal = await noUsableFix() {
            reset()
            return refusal
        }
        let generation = advance(to: .calculatingRoute)
        snapshot.destination = place
        snapshot.places = []
        publish()
        await engine.calculateRoutes(RouteRequest(destination: place.coordinate, destinationName: place.name),
                                     generation: generation)
        // A newer request took over while the engine was busy: its event is not ours to wait for.
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        let event = await wait(.routes, within: tuning.routeWait)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        guard case .routesReady(let routes) = event, !routes.isEmpty else {
            reset()
            return .failure(.routeCalculationFailed, advice: "路线规划失败了。请如实说没有算出路线。")
        }
        // F-15a §2.5 (T-040h): no route list to wait on; guidance starts on the recommended route at once.
        calculated = Array(routes.prefix(3))
        snapshot.routes = calculated
        return await startGuidance(calculated[0])
    }

    /// F-15a §2.5 (T-040h): the other routes of the calculation, for her one short offer.
    private func alternatives(besides chosen: RouteSummary) -> (data: [JSONValue], offer: String?) {
        let others = calculated.enumerated().filter { $0.element.id != chosen.id }
        let data = others.map { Self.describe($0.element, index: $0.offset + 1) }
        let offer: String? = if others.contains(where: { $0.element.durationSeconds < chosen.durationSeconds }) {
            "还有一条更快的，要换吗？"
        } else if others.contains(where: { $0.element.lengthMeters < chosen.lengthMeters }) {
            "还有一条更短的，要换吗？"
        } else if chosen.tollYuan > 0, others.contains(where: { $0.element.tollYuan == 0 }) {
            "还有一条不收费的，要换吗？"
        } else {
            nil
        }
        return (data, offer)
    }

    static func alternativeRoutes(_ calculated: [RouteSummary], running: RouteSummary) -> [AlternativeRoute] {
        calculated.enumerated().compactMap { index, other in
            guard other.id != running.id else { return nil }
            var notes: [String] = []
            if other.durationSeconds < running.durationSeconds { notes.append("更快") }
            if other.lengthMeters < running.lengthMeters { notes.append("更短") }
            if other.tollYuan == 0, running.tollYuan > 0 { notes.append("不收费") }
            let minutes = max(1, other.durationSeconds / 60)
            let text = (["第\(index + 1)条", "约\(minutes)分钟"] + notes).joined(separator: " · ")
            return AlternativeRoute(row: index, route: other, text: text)
        }
    }

    private func noUsableFix() async -> ToolResult? {
        if await location.authorization() == .denied {
            return .failure(.locationPermissionDenied, advice: "没有定位权限，真实导航不能开始。请如实说：请在设置里打开定位。")
        }
        guard let fix = await location.latestFix(), LocationQuality.of(fix, at: clock.now) != nil else {
            return .failure(.noLocation, advice: "还没有定位，真实导航不能开始。请如实说：还没有定位，暂时不能导航。")
        }
        return nil
    }

    private func startGuidance(_ route: RouteSummary, replacing label: String? = nil) async -> ToolResult {
        let replacing = label != nil
        let previous = snapshot.routes.first
        let generation = snapshot.generation
        let mode = mode()
        snapshot.selectedRoute = route.id
        early[.started] = nil
        startInFlight = true
        defer { startInFlight = false }
        publish()
        await engine.selectRoute(route.id, generation: generation)
        await engine.start(mode, generation: generation)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        let event = await wait(.started, within: tuning.startWait)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        guard event == .naviStarted else {
            // A failed route change keeps the trip on its current route (T-040h).
            if replacing, let old = previous {
                snapshot.routes = [old]
                snapshot.selectedRoute = old.id
                publish()
                await engine.selectRoute(old.id, generation: generation)
                await engine.start(mode, generation: generation)
                return .failure(.startFailed, advice: "没有换成功，继续按原路线导航。请如实说明。")
            }
            // Reset first so a request that lands while the engine stops is not wiped out.
            reset()
            await engine.stop(generation: generation)
            return .failure(.startFailed, advice: "导航没有启动成功。请如实说明，不要说已经开始。")
        }
        snapshot.phase = .navigating
        snapshot.mode = mode
        snapshot.routes = [route]
        // A restart cancels any off-route recalculation in flight, so its 重新规划中 never ends on its own.
        snapshot.rerouting = false
        snapshot.alternatives = Self.alternativeRoutes(calculated, running: route)
        listedAt = nil
        publish()
        let minutes = max(1, route.durationSeconds / 60)
        let (others, offer) = alternatives(besides: route)
        let started = mode == .emulator ? "已开始模拟导航" : "已开始导航"
        var sentence = replacing ? "已换成\(label ?? "")路线，大约\(minutes)分钟。" : "\(started)，大约\(minutes)分钟。" + (offer ?? "")
        // F-16 §14 item 8: name, km and hours+minutes; a long trip asks once more and a no cancels.
        var longTrip = false
        if let nearFirst, !replacing {
            let start = nearFirst.match.startSentence(name: snapshot.destination?.name ?? "", meters: route.lengthMeters,
                                                      seconds: route.durationSeconds)
            longTrip = start.longTrip
            sentence = "\(started)，" + start.text + (longTrip ? "" : (offer ?? ""))
        }
        // Item 8: the cancel rule stays outside what she says.
        let ifNo: JSONValue = longTrip ? "如果司机说不去，调用 exit_navigation_mode 取消导航。" : .null
        return .success([
            "status": replacing ? "route_changed" : "navigation_started",
            "destination": .string(snapshot.destination?.name ?? ""),
            "distance_km": .double(Self.km(route.lengthMeters)),
            "duration_min": .int(Int64(minutes)),
            "simulated_movement": .bool(mode == .emulator),
            "long_trip": .bool(longTrip),
            "if_driver_says_no": ifNo,
            "alternatives": .array(others),
            // F-15a §2.5: what a plain 好 / 换 after her offer means.
            "offer_preference": offer.map { $0.contains("更快") ? "fastest" : $0.contains("更短") ? "shortest" : "no_toll" }
                .map(JSONValue.string) ?? .null,
            "next": .string(longTrip ? "只说一句「\(sentence)」，不要念其他路线，也不要念工具名。"
                            : "只说一句：\(sentence)不要念其他路线。"),
        ])
    }

    /// F-15a §2.5 (T-040h): while navigating, 「换最快的」「不走高速」「换第二条」 replace the route with one of the
    /// same calculation; one trip, never a second one.
    private func changeRoute(_ args: JSONValue) async -> ToolResult {
        if startInFlight {
            return .failure(.optionsNotReady, advice: "正在换路线。请如实说正在换，稍等一下。")
        }
        var options = calculated
        // 真实导航: the trip has moved, so the routes come from the current position (T-040h); the trip keeps
        // driving its route while they are calculated, and on any failure.
        let fresh = snapshot.mode == .gps
        if fresh {
            let generation = snapshot.generation
            startInFlight = true
            let routes = await engine.recalculateFromHere(generation: generation)
            guard generation == snapshot.generation else { return .failure(.optionsStale) }
            startInFlight = false
            guard let routes, !routes.isEmpty else {
                return .failure(.routeCalculationFailed, advice: "没有换成功，继续按原路线导航。请如实说明。")
            }
            options = Array(routes.prefix(3))
        }
        guard options.count > 1 else {
            return .failure(.noOptionsOnScreen, advice: "这次只算出一条路线，没有别的可换。请如实说明。")
        }
        // Read after the recalculation: an off-route reroute may have replaced the route meanwhile.
        let current = snapshot.routes
        snapshot.routes = options
        let picked = pickRoute(args)
        snapshot.routes = current
        switch picked {
        case .success(let index):
            let route = options[index]
            if !fresh, route.id == current.first?.id {
                return .success(["status": "route_unchanged", "next": "只说一句：现在走的就是这条路线。"])
            }
            let label = switch args["preference"]?.stringValue {
            case "fastest": "最快的"
            case "shortest": "最短的"
            case "no_toll": "不收费的"
            case "fewest_lights": "红绿灯少的"
            case "recommended": "推荐的"
            default: "第\(index + 1)条"
            }
            let before = calculated
            let generation = snapshot.generation
            calculated = options
            let result = await startGuidance(route, replacing: label)
            if !result.ok, generation == snapshot.generation { calculated = before }
            return result
        case .failure(let box):
            return box.result
        }
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
            reset()
            await engine.stop(generation: generation)
            return .success(["status": "navigation_stopped", "next": "说一句：已结束导航。"])
        case .awaitingDestinationSelection, .awaitingRouteSelection, .resolvingDestination, .calculatingRoute:
            let generation = snapshot.generation
            reset()
            await engine.stop(generation: generation)
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
        case .rerouting:
            snapshot.rerouting = true
            publish()
        case .rerouted(let route):
            snapshot.rerouting = false
            if let route {
                snapshot.routes = [route]
                snapshot.selectedRoute = route.id
                // The other routes started where the trip was; a change now recalculates (§2.5).
                snapshot.alternatives = []
            }
            publish()
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
            // A saved 家/公司 is not an Amap POI: only what was saved is known about it.
            detail = place.id.hasPrefix("saved_") ? place : try await search.detail(id: place.id)
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

    /// F-16 §14 items 5–6: a list's yes-needed ids and its no-state; cleared on exit, timeout and a new session.
    public func forgetConfirmations() {
        confirm = nil
        asked = nil
        rejectedName = nil
    }

    private func closeAlongRouteList() {
        forgetConfirmations()
        snapshot.alongRouteList = false
        snapshot.places = []
        listedAt = nil
        publish()
    }

    /// The latest fix if F-16 may use it, converted to GCJ-02 for Amap.
    /// F-16a: the position every location answer uses (fresh enough, GCJ-02), or nil.
    public func currentPosition() async -> GeoCoordinate? { await currentFix()?.coordinate }

    /// F-16a §4: the usable fix with its accuracy and age (`current_location` reports both), or nil when
    /// there is no fix or it is too old or too coarse (F-16 §3).
    public func currentFix() async -> UsableFix? {
        guard let fix = await location.latestFix(), let quality = LocationQuality.of(fix, at: clock.now) else {
            return nil
        }
        let age = max(0, (clock.now - fix.timestamp).milliseconds)
        return UsableFix(coordinate: CoordinateConverter.gcj02(fix.coordinate),
                         accuracyMeters: fix.horizontalAccuracyMeters, ageSeconds: Int(age / 1000), quality: quality)
    }

    private func usableFix() async -> GeoCoordinate? { await currentFix()?.coordinate }

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
        snapshot.rerouting = false
        snapshot.alternatives = []
        snapshot.lastGuidance = nil
        snapshot.lastGuidanceID = nil
        listedAt = nil
        calculated = []
        forgetConfirmations()
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

    /// F-16 §14 item 7: every candidate says where it is.
    static func describe(_ scored: ScoredPlace, index: Int) -> JSONValue {
        let place = scored.place
        var object: [String: JSONValue] = ["index": .int(Int64(index)), "name": .string(place.name)]
        if let address = place.address { object["address"] = .string(address) }
        object["city"] = place.city.map(JSONValue.string) ?? .null
        object["district"] = place.district.map(JSONValue.string) ?? .null
        object["distance_km"] = scored.km.map { .double(($0 * 10).rounded() / 10) } ?? .null
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

/// A fix F-16 may use: GCJ-02 position, horizontal accuracy and age at the time it was read.
public struct UsableFix: Sendable, Hashable {
    public let coordinate: GeoCoordinate
    public let accuracyMeters: Double
    public let ageSeconds: Int
    public let quality: LocationQuality

    public init(coordinate: GeoCoordinate, accuracyMeters: Double, ageSeconds: Int, quality: LocationQuality) {
        self.coordinate = coordinate
        self.accuracyMeters = accuracyMeters
        self.ageSeconds = ageSeconds
        self.quality = quality
    }
}
