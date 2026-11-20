import NovaKit
import NovaPorts
import NovaTools

/// contracts/navigation.md phases. Cancel resets to idle; there is no cancelled phase.
// F-09b §16 item 10 (T-031z): the phase is NovaKit's `NavigationPhase` (one definition).

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
    /// F-15b §29 (T-040n): the plan stop the running guidance drives to (`trip_next`), else nil.
    public var tripStopID: String?
    /// The route buttons on screen: none while a list is open (a tap there picks a list row), and in 真实导航 only
    /// 「第N条」, since a change recalculates from here and the earlier minutes no longer hold.
    public var routeTapTargets: [AlternativeRoute] {
        guard phase == .navigating, !alongRouteList else { return [] }
        guard mode == .gps else { return alternatives }
        return alternatives.map { AlternativeRoute(row: $0.row, route: $0.route, text: "第\($0.row + 1)条") }
    }

    /// F-16 §15 item 2 (T-042d): the list `show_places` opened, with an about line per place and the names 高德 could
    /// not find (no coordinate, no distance). Valid only while `places` is still that list.
    public var explored: ExploredList?

    public init() {}

    /// F-16 §15 item 2: the about line under a listed place, when the list on screen is the `show_places` one.
    public func about(_ place: Place) -> String? {
        guard let explored, explored.places == places else { return nil }
        return explored.abouts[place.id]
    }

    /// F-16 §15 item 2: a listed name 高德 could not find; it has no map marker and no distance.
    public func unlocated(_ place: Place) -> Bool {
        guard let explored, explored.places == places else { return false }
        return explored.unlocated.contains(place.id)
    }

    public var navigating: Bool { phase == .navigating }
    public var listOpen: Bool {
        phase == .awaitingDestinationSelection || phase == .awaitingRouteSelection || alongRouteList
    }
}

/// F-16 §15 item 2 (T-042d): what `show_places` listed.
public struct ExploredList: Sendable, Hashable {
    public let places: [Place]
    /// Place id → the about line from the search answer.
    public let abouts: [String: String]
    /// Ids of names 高德 could not find.
    public let unlocated: Set<String>
    public init(places: [Place], abouts: [String: String], unlocated: Set<String>) {
        self.places = places
        self.abouts = abouts
        self.unlocated = unlocated
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
    public static let tools: Set<String> = ["navigate_to", "choose_navigation_option", "exit_navigation_mode", "show_places"]

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
    /// F-15b §29 item 2: called with the stop's place id when guidance to it ends `arrived`.
    private var tripArrived: (@Sendable (String) async -> Void)?
    /// F-15b §7: `trip stop-passed index=<k> of=<n>`.
    private let onTripLine: @Sendable (String) -> Void
    /// F-15b §22 (T-040m): hides the trip cards; true when they were shown over a plan with stops and are now hidden.
    private var hideTripCards: (@Sendable () async -> Bool)?

    public func setTripCards(hide: @escaping @Sendable () async -> Bool) { hideTripCards = hide }

    /// F-15b §36 item 2d (T-040p): plain searches abroad. `search` is Photon, `center` a city's centre outside China.
    /// §51 item 8 (T-040z): used for `near=place` geocodes abroad (`area`, then `center`) and Photon searches; the trip is
    /// consulted for `near=trip` and, while shown, `near=here` (§51 item 9).
    private var abroadSearch: (any PlaceSearch)?
    private var abroadCenter: (@Sendable (String) async -> GeoCoordinate?)?
    private var abroadArea: (@Sendable (String) async -> TripArea?)?
    /// F-15b §47 item 1 (T-040s): the places on offer came from `navigate_to abroad` (or an `abroad` trip's
    /// `trip_next`), so their route request is marked `abroad` (OSRM). A home search clears it.
    private var routeAbroad = false
    public func setAbroad(search: any PlaceSearch, center: @escaping @Sendable (String) async -> GeoCoordinate?,
                          area: @escaping @Sendable (String) async -> TripArea? = { _ in nil }) {
        abroadSearch = search
        abroadCenter = center
        abroadArea = area
    }
    public func setTripArrival(_ arrived: @escaping @Sendable (String) async -> Void) { tripArrived = arrived }
    /// F-15b §51 item 8 (T-040z): the plan as `near=trip` and a shown `near=here` (item 9) see it; nil when there is none.
    private var nearTrip: (@Sendable () async -> NearTrip?)?
    public func setNearTrip(_ trip: @escaping @Sendable () async -> NearTrip?) { nearTrip = trip }
    /// F-15b §51 item 9 (T-040za): the simulated car (`RouteGeometry.car`, GCJ-02) while a route runs in 模拟导航.
    private var simulatedCar: (@Sendable () async -> GeoCoordinate?)?
    public func setSimulatedCar(_ car: @escaping @Sendable () async -> GeoCoordinate?) { simulatedCar = car }
    /// §51 item 8: 高德 `/v3/geocode/geo` for `near=place` in China, 香港, 澳门 and 台湾; nil: the 高德 text search.
    private var homeGeocode: (any PlaceLookup)?
    public func setHomeGeocode(_ lookup: any PlaceLookup) { homeGeocode = lookup }
    /// F-16 §15 item 2 (T-042d): the car's city adcode for the `show_places` lookups; nil searches nationwide.
    private var cityCode: (@Sendable () async -> String?)?
    public func setCityCode(_ code: @escaping @Sendable () async -> String?) { cityCode = code }
    /// F-16 §15: `show places n= located= ms=` (codes and counts only, I-8).
    private var onExploreLine: @Sendable (String) -> Void = { _ in }
    public func setExploreLine(_ line: @escaping @Sendable (String) -> Void) { onExploreLine = line }

    public init(search: any PlaceSearch, engine: any NaviEngine, location: any LocationProvider,
                clock: any NovaClock, tuning: NavigationTuning = NavigationTuning(), saved: SavedPlaces? = nil,
                mode: (@Sendable () -> NaviMode)? = nil, nearFirst: NearFirstSearch? = nil,
                onTripLine: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (NavigationFlowState) -> Void = { _ in }) {
        self.onTripLine = onTripLine
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
        case "navigate_to":
            let destination = call.arguments["destination"]?.stringValue ?? ""
            // §51 item 8: the model's calls carry `near` (the validator requires it); an in-app call (a tap) has none
            // and is the home search.
            guard let near = call.arguments["near"] else { return await navigate(destination) }
            return await navigateNear(destination, near: near, call.arguments)
        case "choose_navigation_option": return await choose(call.arguments, fromTap: call.id.rawValue.hasPrefix("ui"))
        case "exit_navigation_mode": return await exit()
        case "show_places": return await showPlaces(call.arguments)
        default: return .failure(.unknownTool)
        }
    }

    // MARK: show_places

    /// F-16 §15 items 2–4 (T-042d): the places from a `web_search` answer, each `{name, about}`, looked up one by one
    /// with 高德 text search in the car's city (nationwide when the city is unknown) and listed with the about line.
    /// No §14 name check, nothing routed; a name 高德 cannot find is listed without distance. While guiding the list
    /// goes over the running route (as `navigate_to`). `show places n= located= ms=`.
    private func showPlaces(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        let items: [(name: String, about: String)] = (Self.array(args["places"])).compactMap { item in
            guard let name = item["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            let about = item["about"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (name, about)
        }
        var seen = Set<String>()
        let wanted = Array(items.filter { seen.insert($0.name).inserted }.prefix(tuning.maxCandidates))
        guard !wanted.isEmpty else {
            return ToolReply.failure(.invalidFieldValue, facts: ["shown": false], mustNot: [.claimDone, .invent]).result
        }
        let fix = await usableFix()
        let city = await cityCode?()
        var places: [Place] = []
        var abouts: [String: String] = [:]
        var unlocated: Set<String> = []
        var failed = 0
        for (offset, item) in wanted.enumerated() {
            var hit: Place?
            do {
                hit = if let city, !city.isEmpty {
                    try await search.text(item.name, city: city, cityLimit: true).first
                } else {
                    try await search.text(item.name, city: nil).first
                }
            } catch is CancellationError {
                return .failure(.optionsStale)
            } catch {
                failed += 1
                hit = nil
            }
            let place: Place
            if let hit {
                // The listed name stays the one she gave when 高德's is only longer (雪自由 → 雪自由(珠海环宇城)).
                let meters = hit.distanceMeters ?? fix.map { Int(SelfPosition.distanceMeters($0, hit.coordinate).rounded()) }
                place = Place(id: hit.id, name: hit.name, address: hit.address, coordinate: hit.coordinate,
                              distanceMeters: meters, openingHours: hit.openingHours, phone: hit.phone, city: hit.city,
                              district: hit.district, photoURL: hit.photoURL, countryCode: hit.countryCode, kind: hit.kind)
            } else {
                place = Place(id: "explore:\(offset):\(item.name)", name: item.name, address: nil,
                              coordinate: fix ?? GeoCoordinate(latitude: 0, longitude: 0, datum: .gcj02), distanceMeters: nil)
                unlocated.insert(place.id)
            }
            guard !places.contains(where: { $0.id == place.id }) else { continue }
            places.append(place)
            if !item.about.isEmpty { abouts[place.id] = item.about }
        }
        // Unlocated names go last, so the map's numbered markers match the list rows above them.
        places = places.filter { !unlocated.contains($0.id) } + places.filter { unlocated.contains($0.id) }
        let ms = max(0, Int((clock.now - started).milliseconds))
        onExploreLine("show places n=\(places.count) located=\(places.count - unlocated.count) ms=\(ms)")
        // Every lookup failed (key, quota, network): nothing useful to show.
        if failed == wanted.count {
            return LookupReply.failed(.liveInfoUnavailable, what: "places", cause: .network,
                                      facts: ["shown": false], mustNot: [.claimDone])
        }
        asked = nil
        rejectedName = nil
        confirm = nil
        if snapshot.navigating {
            snapshot.alongRouteList = true
        } else {
            _ = advance(to: .awaitingDestinationSelection)
            snapshot.routes = []
            snapshot.destination = nil
            snapshot.info = nil
            routeAbroad = false
        }
        snapshot.places = places
        snapshot.explored = ExploredList(places: places, abouts: abouts, unlocated: unlocated)
        listedAt = clock.now
        publish()
        let listed: [JSONValue] = places.map { place in
            var o: [String: JSONValue] = ["name": .string(place.name)]
            if let m = place.distanceMeters, !unlocated.contains(place.id) {
                o["distance_km"] = .double((Double(m) / 100).rounded() / 10)
            } else {
                o["located"] = false
            }
            return .object(o)
        }
        return ToolReply.success(facts: ["shown": true, "listed": .array(listed), "routed": false],
                                 mustNot: [.readList, .claimStarted, .invent]).result
    }

    private static func array(_ value: JSONValue?) -> [JSONValue] {
        if case .array(let items)? = value { return items }
        return []
    }

    // MARK: navigate_to

    /// F-15b §51 item 8 (T-040z, replaces §36 item 2d's `abroad`/`city`): the model names the centre; code resolves it
    /// (the fix or the demo point, a geocode, a shown trip stop, the route), picks the vendor by the centre's country,
    /// keeps the results to that country and range, and says what it did (`searched_around`, `vendor`, `found`).
    /// `nav near kind= vendor= source= found= dropped= reason=`.
    private func navigateNear(_ destination: String, near raw: JSONValue, _ args: JSONValue) async -> ToolResult {
        guard let kind = raw.stringValue.flatMap(NearKind.init(rawValue:)) else {
            return Self.nearInvalid(["near": raw])
        }
        let name = args["near_name"]?.stringValue?.trimmingCharacters(in: .whitespaces).nonEmpty
        let country = Self.nearCountry(args["near_country"]?.stringValue)
        switch kind {
        case .here: return await nearHere(destination)
        case .route:
            guard snapshot.navigating else {
                return Self.nearInvalid(["near": "route", "navigating": false], may: [.offerNearby])
            }
            let r = await listOverGuidance(destination)
            let found = Self.found(r)
            nearLine(.route, vendor: "amap", source: "route", found: found, dropped: 0, reason: "ok")
            return Self.withFacts(r, ["searched_around": "路线沿途", "vendor": "amap", "found": .int(Int64(found))])
        case .place:
            guard let name, let country else {
                return Self.nearInvalid(["near": "place", "missing": .array((name == nil ? ["near_name"] : [])
                                                                             + (country == nil ? ["near_country"] : []))])
            }
            return await nearPlace(destination, name: name, country: country)
        case .trip:
            return await nearTripStop(destination, name: name ?? "")
        }
    }

    /// F-15b §51 item 8 (row 189): `near_country` as an ISO 3166 alpha-2 code. The live model often writes the name
    /// (「日本」), which is two characters and passed the length check, then failed the country check. Common names map
    /// to their code; anything else that is not two ASCII letters counts as missing (the model is asked again).
    static let countryNames: [String: String] = [
        "中国": "CN", "中国大陆": "CN", "日本": "JP", "韩国": "KR", "香港": "HK", "中国香港": "HK", "澳门": "MO",
        "中国澳门": "MO", "台湾": "TW", "中国台湾": "TW", "美国": "US", "新加坡": "SG", "泰国": "TH", "马来西亚": "MY",
        "越南": "VN", "英国": "GB", "法国": "FR", "德国": "DE", "意大利": "IT", "西班牙": "ES", "澳大利亚": "AU",
        "新西兰": "NZ", "加拿大": "CA",
    ]
    static func nearCountry(_ raw: String?) -> String? {
        guard let s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if let code = countryNames[s] { return code }
        let up = s.uppercased()
        return up.count == 2 && up.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) }) ? up : nil
    }

    /// F-09b §13: a refused `near` as facts (what was wrong, the allowed values) and rules; no sentence. Nothing searched.
    static func nearInvalid(_ facts: [String: JSONValue], may: [ReplyMay] = []) -> ToolResult {
        var facts = facts
        facts["near_allowed"] = .array(NearKind.allCases.map { .string($0.rawValue) })
        return ToolReply.notDone(.invalidFields, facts: facts, may: may, mustNot: [.invent]).result
    }

    /// Whether a centre is abroad: by its country when known (HK/MO/TW are 高德's, `TripRegion.isChina`); only
    /// without a country by the China box (`CoordinateConverter.outOfChina`), which also holds Seoul or Osaka's edges.
    static func abroad(country: String?, at point: GeoCoordinate) -> Bool {
        if let country, !country.isEmpty { return !TripRegion.isChina(country) }
        return CoordinateConverter.outOfChina(point.latitude, point.longitude)
    }

    /// `here`: the phone's fix (or the demo point); 高德 in China (the F-16 search), Photon abroad, kept to 50 km.
    /// §51 item 9 (T-040za): while the trip cards are shown over a plan with stops, `here` is the trip location instead.
    private func nearHere(_ destination: String) async -> ToolResult {
        if let trip = await nearTrip?(), !trip.hidden, let next = trip.next {
            return await nearTripHere(destination, next: next)
        }
        let fix = await usableFix()
        let demo = location.source == .demo
        let source = demo ? "demo" : "fix"
        let label = fix == nil ? "没有定位" : demo ? "演示位置" : "手机位置"
        // The phone's country is known only inside China's box (CN); outside it, it is not guessed.
        let phoneAbroad = fix.map { CoordinateConverter.outOfChina($0.latitude, $0.longitude) } ?? false
        var facts: [String: JSONValue] = ["searched_around": .string(label)]
        if fix == nil { facts["located"] = false }
        if phoneAbroad, let fix, abroadSearch != nil {
            let (r, found, dropped) = await searchAbroad(destination, center: fix, area: TripArea(center: fix, countryCode: nil),
                                                         aroundFix: true, label: label)
            nearLine(.here, vendor: "photon", source: source, found: found, dropped: dropped, reason: "ok")
            facts["vendor"] = "photon"
            facts["found"] = .int(Int64(found))
            return Self.withFacts(r, facts)
        }
        let r = await navigate(destination)
        let found = Self.found(r)
        nearLine(.here, vendor: "amap", source: source, found: found, dropped: 0, reason: "ok")
        facts["vendor"] = "amap"
        facts["found"] = .int(Int64(found))
        return Self.withFacts(r, facts)
    }

    /// §51 item 9 (T-040za, owner 2026-11-20): cards shown, `here` is the trip location: the simulated car while a trip
    /// stop guidance runs in 模拟导航, else the trip's next stop. The vendor by the trip stop's country (also for the
    /// car). Facts `searched_around` 「行程位置（…）」 and `source=trip_here`; no `trip_city`.
    private func nearTripHere(_ destination: String, next: NearTripStop) async -> ToolResult {
        // Read before the search: a search ends the trip stop guidance (`endTripStop`).
        let car = snapshot.navigating && snapshot.tripStopID != nil && snapshot.mode == .emulator
            ? await simulatedCar?() : nil
        let center = car ?? next.coordinate
        // The car drives inside the trip: the trip's country (never the China box, which holds Osaka and Seoul).
        let country = next.countryCode
        let label = "行程位置（\(car == nil ? next.name : "模拟车")）"
        let abroad = Self.abroad(country: country, at: center) && abroadSearch != nil
        let result = abroad
            ? await searchAbroad(destination, center: center, area: TripArea(center: center, countryCode: country),
                                 aroundFix: false, label: label)
            : await searchHome(destination, center: center, label: label)
        let vendor = abroad ? "photon" : "amap"
        nearLine(.here, vendor: vendor, source: "trip_here", found: result.found, dropped: result.dropped, reason: "ok")
        return Self.withFacts(result.result, ["searched_around": .string(label), "source": "trip_here",
                                              "vendor": .string(vendor), "found": .int(Int64(result.found))])
    }


    /// `place`: `near_name` geocoded on 高德 (`/v3/geocode/geo`) when `near_country` is CN, HK, MO or TW, else on
    /// Photon (its area, then its centre). A point found in another country than `near_country` is refused
    /// (`countryMismatch`), nothing searched. A failed geocode gives its cause, never not_found.
    private func nearPlace(_ destination: String, name: String, country: String) async -> ToolResult {
        let home = TripRegion.isChina(country)
        // The request owns the flow before the geocode (as the old navigateAbroad): a newer navigate_to or a cancel
        // during the geocode wins, and this one returns optionsStale with no search and no route.
        let guiding = snapshot.navigating
        let generation: Generation
        if guiding {
            generation = snapshot.generation
        } else {
            generation = advance(to: .resolvingDestination)
            publish()
        }
        func current() -> Bool { generation == snapshot.generation && snapshot.navigating == guiding }
        func endRefused() { if !guiding, current() { reset(); publish() } }
        var center: GeoCoordinate?
        var found: String?
        if home {
            do {
                if let homeGeocode {
                    center = try await homeGeocode.lookUp(name, country: country).lazy.compactMap(\.coordinate).first
                } else {
                    center = try await search.text(name, city: nil).first?.coordinate
                }
            } catch {
                guard current() else { return .failure(.optionsStale) }
                endRefused()
                let cause = LookupReply.cause(of: error)
                nearLine(.place, vendor: "none", source: "geocode", found: 0, dropped: 0, reason: "failed")
                return LookupReply.failed(LookupReply.code(for: cause), what: "place", cause: cause,
                                          facts: ["near_name": .string(name)])
            }
            // 高德 answers only for China, 香港, 澳门 and 台湾: the country asked.
            found = center == nil ? nil : country
        } else if let area = await abroadArea?(name) {
            center = area.center
            found = area.countryCode
        } else if let c = await abroadCenter?(name) {
            // No country from a bare centre (Apple's fallback): never guessed from the box.
            center = c
        }
        guard current() else { return .failure(.optionsStale) }
        guard let center else {
            endRefused()
            nearLine(.place, vendor: "none", source: "geocode", found: 0, dropped: 0, reason: "not_found")
            return LookupReply.notFound(.notFound, what: name, facts: ["near_name": .string(name)], may: [.askPlace])
        }
        if let found, found != country {
            endRefused()
            nearLine(.place, vendor: "none", source: "geocode", found: 0, dropped: 0, reason: "country_mismatch")
            return ToolReply.failure(.countryMismatch,
                                     facts: ["near_name": .string(name), "near_country": .string(country),
                                             "found_country": .string(found)],
                                     may: [.askPlace], mustNot: [.invent]).result
        }
        let centreCountry = found ?? country
        let abroad = Self.abroad(country: centreCountry, at: center) && abroadSearch != nil
        let result = abroad
            ? await searchAbroad(destination, center: center, area: TripArea(center: center, countryCode: centreCountry),
                                 aroundFix: false, label: name)
            : await searchHome(destination, center: center, label: name)
        let vendor = abroad ? "photon" : "amap"
        nearLine(.place, vendor: vendor, source: "geocode", found: result.found, dropped: result.dropped, reason: "ok")
        return Self.withFacts(result.result, ["searched_around": .string(name), "vendor": .string(vendor),
                                              "found": .int(Int64(result.found))])
    }

    /// `trip`: only while the cards are shown; the matched stop's saved coordinates are the centre, its country the
    /// vendor's (the box only when the stop has none).
    private func nearTripStop(_ destination: String, name: String) async -> ToolResult {
        guard let trip = await nearTrip?(), !trip.stops.isEmpty else {
            nearLine(.trip, vendor: "none", source: "trip", found: 0, dropped: 0, reason: "not_found")
            return LookupReply.notFound(.notFound, what: name, facts: ["stops": []], may: [.askPlace])
        }
        if trip.hidden {
            onTripLine("trip blocked tool=navigate_to reason=hidden")
            nearLine(.trip, vendor: "none", source: "trip", found: 0, dropped: 0, reason: "trip_hidden")
            return TripPlanner.tripHiddenResult
        }
        let matches = trip.match(name)
        guard matches.count == 1, let stop = matches.first else {
            let ambiguous = matches.count > 1
            nearLine(.trip, vendor: "none", source: "trip", found: 0, dropped: 0, reason: ambiguous ? "ambiguous" : "not_found")
            if ambiguous {
                return ToolReply.failure(.ambiguous, facts: ["near_name": .string(name),
                                                             "matches": .array(matches.map { .string($0.name) })],
                                         may: [.askPick], mustNot: [.invent]).result
            }
            return LookupReply.notFound(.notFound, what: name,
                                        facts: ["stops": .array(Self.uniqueNames(trip.stops).map(JSONValue.string))],
                                        may: [.askPlace])
        }
        let label = "行程第\(stop.day)天\(stop.name)"
        let abroad = Self.abroad(country: stop.countryCode, at: stop.coordinate) && abroadSearch != nil
        let result = abroad
            ? await searchAbroad(destination, center: stop.coordinate,
                                 area: TripArea(center: stop.coordinate, countryCode: stop.countryCode), aroundFix: false,
                                 label: label)
            : await searchHome(destination, center: stop.coordinate, label: label)
        let vendor = abroad ? "photon" : "amap"
        nearLine(.trip, vendor: vendor, source: "trip", found: result.found, dropped: result.dropped, reason: "ok")
        return Self.withFacts(result.result, ["searched_around": .string(label), "vendor": .string(vendor),
                                              "found": .int(Int64(result.found))])
    }

    private static func uniqueNames(_ stops: [NearTripStop]) -> [String] {
        var out: [String] = []
        for s in stops where !out.contains(s.name) { out.append(s.name) }
        return out
    }

    /// `vendor=none` when nothing was searched; `reason=failed` when the geocode itself failed (its cause in the facts).
    private func nearLine(_ kind: NearKind, vendor: String, source: String, found: Int, dropped: Int, reason: String) {
        onTripLine("nav near kind=\(kind.rawValue) vendor=\(vendor) source=\(source) found=\(found) dropped=\(dropped) reason=\(reason)")
    }

    /// Places offered by a result: the listed count, 1 for a started route, else 0.
    static func found(_ r: ToolResult) -> Int {
        guard r.ok else { return 0 }
        return r.data["count"]?.intValue.map(Int.init) ?? 1
    }

    /// `facts` added to a result's `facts` (F-09b §13 `ToolReply`); the result's own facts win.
    static func withFacts(_ r: ToolResult, _ extra: [String: JSONValue]) -> ToolResult {
        var data = r.data
        var facts: [String: JSONValue] = if case .object(let o)? = data["facts"] { o } else { [:] }
        for (k, v) in extra where facts[k] == nil { facts[k] = v }
        data["facts"] = .object(facts)
        return ToolResult(ok: r.ok, code: r.code, data: data, advice: r.advice)
    }

    /// 高德 around a named point or a trip stop in China, kept to 50 km (`reason=far`).
    private func searchHome(_ destination: String, center: GeoCoordinate, label: String) async
        -> (result: ToolResult, found: Int, dropped: Int) {
        confirm = nil
        routeAbroad = false
        endTripStop()
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
        func current() -> Bool { generation == snapshot.generation && snapshot.navigating == guiding }
        let query = DestinationQuery(destination)
        var places: [Place] = []
        var dropped = 0
        do {
            for keywords in query.attempts where places.isEmpty {
                let found = try await search.around(keywords, center: center, radiusMeters: tuning.searchRadiusMeters,
                                                    sort: query.sort)
                guard current() else { return (.failure(.optionsStale), 0, 0) }
                let kept = found.filter { SelfPosition.distanceMeters(center, $0.coordinate) <= Double(tuning.searchRadiusMeters) }
                dropped += found.count - kept.count
                places = kept
            }
        } catch {
            if !guiding { reset() }
            return (Self.searchFailure(error).result, 0, dropped)
        }
        let top = Array(places.prefix(tuning.maxCandidates))
        guard !top.isEmpty else {
            if !guiding { reset() }
            return (LookupReply.noCandidates(what: query.stripped, around: .city,
                                             radiusKm: Double(tuning.searchRadiusMeters) / 1000, city: label), 0, dropped)
        }
        let r = guiding ? listedOverGuidance(top) : await listOrRoute(top)
        return (r, top.count, dropped)
    }

    /// Photon around `center`: the phone abroad (`aroundFix`), or a named place or trip stop kept to `area`'s country
    /// and 50 km (§50 item 3). No 高德 request. The places go to the candidate list as `navigate_to`'s do.
    /// `nav search vendor=photon found= ms=`.
    private func searchAbroad(_ destination: String, center: GeoCoordinate, area: TripArea?, aroundFix: Bool,
                              label: String) async -> (result: ToolResult, found: Int, dropped: Int) {
        confirm = nil
        routeAbroad = true
        endTripStop()
        guard let abroadSearch else { return (Self.nearInvalid([:]), 0, 0) }
        let started = clock.now
        // F-05a §6: while guiding, the places are listed over the running route (as `listOverGuidance`).
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
        func current() -> Bool { generation == snapshot.generation && snapshot.navigating == guiding }
        let query = DestinationQuery(destination)
        var places: [Place] = []
        var areaDropped = 0
        do {
            for keywords in query.attempts where places.isEmpty {
                if let area {
                    let found: [Place]
                    if let boxed = abroadSearch as? any AreaPlaceSearch {
                        found = try await boxed.inArea(keywords, box: GeoBox.around(area.center), limit: tuning.maxCandidates)
                    } else {
                        found = try await abroadSearch.around(keywords, center: center,
                                                              radiusMeters: tuning.searchRadiusMeters, sort: query.sort)
                    }
                    let inside = TripGround.inArea(found, area: area, km: TripTuning().areaKm)
                    places = inside.kept
                    areaDropped += inside.dropped
                } else {
                    places = try await abroadSearch.around(keywords, center: center,
                                                           radiusMeters: tuning.searchRadiusMeters, sort: query.sort)
                }
                guard current() else { return (.failure(.optionsStale), 0, 0) }
            }
        } catch {
            onTripLine("nav search vendor=photon abroad=yes found=0 ms=\(max(0, (clock.now - started).milliseconds))")
            if !guiding { reset() }
            return (Self.searchFailure(error).result, 0, areaDropped)
        }
        // §36 item 3: a place in China is never a result abroad.
        let abroadOnly = places.filter { $0.countryCode == nil || !TripRegion.isChina($0.countryCode) }
        let dropped = areaDropped + places.count - abroadOnly.count
        let top = Array(abroadOnly.prefix(tuning.maxCandidates))
        let areaPart = area == nil ? "" : " area_dropped=\(areaDropped)"
        onTripLine("nav search vendor=photon abroad=yes found=\(top.count) ms=\(max(0, (clock.now - started).milliseconds))\(areaPart)")
        guard !top.isEmpty else {
            if !guiding { reset() }
            // F-09b §13 item 3: facts and rules, no sentence.
            let around: LookupReply.Around = !aroundFix ? .city : location.source == .demo ? .demo : .phone
            let radiusKm: Double = area != nil ? TripTuning().areaKm : Double(tuning.searchRadiusMeters) / 1000
            return (LookupReply.noCandidates(what: query.stripped, around: around, radiusKm: radiusKm,
                                             city: aroundFix ? nil : label), 0, dropped)
        }
        let r = guiding ? listedOverGuidance(top) : await listOrRoute(top)
        return (r, top.count, dropped)
    }

    /// F-15b §51 item 7 (T-040y): a plain navigate_to (home or abroad) ends the trip stop guidance (§29); nothing
    /// after it starts from a trip place (the new route's start is the engine's origin: the phone's fix or the demo point).
    private func endTripStop() {
        guard snapshot.tripStopID != nil else { return }
        snapshot.tripStopID = nil
        publish()
    }

    private func navigate(_ destination: String) async -> ToolResult {
        confirm = nil
        routeAbroad = false
        // F-16: an unset 家/公司 is refused before anything changes (the trip stop guidance keeps going, I-14).
        if let saved, let slot = PlaceSlot.slot(for: destination), saved.place(slot) == nil {
            let code: ToolErrorCode = slot == .home ? .homeNotSet : .workNotSet
            return ToolFailureAdvice.reply(code, facts: ["slot": .string(slot.rawValue)])
        }
        endTripStop()
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
                return ToolFailureAdvice.reply(code, facts: ["slot": .string(slot.rawValue)])
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
        return await listOrRoute(top)
    }

    /// One place is routed at once; several go to the candidate list (F-16).
    private func listOrRoute(_ top: [Place]) async -> ToolResult {
        if top.count == 1 { return await route(to: top[0]) }
        snapshot.phase = .awaitingDestinationSelection
        snapshot.places = top
        listedAt = clock.now
        publish()
        return .success([
            "status": "candidates_listed",
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
        ].merging(Self.said(["listed": .int(Int64(top.count))], may: [.askPick], mustNot: [.readList])) { $1 })
    }

    /// Up to `maxCandidates` places for `destination`, or the failure to return. F-16: stripped query first,
    /// verbatim once if it found nothing; nearby and categories by distance. A stale or coarse fix is not used
    /// (text search, no city); Amap wants GCJ-02. `current` is false once a newer request owns the flow.
    private func findPlaces(_ destination: String, current: () -> Bool) async -> Result<[Place], ToolResultBox> {
        var places: [Place] = []
        let query = DestinationQuery(destination)
        let center = await usableFix()
        do {
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
            // F-09b §13 item 3: facts and rules, no sentence.
            let around: LookupReply.Around = center == nil ? .city : location.source == .demo ? .demo : .phone
            return .failure(ToolResultBox(LookupReply.noCandidates(
                what: query.stripped, around: around,
                radiusKm: center == nil ? nil : Double(tuning.searchRadiusMeters) / 1000)))
        }
        return .success(top)
    }

    private static func searchFailure(_ error: any Error) -> ToolResultBox {
        // F-09b §13 item 3: the cause as a fact; a quota error stays LIVE_INFO_UNAVAILABLE here as before.
        let cause = LookupReply.cause(of: error)
        return ToolResultBox(cause == .keyMissing
            ? LookupReply.failed(.amapWebKeyMissing, what: "place", cause: .keyMissing)
            : LookupReply.failed(.liveInfoUnavailable, what: "place", cause: cause))
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
            // F-16 §15 item 4 (T-042d): 高德 may have returned places none of which fit the name; the facts say how
            // many were found and that none matched, never `found=0` (the caller's `found` does not override these).
            let facts: [String: JSONValue] = ["found": .int(Int64(found.places.count)), "name_matched": 0]
            return .failure(.noCandidates, advice: NearFirstSearch.noFitText, data: ["facts": .object(facts)])
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
        // F-09b §13 item 4 (T-031m): not yet; facts and rules, no sentence.
        return ToolReply.notDone(.confirmFirst, facts: ["name": .string(place.name), "confirmed": false],
                                 may: [.askConfirm]).result
    }

    /// While guiding: the places are listed over the running route (as along-route results); nothing stops
    /// until a pick, which replaces the route (`choose` on the along-route list).
    private func listOverGuidance(_ destination: String) async -> ToolResult {
        let generation = snapshot.generation
        let top: [Place]
        if let saved, let slot = PlaceSlot.slot(for: destination) {
            guard let place = saved.place(slot) else {
                let code: ToolErrorCode = slot == .home ? .homeNotSet : .workNotSet
                return ToolFailureAdvice.reply(code, facts: ["slot": .string(slot.rawValue)])
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
        return listedOverGuidance(top)
    }

    private func listedOverGuidance(_ top: [Place]) -> ToolResult {
        snapshot.places = top
        snapshot.alongRouteList = true
        listedAt = clock.now
        publish()
        return .success([
            "status": "candidates_listed_over_guidance",
            "count": .int(Int64(top.count)),
            "candidates": .array(top.enumerated().map { Self.describe($0.element, index: $0.offset + 1) }),
            "guidance_kept": true,
        ].merging(Self.said(["listed": .int(Int64(top.count)), "guidance_kept": true, "route_changed": false],
                            may: [.askPick], mustNot: [.readList, .claimDone])) { $1 })
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
                return Self.notYet("starting")
            }
            switch pickRoute(args) {
            case .success(let index): return await startGuidance(snapshot.routes[index])
            case .failure(let box): return box.result
            }
        case .resolvingDestination, .planningRoute, .calculatingRoute, .routeReady:
            return Self.notYet("calculating_route")
        case .navigating:
            return await changeRoute(args)
        case .idle, .arrived, .stopped, .error:
            return ToolReply.notDone(.noOptionsOnScreen, facts: ["on_screen": 0], may: [.askDestination]).result
        }
    }

    private func route(to place: Place) async -> ToolResult {
        // F-16 §15 item 3 (T-042d): a `show_places` name 高德 could not find has no coordinate; picking it searches it
        // by name as a `navigate_to` would.
        if snapshot.unlocated(place) {
            snapshot.explored = nil
            return await navigate(place.name)
        }
        // F-15a §2.2 (OQ-NAVM-2): 真实导航 starts only from a usable fix; never the demo origin.
        if mode() == .gps, let refusal = await noUsableFix() {
            reset()
            return refusal
        }
        let generation = advance(to: .calculatingRoute)
        snapshot.destination = place
        snapshot.places = []
        publish()
        await engine.calculateRoutes(RouteRequest(destination: place.coordinate, destinationName: place.name,
                                                  abroad: routeAbroad),
                                     generation: generation)
        // A newer request took over while the engine was busy: its event is not ours to wait for.
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        let event = await wait(.routes, within: tuning.routeWait)
        guard generation == snapshot.generation else { return .failure(.optionsStale) }
        guard case .routesReady(let routes) = event, !routes.isEmpty else {
            reset()
            return LookupReply.failed(.routeCalculationFailed, what: "route", cause: .routeFailed, mustNot: [.claimStarted])
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
            return ToolReply.notDone(.locationPermissionDenied, facts: ["what": "navigation", "cause": "permission_denied"],
                                     may: [.nameSetting], mustNot: [.guessLocation]).result
        }
        guard let fix = await location.latestFix(), LocationQuality.of(fix, at: clock.now) != nil else {
            return ToolReply.notDone(.noLocation, facts: ["what": "navigation", "cause": "no_location"],
                                     may: [.tryLater], mustNot: [.guessLocation]).result
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
                return ToolReply.notDone(.startFailed, facts: ["changed": false, "guidance_kept": true],
                                         may: [.tryLater]).result
            }
            // Reset first so a request that lands while the engine stops is not wiped out.
            reset()
            await engine.stop(generation: generation)
            return ToolReply.notDone(.startFailed, facts: ["started": false], may: [.tryLater]).result
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
        // F-16 §14 item 8: name, km and hours+minutes; a long trip asks once more and a no cancels.
        var longTrip = false
        if let nearFirst, !replacing {
            longTrip = nearFirst.match.startSentence(name: snapshot.destination?.name ?? "", meters: route.lengthMeters,
                                                     seconds: route.durationSeconds).longTrip
        }
        let offerPreference = offer.map { $0.contains("更快") ? "fastest" : $0.contains("更短") ? "shortest" : "no_toll" }
        // F-09b §13 item 5 (T-031n): what changed as facts; she says it in her own words.
        var facts: [String: JSONValue] = [
            replacing ? "route_changed_to" : "started": replacing ? .string(label ?? "") : .bool(true),
            "destination": .string(snapshot.destination?.name ?? ""),
            "distance_km": .double(Self.km(route.lengthMeters)), "duration_min": .int(Int64(minutes)),
            "simulated": .bool(mode == .emulator),
        ]
        if longTrip { facts["long_trip"] = true }
        if let offerPreference, !longTrip, !replacing { facts["offer_other_route"] = .string(offerPreference) }
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
            "offer_preference": offerPreference.map(JSONValue.string) ?? .null,
        ].merging(Self.said(facts, may: longTrip ? [.askConfirm] : [], mustNot: [.readRoutes])) { $1 })
    }

    /// F-15a §2.5 (T-040h): while navigating, 「换最快的」「不走高速」「换第二条」 replace the route with one of the
    /// same calculation; one trip, never a second one.
    private func changeRoute(_ args: JSONValue) async -> ToolResult {
        if startInFlight {
            return Self.notYet("changing_route")
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
                return ToolReply.notDone(.routeCalculationFailed, facts: ["changed": false, "guidance_kept": true],
                                         may: [.tryLater]).result
            }
            options = Array(routes.prefix(3))
        }
        guard options.count > 1 else {
            return ToolReply.notDone(.noOptionsOnScreen, facts: ["routes": .int(Int64(options.count)), "changed": false,
                                                                "guidance_kept": true]).result
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
                return .success(["status": "route_unchanged"].merging(Self.said(["route_changed": false,
                                                                                  "already_on_it": true])) { $1 })
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

    // MARK: trip_next (F-15b §29, T-040n)

    /// One plan stop as a normal single-destination route from here, started as a chosen `navigate_to` place
    /// (F-15a), with no place search. A running guidance is replaced. On `arrived` the arrival hook gets its id.
    /// `abroad`: the stop belongs to an `abroad` trip; its route then comes from OSRM (F-15b §47 item 1).
    public func tripNext(_ place: Place, abroad: Bool = false) async -> ToolResult {
        if startInFlight {
            return Self.notYet("starting")
        }
        routeAbroad = abroad
        forgetConfirmations()
        asked = nil
        // §29 item 1: replaces running guidance as 「换成X」 does: stop the old route first.
        if snapshot.navigating || snapshot.phase == .arrived || snapshot.alongRouteList {
            let generation = snapshot.generation
            snapshot.alongRouteList = false
            await engine.stop(generation: generation)
            guard generation == snapshot.generation else { return .failure(.optionsStale) }
            snapshot.routes = []
            snapshot.info = nil
        }
        let result = await route(to: place)
        if result.ok, snapshot.navigating, snapshot.destination?.id == place.id {
            snapshot.tripStopID = place.id
            publish()
        }
        return result
    }

    // MARK: exit_navigation_mode

    /// F-09b §13 item 5 (T-031n): the cards were put away; the plan stays.
    public static let cardsHiddenNext = ToolReply.success(
        facts: ["trip_cards": "hidden", "plan_kept": true, "show_command": "打开行程"], may: [.nameCommand])
        .result.data["next"]?.stringValue ?? ""
    static let cardsHidden = ToolReply.success(
        facts: ["trip_cards": "hidden", "plan_kept": true, "show_command": "打开行程"], may: [.nameCommand]).result.data

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
        case .awaitingDestinationSelection, .awaitingRouteSelection, .resolvingDestination, .planningRoute,
             .calculatingRoute, .routeReady:
            let generation = snapshot.generation
            reset()
            await engine.stop(generation: generation)
            _ = await hideTripCards?()
            return .success(["status": "navigation_selection_cancelled", "next": "说一句：好的，已取消。"])
        case .idle, .stopped, .error:
            // F-15b §22 item 2: nothing open, the cards shown: they are put away; the plan stays.
            if await hideTripCards?() == true {
                return .success(["status": "trip_cards_hidden"].merging(Self.cardsHidden) { $1 })
            }
            return .success(["status": "no_navigation_active", "next": "如实说当前没有在导航。"])
        }
    }

    // MARK: query_live_info route_traffic

    /// Remaining distance and time of the running guidance, from the engine's own numbers.
    public func routeStatus() -> ToolResult {
        guard snapshot.navigating, let route = snapshot.routes.first else {
            return ToolReply.notDone(.notNavigating, facts: ["navigating": false], mustNot: [.invent]).result
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
            let stop = snapshot.tripStopID
            snapshot.tripStopID = nil
            publish()
            // §29 item 2: guidance that ends arrived at the stop marks it visited.
            if let stop, let tripArrived { Task { await tripArrived(stop) } }
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
            // F-09b §13 item 4 (T-031m): nothing on screen to choose from; facts and rules, no sentence.
            return ToolReply.notDone(.notNavigating, facts: ["navigating": false, "along_route": false],
                                     may: [.offerNearby]).result
        }
        guard let category, let keywords = Self.categories[category] else {
            return ToolReply.failure(.invalidArgument,
                                     facts: ["allowed": .array(["加油站", "充电站", "服务区", "厕所"])],
                                     may: [.askPick, .askWhat], mustNot: [.invent]).result
        }
        let line = snapshot.routes.first?.polyline ?? []
        let polygon = AlongRouteCorridor.polygon(line)
        guard !polygon.isEmpty else {
            return LookupReply.failed(.liveInfoUnavailable, what: "along_route", cause: .noRouteShape,
                                      facts: ["guidance_kept": true])
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
            return LookupReply.notFound(.noResults, what: keywords, facts: ["along_route": true, "guidance_kept": true],
                                        may: [.similarPlace])
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
        ].merging(Self.said(["listed": .int(Int64(top.count)), "what": .string(keywords), "guidance_kept": true],
                            may: [.askPick], mustNot: [.readList])) { $1 })
    }

    /// Details of the destination or of the n-th place on screen, from Amap's place detail only.
    public func placeDetails(target: JSONValue?) async -> ToolResult {
        let place: Place
        switch target {
        case .string("destination"):
            guard let destination = snapshot.destination else {
                // F-09b §13 item 4 (T-031m): places on screen to choose from; she may ask which one.
                if !snapshot.places.isEmpty {
                    return ToolReply.choosing(.noDestination, onScreen: snapshot.places.count,
                                              names: snapshot.places.map(\.name), facts: ["destination": .null]).result
                }
                return ToolReply.notDone(.noDestination, facts: ["destination": .null],
                                         may: [.askDestination], mustNot: [.invent]).result
            }
            place = destination
        case .some(let value):
            guard let index = Self.index(["index": value]) else {
                return Self.whichPlace(snapshot)
            }
            guard index >= 1, index <= snapshot.places.count else {
                return snapshot.places.isEmpty
                    ? ToolReply.choosing(.noOptionsOnScreen, onScreen: 0, may: [.askDestination]).result
                    : Self.outOfRange(snapshot.places.count, names: snapshot.places.map(\.name)).result
            }
            place = snapshot.places[index - 1]
        case .none:
            return Self.whichPlace(snapshot)
        }
        let detail: Place?
        do {
            // A saved 家/公司 is not an Amap POI: only what was saved is known about it.
            detail = place.id.hasPrefix("saved_") ? place : try await search.detail(id: place.id)
        } catch {
            return LiveInfoFailure.result(error, what: "\(place.name)的详情")
        }
        guard let detail else {
            return LookupReply.notFound(.noResults, what: "details", facts: ["place": .string(place.name)])
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

    /// F-09b §14 item 1 (T-031p): the point the `[系统] 现在` note names. While the trip cards are shown over a plan
    /// with stops, the trip location of F-15b §51 item 9 (the simulated car in 模拟导航 trip stop guidance, else the
    /// next stop); otherwise the phone's usable fix; nil without either.
    public func contextCenter() async -> ContextCenter? {
        if let trip = await nearTrip?(), !trip.hidden, let next = trip.next {
            let car = snapshot.navigating && snapshot.tripStopID != nil && snapshot.mode == .emulator
                ? await simulatedCar?() : nil
            return ContextCenter(coordinate: car ?? next.coordinate, trip: car == nil ? next.name : "模拟车")
        }
        return await usableFix().map { ContextCenter(coordinate: $0, trip: nil) }
    }

    private func advance(to phase: NavigationPhase) -> Generation {
        snapshot.generation = snapshot.generation.next()
        snapshot.phase = phase
        // F-15b §29: any new request (a navigate_to, a cancel, the next stop) ends the trip stop.
        snapshot.tripStopID = nil
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
        snapshot.explored = nil
        listedAt = nil
        calculated = []
        forgetConfirmations()
        publish()
    }

    private func publish() { onChange(snapshot) }

    private func staleList() -> ToolResult? {
        guard let listedAt, clock.now - listedAt > tuning.choiceLifetime else { return nil }
        if snapshot.alongRouteList { closeAlongRouteList() } else { reset() }
        // F-09b §13 item 4 (T-031m): the list was closed; nothing is on screen now.
        return ToolReply.choosing(.optionsStale, onScreen: 0, facts: ["expired": true], may: [.askDestination]).result
    }

    private func pick<T>(_ items: [T], _ args: JSONValue, distance: (T) -> Int?,
                         name: (T) -> String) -> Result<Int, ToolResultBox> {
        if let index = Self.index(args) {
            return index <= items.count ? .success(index - 1)
                : .failure(Self.outOfRange(items.count, names: items.map(name)))
        }
        if let wanted = args["name"]?.stringValue {
            let matches = items.indices.filter { name(items[$0]).contains(wanted) || wanted.contains(name(items[$0])) }
            if matches.count == 1 { return .success(matches[0]) }
            // F-09b §13 item 4 (T-031m): what is on screen, and she may ask which one.
            return .failure(ToolResultBox(matches.isEmpty
                ? ToolReply.choosing(.noMatch, onScreen: items.count, names: items.map(name),
                                     facts: ["asked_name": .string(wanted)]).result
                : ToolReply.choosing(.ambiguous, onScreen: items.count, names: matches.map { name(items[$0]) },
                                     facts: ["asked_name": .string(wanted)]).result))
        }
        if args["preference"]?.stringValue == "nearest" {
            let known = items.indices.compactMap { i in distance(items[i]).map { (i, $0) } }
            guard let nearest = known.min(by: { $0.1 < $1.1 }) else {
                return .failure(ToolResultBox(ToolReply.choosing(.distanceUnknown, onScreen: items.count,
                                                                 names: items.map(name),
                                                                 facts: ["distance_known": false]).result))
            }
            return .success(nearest.0)
        }
        if args["preference"] != nil {
            return .failure(ToolResultBox(ToolReply.choosing(.preferenceNotForDestinations, onScreen: items.count,
                                                             names: items.map(name),
                                                             facts: ["list": "places"]).result))
        }
        return .failure(ToolResultBox(.failure(.invalidFields)))
    }

    private func pickRoute(_ args: JSONValue) -> Result<Int, ToolResultBox> {
        let routes = snapshot.routes
        if let index = Self.index(args) {
            return index <= routes.count ? .success(index - 1) : .failure(Self.outOfRange(routes.count))
        }
        guard let preference = args["preference"]?.stringValue else {
            return .failure(ToolResultBox(ToolReply.choosing(.invalidFields, onScreen: routes.count,
                                                             facts: ["list": "routes"]).result))
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
            return .failure(ToolResultBox(ToolReply.choosing(.preferenceNotForRoutes, onScreen: routes.count,
                                                             facts: ["list": "routes"]).result))
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

    /// F-09b §13 item 4 (T-031m): 「第五个」 with 3 on screen: the count and the names, and she may ask which.
    private static func outOfRange(_ count: Int, names: [String] = []) -> ToolResultBox {
        ToolResultBox(ToolReply.choosing(.outOfRange, onScreen: count, names: names).result)
    }

    /// F-09b §13 item 4 (T-031m): something is still running (`state`); nothing is picked or started yet.
    private static func notYet(_ state: String) -> ToolResult {
        ToolReply.notDone(.optionsNotReady, facts: ["state": .string(state)], may: [.waitBriefly]).result
    }

    /// `place_details` without a target: the destination (if any) and the places on screen; she may ask which.
    private static func whichPlace(_ snapshot: NavigationFlowState) -> ToolResult {
        ToolReply.choosing(.invalidArgument, onScreen: snapshot.places.count, names: snapshot.places.map(\.name),
                           facts: ["destination": snapshot.destination.map { .string($0.name) } ?? .null]).result
    }

    /// F-09b §13 item 5 (T-031n): a success as `facts`, `may`, `must_not` and the built `next`.
    static func said(_ facts: [String: JSONValue], may: [ReplyMay] = [], mustNot: [ReplyMustNot] = []) -> [String: JSONValue] {
        ToolReply.success(facts: facts, may: may, mustNot: mustNot).result.data
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
