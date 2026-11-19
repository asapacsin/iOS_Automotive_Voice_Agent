import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §13 item 1 (T-040j): a tap on the trip cards, the same tool call the voice path makes.
public enum TripTap: Sendable, Hashable {
    case remove(index: Int)
    case move(from: Int, to: Int)
    /// §29 item 4: 「去下一站：名字」 (`trip_next`).
    case next
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
        case .next: "next"
        case .add: "add"
        case .day: "day"
        case .openPlan: "open"
        case .deletePlan: "delete"
        }
    }
}

public struct TripTuning: Sendable, Hashable {
    /// §4 item 4: lookups at once, and the limit of a whole `make_trip_list`.
    /// Device 2026-11-17: 2 of 5 lookups failed with 4 at once (高德's per-second limit); now 2 at once, and a busy,
    /// timed-out or failed lookup is tried up to twice more (`retryDelay`, then twice that).
    public var parallelLookups = 2
    public var resolveLimit = NovaDuration.seconds(15)
    public var retryDelay = NovaDuration.milliseconds(600)
    /// §4 item 6: 高德 results kept per name for the picker, and how long the picker may take (Ultravox's default
    /// tool timeout); after that every open name takes 高德's first result.
    public var candidates = 5
    public var pickLimit = NovaDuration.milliseconds(2500)
    /// §37 item 5 (T-040o): the phone's position is a start only this close to a sight.
    public var startRadiusMeters = 300_000
    /// §37 item 4: hotel search radii around a night's midpoint, tried in turn.
    public var hotelRadii = [3_000, 10_000]
    /// §45 items 2–3 (T-040q): rental search radii around the start and the end, tried in turn.
    public var rentalRadii = [3_000, 10_000]
    /// §36 item 2: Apple's region around the first found name.
    public var abroadRegionMeters = 100_000
    /// §50 item 9 (T-040v): the whole Qwen `ground` request (route `ground`), after which the model's places are used.
    public var groundTimeout = NovaDuration.seconds(30)
    /// §50 item 3: a place abroad is kept only within this many km of the trip city's centre.
    public var areaKm = 50.0
    /// §50 item 3: Photon results asked per trip lookup inside the box.
    public var areaLimit = 5
    /// §50 item 4 `far`: a straight-line estimate over this (4 h) to every other place is "far".
    public var unreachableSeconds = 4 * 3600
    /// §50 item 2: hotels within 1 km of `hotel_near`, else 3 km, at most 5.
    public var hotelNearRadii = [1_000, 3_000]
    public var hotelNearMax = 5
    public init() {}
}

/// F-15b (T-040i): `make_trip_list`, `edit_trip_list`, `trip_next` and `trip_plans`. Owns the app's one trip list (§3), resolves
/// the model's names through 高德 (§4, never taken as places), and routes the list through `NavigationController`
/// one stop at a time (§29). Record lines are codes and numbers only (§7, I-8).
public actor TripPlanner: ToolExecutor {
    public static let tools: Set<String> = ["make_trip_list", "edit_trip_list", "revise_trip_list", "trip_next", "trip_plans"]
    /// §49 item 6 (T-040u): at most this many `trip_needs_fix` results per request.
    public static let maxFixRounds = 2

    /// §49 items 5–8 (T-040u): one request (a `make_trip_list`, or a driver change through `revise_trip_list`): the
    /// `trip_needs_fix` rounds given so far, the names not found, the changes the model made from a check.
    struct FixRequest: Sendable {
        var round = 0
        var notFound: [String] = []
        var changes: [String] = []
        /// What the make had to say besides the fit (hotels not found, rental), said once at the end.
        var notes: [String] = []
        /// §50 item 4 (T-040v): places that failed `far` in the last fit (left out of it), and §50 item 2's named
        /// hotels that are not lodging. Both go to the model as issues.
        var far: [String] = []
        var notHotels: [String] = []
        /// Everything left out for `far` or the hotel-only check during this request, named at the end.
        var dropped: [String] = []
    }
    /// The request waiting for a `revise_trip_list`, nil when none.
    private var fix: FixRequest?
    /// §49 item 4 `hotel`: each night's hotel choices (1-based night) from the last hotel pick, and the nights the
    /// model picked from them. Not saved.
    private var hotelChoices: [Int: [(place: Place, meters: Int)]] = [:]
    private var hotelsChosen: Set<Int> = []
    /// §50 item 2 (T-040v): the hotel choices came from `hotel_near`, so the `hotel` check runs without wishes.
    private var hotelNearActive = false
    /// §50 item 1: Qwen with web search; nil keeps the model's own names.
    private let grounder: (any TripGrounder)?
    /// §50 item 3: the centre and country of an abroad trip's city; nil keeps §36's China-only check.
    private let abroadArea: (@Sendable (String) async -> TripArea?)?
    /// §50 item 3: the area of the trip being made or revised (nil at home or without `abroadArea`).
    private var area: TripArea?
    /// §50 item 7: names sent to the picker by the last `choose`.
    private var pickerNames = 0

    private let search: any PlaceSearch
    /// §36 item 2 (T-040o): Apple's place search for trips abroad; nil keeps every trip on 高德.
    private let abroadSearch: (any PlaceSearch)?
    /// §36 item 2a (2026-11-18): the centre of an abroad trip's `city` ("Tokyo, Japan"), outside China, else nil.
    /// Apple searches near the phone when no area is given, so every Tokyo name came back as a place in China.
    private let abroadCenter: (@Sendable (String) async -> GeoCoordinate?)?
    /// §38 item 2: opens Apple Maps to a stop when 高德's route fails abroad; true when it opened.
    private let onHandoff: (@Sendable (Place) async -> Bool)?
    /// §4 item 6: nil picks 高德's first result.
    private let picker: (any PlacePicker)?
    /// §4 item 9: list changes still running (`make_trip_list`, `edit_trip_list`); `trip_next` waits for them.
    private var changes: [Int: (make: Bool, task: Task<ToolResult, Never>)] = [:]
    private var nextChange = 0
    /// §4 item 9: calls waiting for running list changes (tests read it).
    private(set) var waiting = 0
    private let navigation: NavigationController
    private let origin: @Sendable () async -> GeoCoordinate?
    private let clock: any NovaClock
    private let tuning: TripTuning
    private let onLine: @Sendable (String) -> Void
    private let onChange: @Sendable (TripList) -> Void
    private let onPlans: @Sendable (TripPlansSummary) -> Void
    /// §22 (T-040m): the cards are put away (not saved: a restart shows them).
    public private(set) var cardsHidden = false
    private let onHidden: @Sendable (Bool) -> Void
    /// §26 (T-040n): the driving-time table; nil orders nothing (`ROUTE_TIMES_UNAVAILABLE`).
    private let times: TripTimes?
    /// §36 item 2c (T-040p): the table for `abroad` trips (OSRM); when it fails the plan is ordered on an estimate.
    private let abroadTimes: TripTimes?
    /// §46 (T-040r): photos for stops abroad (Wikipedia); nil keeps abroad stops without photos (§36 item 7).
    private let abroadPhotos: (any PlacePhotoSource)?
    /// §32: `here` or `demo` (模拟导航's demo point) for the `trip order` line.
    private let startLabel: @Sendable () async -> String
    /// §29 item 3: the arrival note for a connected session.
    private let onNote: @Sendable (String) -> Void
    /// Tests only (row 69): changes an ordering before the place check.
    private var tamper: (@Sendable ([TripList]) -> [TripList])?
    func setTamper(_ tamper: @escaping @Sendable ([TripList]) -> [TripList]) { self.tamper = tamper }
    /// §50 item 6 (T-040w): the steps shown while a trip is made or revised; nil shows none.
    private var work: WorkProgressBoard?
    public func setWork(_ board: WorkProgressBoard?) { work = board }
    /// §15: the current plan; `list` is its current day.
    private var plan = TripPlan()
    /// §4 item 7: places already found this launch, by city and asked name (高德 quota and per-second limits:
    /// re-adding or re-making a plan costs no lookup). At most `cacheLimit` entries, oldest dropped.
    private var foundCache: [String: Place] = [:]
    private var cacheOrder: [String] = []
    static let cacheLimit = 64
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
    /// The launch's answers: a found link is applied again when the place is resolved again (text search gives
    /// none); a place known to have none is not asked again.
    private var photoKnown: [String: URL] = [:]
    private var photoNone: Set<String> = []
    /// Lookups still running: not asked again by a change meanwhile (§12 item 6: one call per stop).
    private var photoPending: Set<String> = []
    private var photoTask: Task<Void, Never>?

    /// `origin`: the same as `navigate_to`'s (the usable fix, or the demo origin in 模拟导航), GCJ-02.
    public init(search: any PlaceSearch, navigation: NavigationController, origin: @escaping @Sendable () async -> GeoCoordinate?,
                clock: any NovaClock, tuning: TripTuning = TripTuning(), picker: (any PlacePicker)? = nil,
                files: (any TripFiles)? = nil,
                now: @escaping @Sendable () -> Date = { Date() },
                onLine: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (TripList) -> Void = { _ in },
                onPlans: @escaping @Sendable (TripPlansSummary) -> Void = { _ in },
                onHidden: @escaping @Sendable (Bool) -> Void = { _ in },
                times: TripTimes? = nil,
                startLabel: @escaping @Sendable () async -> String = { "here" },
                onNote: @escaping @Sendable (String) -> Void = { _ in },
                abroadSearch: (any PlaceSearch)? = nil,
                onHandoff: (@Sendable (Place) async -> Bool)? = nil,
                abroadCenter: (@Sendable (String) async -> GeoCoordinate?)? = nil,
                abroadTimes: TripTimes? = nil,
                abroadPhotos: (any PlacePhotoSource)? = nil,
                grounder: (any TripGrounder)? = nil,
                abroadArea: (@Sendable (String) async -> TripArea?)? = nil) {
        self.grounder = grounder
        self.abroadArea = abroadArea
        self.abroadPhotos = abroadPhotos
        self.abroadTimes = abroadTimes
        self.abroadSearch = abroadSearch
        self.abroadCenter = abroadCenter
        self.onHandoff = onHandoff
        self.times = times
        self.startLabel = startLabel
        self.onNote = onNote
        self.onPlans = onPlans
        self.onHidden = onHidden
        self.files = files
        self.now = now
        self.search = search
        self.picker = picker
        self.navigation = navigation
        self.origin = origin
        self.clock = clock
        self.tuning = tuning
        self.onLine = onLine
        self.onChange = onChange
    }

    public var current: TripList { list }
    /// §36 item 2d (T-040p): the city of an `abroad` trip in progress, for `navigate_to`; nil when there is none.
    public var abroadCity: String? {
        guard plan.abroad, !plan.isEmpty, let city = plan.city, !city.isEmpty else { return nil }
        return city
    }
    public var currentPlan: TripPlan { plan }
    /// §50 item 3 (T-040v): the area of an `abroad` trip in progress, for `navigate_to`; nil when none is open.
    public func openTripArea() async -> TripArea? {
        guard abroadCity != nil else { return nil }
        if area == nil, let abroadArea, let city = plan.city { area = await abroadArea(city) }
        return area
    }
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
            if let restored = SavedTripPlans(data: data) {
                saved = restored
            } else {
                ok = false
                files.moveAside(Self.plansFile)
            }
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

    /// §22: `exit_navigation_mode` puts the cards away through this.
    public func connectCards() async {
        await navigation.setTripCards { [weak self] in await self?.hideCards() ?? false }
        await navigation.setTripArrival { [weak self] id in await self?.arrived(id) }
    }

    /// §22 item 2: hides shown cards of a plan with stops; false when there is nothing to hide.
    public func hideCards() -> Bool {
        guard !cardsHidden, plan.stopCount > 0 else { return false }
        setHidden(true)
        return true
    }

    private func setHidden(_ hidden: Bool) {
        guard cardsHidden != hidden else { return }
        cardsHidden = hidden
        onLine("trip cards hidden=\(hidden ? "yes" : "no")")
        onHidden(hidden)
    }

    public func execute(_ call: ToolCall) async -> ToolResult {
        // §22 item 3: any trip tool call shows the cards again.
        if Self.tools.contains(call.name),
           call.name != "trip_plans" || call.arguments["action"]?.stringValue == "open" { setHidden(false) }
        switch call.name {
        case "make_trip_list":
            // §3 item 4: a new list replaces any change still running, so it waits for none.
            return await tracked(call, make: true)
        case "edit_trip_list", "revise_trip_list":
            // §4 item 9: an edit changes the list being made, so it waits for running makes first.
            await waitFor { $0.make }
            return await tracked(call, make: false)
        default:
            // §4 item 9: trip_next and trip_plans use the finished list: they wait until no change is running.
            await waitFor { _ in true }
            return await run(call)
        }
    }

    private func waitFor(_ which: ((make: Bool, task: Task<ToolResult, Never>)) -> Bool) async {
        waiting += 1
        defer { waiting -= 1 }
        var done = Set<Int>()
        while let next = changes.first(where: { !done.contains($0.key) && which($0.value) }) {
            _ = await next.value.task.value
            done.insert(next.key)
        }
    }

    private func tracked(_ call: ToolCall, make: Bool) async -> ToolResult {
        let id = nextChange
        nextChange += 1
        let task = Task { await self.run(call) }
        changes[id] = (make, task)
        // §50 item 6: a make opens the steps; a revise round continues them.
        let steps = call.name == "make_trip_list" || call.name == "revise_trip_list"
        if steps { call.name == "make_trip_list" ? work?.start(.trip) : work?.continueTrip() }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        changes[id] = nil
        // The cards replace the steps; a `trip_needs_fix` round keeps them for the revise; a failure keeps its line.
        if steps, result.data["status"]?.stringValue != "trip_needs_fix" { result.ok ? work?.clear(.trip) : work?.end() }
        return result
    }

    private func run(_ call: ToolCall) async -> ToolResult {
        // The dispatcher validated the call (ToolCatalog.validate); this is the backstop for direct callers.
        if let code = ToolCatalog.validate(call) { return .failure(code) }
        switch call.name {
        case "make_trip_list": return await make(call.arguments)
        case "edit_trip_list": return await edit(call.arguments)
        case "revise_trip_list": return await revise(call.arguments)
        case "trip_next": return await next(call.arguments)
        case "trip_plans": return await plans(call.arguments)
        default: return .failure(.unknownTool)
        }
    }

    // MARK: make_trip_list

    private func make(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        if case .array(let raw)? = args["days"] {
            let dayItems: [[PlaceItem]] = raw.map { day in
                guard case .array(let places) = day else { return [] }
                return Self.items(places)
            }
            return await makeTrip(dayItems, single: false, city: args["city"]?.stringValue, args: args, started: started)
        }
        guard case .array(let raw)? = args["places"] else { return .failure(.invalidFields) }
        let placeItems = Self.items(raw)
        let names = placeItems.map(\.name)
        let city = args["city"]?.stringValue
        let day = Self.int(args["day"])
        // §15 item 2: a day may be at most the number of days + 1.
        if let day, !(1...min(plan.dayCount + 1, TripPlan.maxDays)).contains(day) { return dayOutOfRange() }
        // §37 (T-040o): without `day` the places are a one-day trip with its frame (start, hotels, end).
        if day == nil { return await makeTrip([placeItems], single: true, city: city, args: args, started: started) }
        let ignored = ["start", "end", "hotels", "abroad", "rental"].contains { args[$0] != nil }
        let generation = plan.revision
        let here = await origin()
        let lookups = await resolve(names, city: city, abroad: plan.abroad)
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
            case .keyMissing, .candidates: break
            }
        }
        guard !entries.isEmpty else {
            line(stops: list.count, notFound: notFound.count, duplicates: duplicates.count, since: started)
            return .failure(.noCandidates, advice: "清单里的地点都没有找到，清单没有改。请如实说没找到这些地方。")
        }
        var made = TripList()
        made.replace(entries)
        // §28 item 2: the new list ordered by driving time; when that fails it stays in the order asked.
        let arranged = await ordered([made], dayCount: 1, named: String?.none)
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        if case .success(let o) = arranged, let first = o.days.first { made = first }
        if let day { _ = plan.replaceDay(day, with: made) } else { plan.replaceAll(with: made) }
        changed()
        line(stops: list.count, notFound: notFound.count, duplicates: duplicates.count, since: started)
        let missed = notFound.isEmpty ? "" : "；没找到：\(notFound.joined(separator: "、"))"
        return listResult(changed: nil, notFound: notFound, duplicates: duplicates,
                          next: "只说一句：清单有\(list.count)个地点\(missed)\(Self.unordered(arranged))\(ignored ? "（只改一天时不改出发、酒店和结束）" : "")。不要念整张清单，司机问时再念。")
    }

    /// §15 item 6 and §37 (T-040o): a whole plan of one or several days in one call (parallel per-day calls would race
    /// on `revision`), with its frame: `start`, `hotels` and `end` are searched with the places (§36) and are not
    /// counted in the 16. The same place twice anywhere in the plan is a duplicate; a day where nothing was found stays
    /// as an empty day.
    /// §48 item 1 (T-040t): a place as the model gave it: a name, or `{name, minutes, optional}`.
    struct PlaceItem: Sendable, Hashable {
        let name: String
        let minutes: Int?
        /// §49 item 1 (T-040u): 3 must-see, 2 worth it, 1 extra.
        let importance: Int
        /// §50 item 2 (T-040v): `role: hotel`, a night's hotel given among the places.
        var hotel = false
        var optional: Bool { importance < 3 }
    }

    /// §48 item 1: a plain string is a required place with no minutes; minutes are clamped to 15–600.
    /// §49 item 1: `importance` 1–3, else from `optional` (false → 3, true → 1); a plain string → 3.
    static func items(_ raw: [JSONValue]) -> [PlaceItem] {
        raw.compactMap { v in
            if let name = v.stringValue { return PlaceItem(name: TranscriptText.normalize(name), minutes: nil, importance: 3) }
            guard let name = v["name"]?.stringValue else { return nil }
            let importance = v["importance"]?.intValue.map { TripStop.clampImportance(Int($0)) }
                ?? ((v["optional"]?.boolValue ?? false) ? 1 : 3)
            return PlaceItem(name: TranscriptText.normalize(name), minutes: v["minutes"]?.intValue.map { TripStop.clampMinutes(Int($0)) },
                             importance: importance, hotel: v["role"]?.stringValue == "hotel")
        }
    }

    private func makeTrip(_ modelItems: [[PlaceItem]], single: Bool, city: String?, args: JSONValue,
                          started: NovaInstant) async -> ToolResult {
        var dayItems = modelItems
        let startName = args["start"]?.stringValue.map(TranscriptText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let endName = args["end"]?.stringValue.map(TranscriptText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let hotelNames: [String] = if case .array(let h)? = args["hotels"] {
            h.compactMap(\.stringValue).map(TranscriptText.normalize).filter { !$0.isEmpty }
        } else { [] }
        // §48 item 1: `day_count` with places, else one day per group.
        let dayCount = single ? min(max(Self.int(args["day_count"]) ?? 1, 1), TripPlan.maxDays) : max(1, modelItems.count)
        let pace = args["pace"]?.stringValue.flatMap(TripFitter.Pace.init(rawValue:)) ?? .normal
        // §37 item 1: one hotel for every night, or one per night.
        if !hotelNames.isEmpty, hotelNames.count != 1, hotelNames.count != dayCount - 1 {
            return .failure(.invalidFields, advice: "hotels 只能填一个（每晚都住），或者每晚一个（\(dayCount)天=\(max(dayCount - 1, 1))个）。请重新调用。")
        }
        // §36 item 2a: a trip abroad needs its city to search in.
        let abroadAsked = args["abroad"]?.boolValue ?? false
        if abroadAsked, abroadSearch != nil, abroadCenter != nil || abroadArea != nil,
           (city ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            return .failure(.invalidFields, advice: "abroad=true 时必须填 city：英文城市名加国家，比如 \"Tokyo, Japan\"。请马上重新调用，不要告诉司机。")
        }
        let hotelNear = args["hotel_near"]?.stringValue.map(TranscriptText.normalize).flatMap { $0.isEmpty ? nil : $0 }
        let wishes = args["wishes"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let generation = plan.revision
        // §50 item 1 (T-040v): abroad, the model's places become real places from Qwen with web search, before any lookup.
        var groundHotels: [TripGroundHotel] = []
        if abroadAsked, abroadSearch != nil, let grounder, let city, !city.trimmingCharacters(in: .whitespaces).isEmpty {
            let request = TripGroundRequest(city: city, days: dayCount,
                                            places: modelItems.flatMap { $0 }.map {
                                                TripGroundPlace(name: $0.name, minutes: $0.minutes, importance: $0.importance)
                                            },
                                            wishes: wishes, start: startName, end: endName, hotelNear: hotelNear)
            work?.step(WorkProgress.tripFind)
            if let grounded = await ground(request, with: grounder) {
                let items = grounded.places.map {
                    PlaceItem(name: TranscriptText.normalize(TripGround.written($0)), minutes: $0.minutes.map(TripStop.clampMinutes),
                              importance: TripStop.clampImportance($0.importance))
                }
                // The model's day groups are kept as they are; one group (`places`) is replaced.
                // §50 item 2: places marked `role: hotel` stay as the model gave them.
                if single, !items.isEmpty { dayItems = [items + modelItems.flatMap { $0 }.filter(\.hotel)] }
                groundHotels = grounded.hotels
            }
            guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        }
        let dayNames = dayItems.map { $0.map(\.name) }
        let flat = dayNames.flatMap { $0 }
        let extras = [startName, endName].compactMap { $0 } + hotelNames
        let here = await origin()
        let searched = await resolveTrip(flat + extras, city: city, abroad: args["abroad"]?.boolValue ?? false)
        let lookups = searched.lookups
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        if lookups.contains(where: { if case .keyMissing = $0 { true } else { false } }) {
            line(stops: plan.stopCount, notFound: flat.count, duplicates: 0, since: started)
            return .failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有做成清单。")
        }
        var seen = Set<String>()
        var notFound: [String] = []
        var duplicates: [String] = []
        var lists: [TripList] = []
        // §48: optional places go to the fit beside the plan (with their group's day when there are groups).
        var optionalStops: [(day: Int?, stop: TripStop)] = []
        // §50 item 2: places marked as a night's hotel: lodging ones become the night's hotel; others fail the
        // hotel-only check (`not_found` 「<名字>不是酒店」) and are not used.
        var placeHotels: [TripStop] = []
        var notHotels: [String] = []
        var offset = 0
        for (g, items) in dayItems.enumerated() {
            var required: [TripStop] = []
            for item in items {
                defer { offset += 1 }
                switch lookups[offset] {
                case .found(let place):
                    if item.hotel {
                        if let kind = place.kind, kind != .hotel {
                            notHotels.append(item.name)
                        } else if seen.insert(place.id).inserted {
                            placeHotels.append(TripStop(index: 0, asked: item.name, place: place, distanceMeters: nil, role: .hotel))
                        }
                    } else if seen.insert(place.id).inserted {
                        let stop = TripStop(index: 0, asked: item.name, place: place, distanceMeters: distance(here, place),
                                            minutes: item.minutes, importance: item.importance)
                        if item.optional { optionalStops.append((single ? nil : g, stop)) } else { required.append(stop) }
                    } else {
                        duplicates.append(item.name)
                    }
                case .missing(let reason):
                    notFound.append(item.name)
                    onLine("trip lookup index=\(offset + 1) ok=no reason=\(reason)")
                case .keyMissing, .candidates: break
                }
            }
            // `places` over several days: the required places in the asked order, 16 a day, before the fit.
            let chunks = single ? max(1, min(dayCount, (required.count + TripList.maxStops - 1) / TripList.maxStops)) : 1
            for c in 0..<chunks {
                var made = TripList()
                made.arrange(Array(required.dropFirst(c * TripList.maxStops).prefix(TripList.maxStops)))
                lists.append(made)
            }
        }
        if single { while lists.count < dayCount { lists.append(TripList()) } }
        guard lists.contains(where: { $0.count > 0 }) || !optionalStops.isEmpty else {
            line(stops: plan.stopCount, notFound: notFound.count, duplicates: duplicates.count, since: started)
            return .failure(.noCandidates, advice: "清单里的地点都没有找到，清单没有改。请如实说没找到这些地方。")
        }
        // §37 item 1: a frame name not found is left out and named in not_found.
        func frameStop(_ name: String?, _ role: TripRole) -> TripStop? {
            guard let name else { return nil }
            defer { offset += 1 }
            guard case .found(let place) = lookups[offset] else {
                notFound.append(name)
                if case .missing(let reason) = lookups[offset] { onLine("trip lookup index=\(offset + 1) ok=no reason=\(reason)") }
                return nil
            }
            return TripStop(index: 0, asked: name, place: place, distanceMeters: distance(here, place), role: role)
        }
        let startStop = frameStop(startName, .start)
        let endStop = frameStop(endName, .end)
        var hotels = hotelNames.map { frameStop($0, .hotel) }
        if hotelNames.isEmpty, !placeHotels.isEmpty {
            hotels = placeHotels.count == dayCount - 1 ? placeHotels.map { Optional($0) } : [placeHotels[0]]
        }
        // §50 item 2 hotel-only check: a named hotel abroad whose OpenStreetMap kind is not lodging is not used.
        if searched.abroad {
            hotels = hotels.map { stop in
                guard let stop, let kind = stop.place.kind, kind != .hotel else { return stop }
                notHotels.append(stop.asked)
                return nil
            }
        }
        // §50 item 2: hotels near the named place (when the driver named no hotel).
        var nearChoices: [(place: Place, meters: Int)] = []
        var nearNote: String?
        if let hotelNear, hotelNames.isEmpty, placeHotels.isEmpty, dayCount > 1 {
            let found = await hotelsNear(hotelNear, city: city, abroad: searched.abroad, grounded: groundHotels)
            guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
            if let found, let first = found.first {
                nearChoices = found
                hotels = [TripStop(index: 0, asked: "酒店", place: first.place, distanceMeters: nil, role: .hotel, picked: true)]
            } else {
                nearNote = "没找到\(hotelNear)，换一个更具体的地点"
            }
        }
        // §45 items 2–5 (T-040q): a rental pickup near the start and a return near the end, picked by code.
        let rentalAsked = args["rental"]?.boolValue ?? false
        var rentalNotes: [String] = []
        var pickup: TripStop?
        var dropoff: TripStop?
        if rentalAsked {
            let rentals = await pickRentals(start: startStop, end: endStop, here: here,
                                            lastSight: lists.last(where: { $0.count > 0 })?.stops.last, abroad: searched.abroad)
            guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
            pickup = rentals.pickup
            dropoff = rentals.dropoff
            rentalNotes = rentals.notes
        }
        let source = Self.layout(lists, start: startStop, end: endStop, hotels: hotels, pickup: pickup, dropoff: dropoff)
        // §28 item 2, §37 items 3–5: ordered by driving time between the fixed ends, hotels picked when none named.
        // §48 item 4: fitted to the day budget.
        let fit = FitRequest(pace: pace, groups: !single, extra: optionalStops)
        let pickHotels = ((hotelNames.isEmpty && placeHotels.isEmpty) || (!notHotels.isEmpty && hotels.allSatisfy { $0 == nil }))
            && nearChoices.isEmpty
        let (arranged, far) = await orderedNear(source, dayCount: dayCount, pickHotels: pickHotels, abroad: searched.abroad,
                                                rentalAsked: rentalAsked, fit: fit)
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        var extra: [String: JSONValue] = [:]
        var notes: [String] = []
        var spare: [TripStop] = []
        var fitted = false
        var fitPart: [String] = []
        switch arranged {
        case .success(let o):
            lists = o.days
            spare = o.spare
            if let m = o.dayMinutes {
                fitted = true
                fitPart = Self.fitNotes(m, budget: pace.budgetMinutes, spare: spare.map(\.place.name))
                notes += fitPart
            }
            if o.estimated { extra["times"] = "estimated" }
            if !o.nightsWithoutHotel.isEmpty {
                notes.append("第\(o.nightsWithoutHotel.map(String.init).joined(separator: "、"))晚附近没找到酒店")
            }
            if o.picked > 0 { notes.append("酒店是自动挑的，司机可以换") }
        case .failed(let code):
            // §48 item 10: nothing fitted or dropped: the model's order and groups, the required places first.
            let unfitted = Self.withOptional(lists, optionalStops)
            lists = Self.layout(unfitted.days, start: startStop, end: endStop, hotels: hotels, pickup: pickup, dropoff: dropoff)
            spare = unfitted.spare
            if code == .noStart {
                extra["order"] = .string(ToolErrorCode.noStart.rawValue)
            } else {
                // §42: the frame as built, unordered.
                frameLine(start: startStop != nil ? "named" : "none", end: endStop != nil,
                          hotels: hotels.contains { $0 != nil } ? "named" : "none", nights: max(dayCount - 1, 0), picked: 0,
                          rental: Self.rentalLabel(source, asked: rentalAsked))
            }
        }
        if let nearNote { notes.append(nearNote) }
        // §45 items 5 and 8: a rental place not found is said once; booking is the driver's.
        if rentalAsked { notes += rentalNotes + ["租车需要提前在网上预订"] }
        plan.replaceAll(withDays: lists)
        plan.spare = spare
        plan.budgetMinutes = fitted ? pace.budgetMinutes : nil
        plan.abroad = searched.abroad
        plan.city = searched.abroad ? city?.trimmingCharacters(in: .whitespaces) : nil
        changed()
        line(stops: plan.stopCount, notFound: notFound.count, duplicates: duplicates.count, since: started)
        // §49 item 2 (T-040u): the wishes go with the plan; the hotel choices of this pick replace older ones.
        plan.wishes = wishes
        if case .success(let o) = arranged { hotelChoices = o.hotelChoices } else { hotelChoices = [:] }
        // §50 item 2: the `hotel` check offers the hotels near the named place, with the distance to it.
        hotelNearActive = !nearChoices.isEmpty
        if hotelNearActive, case .success = arranged, !far.contains(where: { f in nearChoices.contains { $0.place.name == f } }) {
            hotelChoices = Dictionary(uniqueKeysWithValues: (1..<max(dayCount, 2)).map { ($0, nearChoices) })
        }
        hotelsChosen = []
        let ask = extra["order"] != nil ? "。NO_START：然后只问一句：「从哪里出发？机场还是酒店？」" : ""
        let unordered = extra["order"] != nil ? "" : Self.unordered(arranged)
        let answer: ([String], [String]) -> ToolResult = { [self] missing, more0 in
            let missed = missing.isEmpty ? "" : "；没找到：\(missing.joined(separator: "、"))"
            let all = more0 + notes
            let more = all.isEmpty ? "" : "；" + all.joined(separator: "；")
            if single, plan.dayCount == 1 {
                return listResult(changed: nil, notFound: missing, duplicates: duplicates,
                                  next: "只说一句：清单有\(list.count)个地点\(missed)\(unordered)\(more)\(ask)。不要念整张清单，司机问时再念。",
                                  extra: extra)
            }
            let perDay = plan.days.enumerated().map { "第\($0.offset + 1)天\($0.element.stops.filter { $0.role == .sight }.count)个" }
                .joined(separator: "，")
            return listResult(changed: nil, notFound: missing, duplicates: duplicates,
                              next: "用一两句话说：\(plan.dayCount)天的行程做好了（\(perDay)），每天只说一两个主要地方\(missed)\(unordered)\(more)\(ask)。不要念整张清单，司机问时再念。",
                              extra: extra)
        }
        // §49 items 4–6: a fitted plan is checked; a failure goes back to the model before anything is said.
        guard fitted else {
            fix = nil
            return answer(notFound, [])
        }
        return checked(FixRequest(notFound: notFound, notes: notes.filter { !fitPart.contains($0) }, far: far, notHotels: notHotels,
                                  dropped: far + notHotels), answer: answer)
    }

    // MARK: §50 grounding, hotels near a place, far places (T-040v)

    /// §50 items 1 and 9: one `ground` request within `groundTimeout`; nil (the model's places) on a timeout, an
    /// error, an answer without search results or with wrong fields. `trip ground vendor=qwen …` either way.
    private func ground(_ request: TripGroundRequest, with grounder: any TripGrounder) async -> TripGroundAnswer? {
        let started = clock.now
        let (stream, feed) = AsyncStream.makeStream(of: Result<TripGroundAnswer, TripGroundError>.self)
        let work = Task {
            do { feed.yield(.success(try await grounder.ground(request))) } catch let e as TripGroundError {
                feed.yield(.failure(e))
            } catch { feed.yield(.failure(.failed)) }
        }
        let clock = clock, limit = tuning.groundTimeout
        let timer = Task {
            try? await clock.sleep(until: started + limit)
            if !Task.isCancelled { feed.yield(.failure(.timeout)) }
        }
        var answer: Result<TripGroundAnswer, TripGroundError> = .failure(.failed)
        for await a in stream {
            answer = a
            break
        }
        work.cancel()
        timer.cancel()
        feed.finish()
        let elapsed = ms(since: started)
        switch answer {
        case .success(let a):
            let (places, added) = TripGround.keepMustSee(model: request.places, answer: a.places)
            let kept3 = places.filter { $0.importance == 3 }.count
            onLine("trip ground vendor=qwen places=\(places.count) hotels=\(a.hotels.count) kept3=\(kept3) added=\(added) ok=yes ms=\(elapsed)")
            return TripGroundAnswer(places: places, hotels: a.hotels, area: a.area)
        case .failure(let e):
            let kept3 = request.places.filter { $0.importance == 3 }.count
            onLine("trip ground vendor=qwen places=\(request.places.count) hotels=0 kept3=\(kept3) added=0 ok=fallback reason=\(e.rawValue) ms=\(elapsed)")
            return nil
        }
    }

    /// §50 item 2: the named place first (inside the trip area abroad), then hotels within 1 km of it, else 3 km, at
    /// most 5, nearest first, each with its distance to that place. The grounded hotel names are tried first; only one
    /// within 1 km is kept. nil when the place is not found; empty when no hotel is near it.
    private func hotelsNear(_ name: String, city: String?, abroad: Bool, grounded: [TripGroundHotel]) async -> [(place: Place, meters: Int)]? {
        let lookups = await resolve([name], city: abroad ? nil : city, abroad: abroad, near: area?.center)
        guard case .found(let target)? = lookups.first else { return nil }
        let vendor = abroad ? (abroadSearch ?? search) : search
        func meters(_ p: Place) -> Int { Int(SelfPosition.distanceMeters(target.coordinate, p.coordinate).rounded()) }
        var out: [(place: Place, meters: Int)] = []
        if !grounded.isEmpty {
            let names = grounded.map { TranscriptText.normalize(TripGround.written(TripGroundPlace(name: $0.name, english: $0.english,
                                                                                                    minutes: nil, importance: 3))) }
            let found = await resolve(names, city: abroad ? nil : city, abroad: abroad, near: target.coordinate)
            if let close = found.compactMap({ if case .found(let p) = $0 { p } else { nil } })
                .filter({ ($0.kind == nil || $0.kind == .hotel) && meters($0) <= (tuning.hotelNearRadii.first ?? 1_000) })
                .min(by: { meters($0) < meters($1) }) {
                out.append((close, meters(close)))
            }
        }
        for radius in tuning.hotelNearRadii {
            guard !Task.isCancelled else { return out }
            let found = (try? await vendor.aroundOnly("酒店", center: target.coordinate, radiusMeters: radius, sort: .distance)) ?? []
            let usable = found.filter { p in
                meters(p) <= radius && (!abroad || p.countryCode == nil || !TripRegion.isChina(p.countryCode))
                    && !out.contains { $0.place.id == p.id }
            }.sorted { meters($0) < meters($1) }
            if !usable.isEmpty {
                out += usable.map { ($0, meters($0)) }
                break
            }
        }
        return Array(out.prefix(tuning.hotelNearMax))
    }

    /// §50 item 4 `far`: the plan ordered; when its times are the straight-line estimate (no OSRM time), a place whose
    /// estimate to every other place is over `unreachableSeconds` is left out and the rest are fitted again (a far
    /// hotel is replaced by §37's search). Returns the result and the far places' names.
    private func orderedNear(_ source: [TripList], dayCount: Int, pickHotels: Bool, abroad: Bool?, rentalAsked: Bool = false,
                             fit: FitRequest) async -> (OrderResult, [String]) {
        let first = await ordered(source, dayCount: dayCount, named: String?.none, pickHotels: pickHotels, abroad: abroad,
                                  rentalAsked: rentalAsked, fit: fit)
        guard case .success(let o) = first, o.estimated else { return (first, []) }
        let all = o.days.flatMap(\.stops)
        let farIDs = TripGround.far(all.map(\.place), limitSeconds: tuning.unreachableSeconds)
        guard !farIDs.isEmpty, !Task.isCancelled else { return (first, []) }
        var names: [String] = []
        for stop in all where farIDs.contains(stop.place.id) && !names.contains(stop.place.name) { names.append(stop.place.name) }
        let hotelFar = all.contains { $0.role == .hotel && farIDs.contains($0.place.id) }
        let kept = source.map { list -> TripList in
            var l = TripList()
            l.arrange(list.stops.filter { !farIDs.contains($0.place.id) })
            return l
        }
        var again = fit
        again.extra = fit.extra.filter { !farIDs.contains($0.stop.place.id) }
        let second = await ordered(kept, dayCount: dayCount, named: String?.none, pickHotels: pickHotels || hotelFar, abroad: abroad,
                                   rentalAsked: rentalAsked, fit: again)
        return (second, names)
    }

    // MARK: §49 checks and revisions (T-040u)

    /// §49 item 4: the checks over the current plan.
    private func runChecks(_ request: FixRequest) -> [TripChecks.Issue] {
        guard let budget = plan.budgetMinutes else { return [] }
        let days = plan.days.map { day -> TripChecks.Day in
            let sights = day.stops.filter { $0.role == .sight }
            let driving = Int((Double(day.stops.reduce(0) { $0 + ($1.legSeconds ?? 0) }) / 60).rounded())
            let area = sights.last.map { $0.place.district ?? $0.place.name }
            return TripChecks.Day(minutes: Self.dayMinutes(day), drivingMinutes: driving,
                                  onlyMustSee: !sights.isEmpty && sights.allSatisfy { $0.importance == 3 }, area: area)
        }
        var hotels: [Int: [TripChecks.HotelChoice]] = [:]
        if plan.wishes != nil || hotelNearActive {
            for (night, list) in hotelChoices where !hotelsChosen.contains(night) && night < plan.dayCount {
                hotels[night] = list.map { TripChecks.HotelChoice(name: $0.place.name, meters: $0.meters) }
            }
        }
        return TripChecks.run(notFound: request.notFound, days: days, budgetMinutes: budget, spareEmpty: plan.spare.isEmpty,
                              hotels: hotels, notHotels: request.notHotels, far: request.far, city: TripGround.cityName(plan.city))
    }

    /// §49 items 5–6: checks the plan; while a check fails and fewer than 2 rounds were given, the result is
    /// `trip_needs_fix` (nothing said); else the normal answer, built by `answer(notFound, extra notes)` with the
    /// changes made and the issues still failing that §48 item 7 does not say already.
    private func checked(_ request: FixRequest, answer: ([String], [String]) -> ToolResult) -> ToolResult {
        let started = clock.now
        var request = request
        let issues = runChecks(request)
        let count = { (k: TripChecks.Kind) in issues.filter { $0.kind == k }.count }
        onLine("trip check round=\(request.round) not_found=\(count(.notFound)) over=\(count(.over)) driving=\(count(.driving)) under=\(count(.under)) hotel=\(count(.hotel)) far=\(count(.far)) ms=\(ms(since: started))")
        if !issues.isEmpty, request.round < Self.maxFixRounds {
            request.round += 1
            fix = request
            var data = answer(request.notFound, []).data
            data["status"] = "trip_needs_fix"
            data["round"] = .int(Int64(request.round))
            data["issues"] = .array(issues.map { .string($0.line) })
            data["wishes"] = plan.wishes.map(JSONValue.string) ?? .null
            data["next"] = "先不要跟司机说话，直接调用 revise_trip_list 按 issues 改，改完会再检查。"
            return .success(data)
        }
        fix = nil
        let leftover = issues.filter { $0.kind == .driving }.map(\.line)
        // §50 item 4: a place still failing after round 2 is dropped and named.
        var seen = Set<String>()
        let dropped = request.dropped.filter { seen.insert($0).inserted }
        let droppedLine = dropped.isEmpty ? [] : ["去掉了\(dropped.joined(separator: "、"))（开车到不了、太远或者不是酒店）"]
        return answer(request.notFound, request.changes + leftover + droppedLine)
    }

    /// §49 items 7–8: `revise_trip_list`: replace, add, drop, pick hotels, change the pace; then fit and check again.
    private func revise(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        var counts = (replace: 0, add: 0, drop: 0, hotels: 0)
        func log(_ result: ToolResult, round: Int) -> ToolResult {
            let code = result.ok ? "none" : (result.code?.rawValue ?? "none")
            onLine("trip revise round=\(round) replace=\(counts.replace) add=\(counts.add) drop=\(counts.drop) hotels=\(counts.hotels) ok=\(result.ok ? "yes" : "no") code=\(code) ms=\(ms(since: started))")
            return result
        }
        // §49 item 8: with no request waiting, the call opens one of its own.
        work?.step(WorkProgress.tripRevise)
        var request = fix ?? FixRequest()
        guard plan.budgetMinutes != nil, plan.allStops.contains(where: { $0.stop.role == .sight }) else {
            return log(failure(.noRevision), round: request.round)
        }
        func array(_ k: String) -> [JSONValue] { if case .array(let a)? = args[k] { a } else { [] } }
        func item(_ v: JSONValue) -> PlaceItem? { Self.items([v]).first }
        let replaces = array("replace").compactMap { r -> (name: String, with: PlaceItem)? in
            guard let n = r["name"]?.stringValue, let w = r["with"].flatMap(item) else { return nil }
            return (TranscriptText.normalize(n), w)
        }
        let adds = array("add").compactMap(item)
        let drops = array("drop").compactMap(\.stringValue).map(TranscriptText.normalize)
        let picks = array("hotels").compactMap { h -> (night: Int, pick: String)? in
            guard let n = Self.int(h["night"]), let p = h["pick"]?.stringValue else { return nil }
            return (n, TranscriptText.normalize(p))
        }
        let pace = args["pace"]?.stringValue.flatMap(TripFitter.Pace.init(rawValue:))
        counts = (replaces.count, adds.count, drops.count, picks.count)
        guard !(replaces.isEmpty && adds.isEmpty && drops.isEmpty && picks.isEmpty && pace == nil) else {
            return log(.failure(.invalidFields), round: request.round)
        }
        // A name must be a sight of the plan, a spare place, or (for replace) a name not found.
        let sights = plan.allStops.filter { $0.stop.role == .sight }.map(\.stop)
        func inPlan(_ name: String) -> Bool { sights.contains { TripList.matches($0, name) } }
        func inSpare(_ name: String) -> Bool { plan.spare.contains { TripList.matches($0, name) } }
        for r in replaces where !(inPlan(r.name) || inSpare(r.name) || request.notFound.contains(r.name)) {
            return log(.failure(.invalidFields), round: request.round)
        }
        for d in drops where !(inPlan(d) || inSpare(d) || request.notFound.contains(d)) {
            return log(.failure(.invalidFields), round: request.round)
        }
        var pickedPlaces: [(night: Int, place: Place)] = []
        for p in picks {
            guard let choice = hotelChoices[p.night]?.first(where: {
                TranscriptText.normalize($0.place.name) == p.pick || TranscriptText.normalize($0.place.name).contains(p.pick)
            }) else { return log(.failure(.invalidFields), round: request.round) }
            pickedPlaces.append((p.night, choice.place))
        }
        // New and replacing names are searched as places of the trip (§36 item 2), inside its area (§50 item 3).
        if plan.abroad, area == nil, let abroadArea, let city = plan.city { area = await abroadArea(city) }
        let generation = plan.revision
        let newItems = replaces.map(\.with) + adds
        let lookups = newItems.isEmpty ? [] : await resolve(newItems.map(\.name), city: plan.city, abroad: plan.abroad, near: regionHint())
        guard !Task.isCancelled, plan.revision == generation else { return log(.failure(.optionsStale), round: request.round) }
        if lookups.contains(where: { if case .keyMissing = $0 { true } else { false } }) {
            return log(.failure(.amapWebKeyMissing, advice: "高德的查询服务还没有配置好，请如实说明没有改行程。"), round: request.round)
        }
        func found(_ i: Int, _ item: PlaceItem) -> TripStop? {
            guard case .found(let place) = lookups[i] else {
                if !request.notFound.contains(item.name) { request.notFound.append(item.name) }
                return nil
            }
            return TripStop(index: 0, asked: item.name, place: place, distanceMeters: nil, minutes: item.minutes,
                            importance: item.importance)
        }
        var source = plan.days.map(\.stops)
        var spare = plan.spare
        var extras: [TripStop] = []
        for (i, r) in replaces.enumerated() {
            let new = found(i, r.with)
            if let k = request.notFound.firstIndex(of: r.name) {
                request.notFound.remove(at: k)
                if let new {
                    extras.append(new)
                    request.changes.append("\(r.name)没找到，换成了\(new.place.name)")
                }
                continue
            }
            spare.removeAll { TripList.matches($0, r.name) }
            var replaced = false
            source = source.map { day in
                day.compactMap { s in
                    guard s.role == .sight, s.mark == nil, TripList.matches(s, r.name) else { return s }
                    replaced = true
                    return new
                }
            }
            if replaced, let new { request.changes.append("\(r.name)换成了\(new.place.name)") }
        }
        for (j, a) in adds.enumerated() {
            if let new = found(replaces.count + j, a) {
                extras.append(new)
                request.changes.append("加了\(new.place.name)")
            }
        }
        for d in drops {
            request.notFound.removeAll { $0 == d }
            spare.removeAll { TripList.matches($0, d) }
            source = source.map { day in day.filter { !($0.role == .sight && $0.mark == nil && TripList.matches($0, d)) } }
            request.changes.append("去掉了\(d)")
        }
        // §49 item 7 `hotels`: night k's hotel is the last stop of day k and the first of day k+1.
        for p in pickedPlaces {
            let hotel = TripStop(index: 0, asked: "酒店", place: p.place, distanceMeters: nil, role: .hotel)
            for d in [p.night - 1, p.night] where source.indices.contains(d) {
                if d == p.night - 1, let i = source[d].lastIndex(where: { $0.role == .hotel }) { source[d][i] = hotel }
                if d == p.night, let i = source[d].firstIndex(where: { $0.role == .hotel }) { source[d][i] = hotel }
            }
            hotelsChosen.insert(p.night)
            request.changes.append("第\(p.night)晚住\(p.place.name)")
        }
        let newPace = pace ?? TripFitter.Pace(budgetMinutes: plan.budgetMinutes)
        let lists = source.map { stops -> TripList in
            var list = TripList()
            list.arrange(stops)
            return list
        }
        let fitRequest = FitRequest(pace: newPace, extra: (spare + extras).map { (day: nil, stop: $0) })
        let (result, far) = await orderedNear(lists, dayCount: plan.dayCount, pickHotels: true, abroad: nil, fit: fitRequest)
        guard !Task.isCancelled, plan.revision == generation else { return log(.failure(.optionsStale), round: request.round) }
        // §50 item 4: this fit's `far` places go to the model; the hotel-only issue was answered by the make's fit.
        request.far = far
        request.notHotels = []
        request.dropped += far
        switch result {
        case .failed(let code): return log(failure(code), round: request.round)
        case .success(let o):
            plan.arrange(days: o.days)
            plan.spare = o.spare
            plan.budgetMinutes = newPace.budgetMinutes
            changed()
            let fitNote = Self.fitNotes(o.dayMinutes ?? plan.days.map(Self.dayMinutes), budget: newPace.budgetMinutes,
                                        spare: o.spare.map(\.place.name))
            let estimated = o.estimated
            let round = request.round
            let makeNotes = request.notes
            let answer: ([String], [String]) -> ToolResult = { [self] missing, more in
                let missed = missing.isEmpty ? "" : "没找到：\(missing.joined(separator: "、"))；"
                let notes = (more + fitNote + makeNotes).joined(separator: "；")
                return listResult(changed: "revised", notFound: missing,
                                  next: "只说一次，用一两句话：\(missed)\(notes)\(estimated ? "；时间是估算的" : "")。不要念整张清单，司机问时再念。",
                                  extra: estimated ? ["times": "estimated"] : [:])
            }
            return log(checked(request, answer: answer), round: round)
        }
    }

    /// §37 item 2: the frame put round the days in the asked order (used before ordering, and kept when it fails):
    /// day 1 from `start`, night k's hotel last on day k and first on day k+1, `end` last on the last day.
    /// `hotels`: one for every night, or one per night (nil where it was not found).
    /// §45 item 4 (T-040q): `pickup` right after `start` on day 1, `dropoff` just before `end` on the last day.
    /// §48 item 10: the optional places after the required ones, on their group's day (else the first day with room),
    /// at most 16 a day; the ones with no room are spare.
    static func withOptional(_ days: [TripList], _ optional: [(day: Int?, stop: TripStop)]) -> (days: [TripList], spare: [TripStop]) {
        var stops = days.map(\.stops)
        var spare: [TripStop] = []
        for o in optional {
            let d = o.day.map { min($0, stops.count - 1) } ?? stops.firstIndex { $0.count < TripList.maxStops }
            if let d, stops[d].count < TripList.maxStops { stops[d].append(o.stop) } else { spare.append(o.stop) }
        }
        return (stops.map { s in
            var list = TripList()
            list.arrange(s)
            return list
        }, spare)
    }

    static func layout(_ days: [TripList], start: TripStop?, end: TripStop?, hotels: [TripStop?],
                       pickup: TripStop? = nil, dropoff: TripStop? = nil) -> [TripList] {
        let nights = max(days.count - 1, 0)
        func hotel(_ night: Int) -> TripStop? {
            guard night < nights else { return nil }
            if hotels.count == 1 { return hotels[0] }
            return night < hotels.count ? hotels[night] : nil
        }
        return days.enumerated().map { d, day in
            var stops: [TripStop] = []
            if d == 0, let start { stops.append(start) }
            if d == 0, let pickup { stops.append(pickup) }
            if d > 0, let h = hotel(d - 1) { stops.append(h) }
            stops += day.stops
            if d < nights, let h = hotel(d) { stops.append(h) }
            if d == days.count - 1, let dropoff { stops.append(dropoff) }
            if d == days.count - 1, let end { stops.append(end) }
            var list = TripList()
            list.arrange(stops)
            return list
        }
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
            return listResult(changed: "removed", next: "只说一句：去掉了\(removed)，现在清单有\(list.count)个地点。\(overNote())",
                              extra: ["removed": .string(removed)])
        case "move" where args["to_day"] != nil:
            return await moveToDay(index: index, toDay: Self.int(args["to_day"]) ?? 0)
        case "reorganize":
            return await reorganize(start: args["start"]?.stringValue, days: Self.int(args["days"]))
        case "visited", "skip":
            guard let index, (1...n).contains(index) else { return outOfRange() }
            let mark: TripMark = action == "visited" ? .visited : .skipped
            let name = list.stops[index - 1].place.name
            list.setMark(at: index, mark)
            // §37 item 7: a night's hotel is one place on two days; 「已经到了」 there ends the day.
            if action == "visited" { markOtherCopy(day: plan.currentDay, index: index, mark) }
            changed()
            onLine("trip visit index=\(index) day=\(plan.currentDay) by=\(action == "visited" ? "voice" : "skip")")
            return listResult(changed: action, next: "只说一句：\(name)\(action == "visited" ? "记为去过了" : "跳过了")。")
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
                // §37 item 1: the frame (start, hotels, end) is not counted in the 16.
                guard list.stops.filter({ $0.role == .sight }).count < TripList.maxStops else { return failure(.tripTooLong) }
            } else {
                guard let index, (1...n).contains(index) else { return outOfRange() }
            }
            let generation = plan.revision
            let here = await origin()
            // §48 item 6 (T-040t): 「把X也加上」 with X spare takes that place, with no new search.
            let spareIndex = action == "add" ? plan.spare.firstIndex(where: { TripList.matches($0, name) }) : nil
            let lookup: Lookup = if let spareIndex { .found(plan.spare[spareIndex].place) } else {
                await resolve([name], city: nil, abroad: plan.abroad, near: regionHint()).first ?? .missing("failed")
            }
            // §3 item 4: a newer change while this lookup ran wins; this one changes nothing.
            guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
            let place: Place
            switch lookup {
            case .found(let found): place = found
            case .candidates: return failure(.notFound)
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
            var stop = TripStop(index: 0, asked: name, place: place, distanceMeters: distance(here, place))
            if let spareIndex {
                let kept = plan.spare.remove(at: spareIndex)
                stop.minutes = kept.minutes
                stop.optional = kept.optional
            }
            if let replacing {
                // §37 items 2 and 4: a replaced start, hotel or end keeps its role; the driver chose it (not picked).
                let old = list.stops[replacing - 1]
                stop.role = old.role
                list.set(stop, at: replacing)
                if old.role == .hotel { replaceOtherCopy(day: plan.currentDay, index: replacing, of: old, with: stop) }
                changed()
                return listResult(changed: "replaced", next: "只说一句：第\(replacing)个换成了\(place.name)，现在清单有\(list.count)个地点。\(overNote())")
            }
            // Without an index a sight goes before the day's closing hotel or end (and a rental return before it, §45).
            let closingRoles: Set<TripRole> = [.hotel, .end, .rentalReturn]
            // The day's first stop is its head (a morning hotel copy is also a hotel), never part of the closing run.
            let head = [TripRole.start, .hotel].contains(list.stops.first?.role) ? 1 : 0
            let closing = min(list.stops.reversed().prefix { closingRoles.contains($0.role) }.count, max(n - head, 0))
            list.insert(stop, at: index ?? (closing > 0 ? n - closing + 1 : nil))
            changed()
            return listResult(changed: "added", next: "只说一句：加上了\(place.name)，现在清单有\(list.count)个地点。\(overNote())")
        default:
            return .failure(.invalidFields)
        }
    }

    // MARK: Ordering (§26–§28, T-040n)

    private struct Ordered {
        let days: [TripList]
        /// §37 item 4: hotels the app picked this time, and the nights (1-based) where none was found.
        var picked = 0
        var nightsWithoutHotel: [Int] = []
        /// §36 item 2c: the times are the straight-line estimate.
        var estimated = false
        /// §48 (T-040t): the optional places left out, in the model's order, and each day's minutes (nil unfitted).
        var spare: [TripStop] = []
        var dayMinutes: [Int]?
        /// §49 item 4 `hotel` (T-040u): up to 3 hotels found per picked night (1-based), with the distance to that
        /// day's last place; the first is the one taken.
        var hotelChoices: [Int: [(place: Place, meters: Int)]] = [:]
    }

    /// §48 item 4 (T-040t): what the fit needs: the day budget, whether the places stay on their day groups, and the
    /// optional places not yet in the plan (the model's extras, or the plan's spare places on `reorganize`).
    private struct FitRequest {
        let pace: TripFitter.Pace
        var groups = false
        var extra: [(day: Int?, stop: TripStop)] = []
        var budgetSeconds: Int { pace.budgetMinutes * 60 }
    }

    private enum OrderResult {
        case success(Ordered)
        case failed(ToolErrorCode)
    }

    /// §28 item 2: what `next` adds when the new plan could not be ordered.
    private static func unordered(_ result: OrderResult) -> String {
        if case .failed = result { return "；还没按车程排好顺序" }
        return estimateNote(result)
    }

    /// §36 item 2c: said once when the times are estimated.
    private static func estimateNote(_ result: OrderResult) -> String {
        if case .success(let o) = result, o.estimated { return "；时间是估算的" }
        return ""
    }

    /// §27–§28 and §37 (T-040o): `source` ordered again by driving time. The frame comes from the stops' roles: the
    /// trip's `start` (day 1 first), each night's hotel (day k last, day k+1 first) and `end` (last day last).
    /// Marked sights keep their days; the sights still to go go on one path from the start (the named stop `named`,
    /// else the trip's start, else the car within `startRadiusMeters`) to the end, are cut into `dayCount` days, and
    /// each day is ordered again between its fixed ends. With `pickHotels` and no hotels, a 2–5 day trip gets one per
    /// night near the night's midpoint. The same place ids and roles, always (§27 item 4).
    /// §45 item 4 (T-040q): a rental pickup stays right after day 1's head, a return just before the last day's tail.
    /// §48 (T-040t): with `fit`, the cut into days is replaced by `TripFitter` (visit minutes, a day budget, optional
    /// places inserted where they fit), and a day the frame makes over budget drops its last-ranked optional places.
    private func ordered(_ source: [TripList], dayCount: Int, named: String?, pickHotels: Bool = false,
                         abroad: Bool? = nil, rentalAsked: Bool = false, fit: FitRequest? = nil) async -> OrderResult {
        let started = clock.now
        let abroad = abroad ?? plan.abroad
        let all = source.enumerated().flatMap { d, list in list.stops.map { (day: d, stop: $0) } }
        let sights = all.filter { $0.stop.role == .sight }
        var pending = sights.filter { $0.stop.mark == nil }.map(\.stop)
        let total = pending.count
        var label = "none"
        var startStop = all.first { $0.stop.role == .start }?.stop
        let endStop = all.last { $0.stop.role == .end }?.stop
        let pickupStop = all.first { $0.stop.role == .rentalPickup }?.stop
        let dropoffStop = all.last { $0.stop.role == .rentalReturn }?.stop
        let rental = Self.rentalLabel(source, asked: rentalAsked)
        func log(_ ok: Bool, requests: Int = 0, cached: Int = 0, days: Int = 0) {
            onLine("trip order ok=\(ok ? "yes" : "no") stops=\(total) days=\(days) start=\(label) requests=\(requests) cached=\(cached) ms=\(ms(since: started))")
        }
        // §48: the day of each sight as the plan has it (the driver's groups), and the extras not in the plan yet.
        let sourceDay = Dictionary(sights.map { ($0.stop.place.id, $0.day) }, uniquingKeysWith: { a, _ in a })
        let extras = (fit?.extra ?? []).filter { e in !all.contains { $0.stop.place.id == e.stop.place.id } }
        guard !pending.isEmpty || !extras.isEmpty else { return .success(Ordered(days: source)) }
        // Marks of the frame stops, kept where the same stop lands on the same day again.
        var frameMarks: [String: TripMark] = [:]
        for (d, stop) in all where stop.role != .sight {
            if let mark = stop.mark { frameMarks["\(d)|\(stop.place.id)|\(stop.role.rawValue)"] = mark }
        }
        // §28 item 1 and §37 item 5: the named stop, else the trip's start, else the car near a sight, else nothing.
        var startNode: TripTimes.Node?
        var first: TripStop?
        if let named, let i = pending.firstIndex(where: { $0.place.id == named }) {
            first = pending.remove(at: i)
            // A sight named as the start replaces the trip's start.
            startStop = nil
            label = "named"
        } else if let named, let stop = all.first(where: { $0.stop.place.id == named })?.stop {
            startNode = TripTimes.Node(key: stop.place.id, coordinate: stop.place.coordinate)
            // A hotel, end or visited sight named as the start: the plan is ordered from it; the old start is dropped.
            if stop.role != .start, startStop?.place.id != named { startStop = nil }
            label = "named"
        } else if let startStop {
            startNode = TripTimes.Node(key: startStop.place.id, coordinate: startStop.place.coordinate)
            label = "named"
        } else if let here = await origin(),
                  (pending + extras.map(\.stop)).contains(where: { SelfPosition.distanceMeters(here, $0.place.coordinate) <= Double(tuning.startRadiusMeters) }) {
            startNode = .here(here)
            label = await startLabel()
        } else {
            log(false)
            frameLine(start: "none", end: endStop != nil, hotels: "none", nights: 0, picked: 0, rental: rental)
            return .failed(.noStart)
        }
        // §36 item 2c: abroad the table is OSRM's, else the straight-line estimate; at home 高德's (§26 item 4).
        let tableTimes = abroad ? (abroadTimes ?? times) : times
        guard abroad || tableTimes != nil else {
            log(false)
            return .failed(.routeTimesUnavailable)
        }
        // Night k's hotel as the plan has it (positional), else the one hotel of every night.
        let sourceNights = max(source.count - 1, 0)
        var plannedHotels: [TripStop?] = (0..<sourceNights).map { k in
            source[k].stops.last.flatMap { $0.role == .hotel ? $0 : nil }
        }
        let anyHotel = plannedHotels.compactMap { $0 }
        // Nodes: the start (node 0) when there is one, then every other place once.
        var nodes: [TripTimes.Node] = []
        var nodeIndex: [String: Int] = [:]
        let offset = startNode == nil ? 0 : 1
        if let startNode { nodeIndex[startNode.key] = 0 }
        func addNode(_ stop: TripStop) {
            guard nodeIndex[stop.place.id] == nil else { return }
            nodeIndex[stop.place.id] = nodes.count + offset
            nodes.append(TripTimes.Node(key: stop.place.id, coordinate: stop.place.coordinate))
        }
        if let first { addNode(first) }
        pending.forEach(addNode)
        extras.map(\.stop).forEach(addNode)
        if let endStop { addNode(endStop) }
        if let pickupStop { addNode(pickupStop) }
        if let dropoffStop { addNode(dropoffStop) }
        anyHotel.forEach(addNode)
        // §42: `trip times vendor=<amap|osrm|estimate> pairs= ms=` after each table.
        func timeTable(_ start: TripTimes.Node?, _ list: [TripTimes.Node]) async -> TripTimes.Table? {
            let asked = clock.now
            work?.step(WorkProgress.tripTimes)
            var got = await tableTimes?.table(start: start, stops: list)
            if got == nil, abroad { got = TripTimes.estimate(start: start, stops: list) }
            let vendor = got?.estimated == true ? "estimate" : abroad && abroadTimes != nil ? "osrm" : "amap"
            onLine("trip times vendor=\(vendor) pairs=\(got?.pairs ?? 0) ms=\(ms(since: asked))")
            return got
        }
        guard var table = await timeTable(startNode, nodes) else {
            log(false)
            return .failed(.routeTimesUnavailable)
        }
        var requests = table.requests, cached = table.cached
        func idx(_ stop: TripStop) -> Int { nodeIndex[stop.place.id] ?? 0 }
        let origin = first.map(idx) ?? 0
        let endIdx = endStop.map(idx)
        let time: (Int, Int) -> Int = { table.time($0, $1) }
        let stopOf = Dictionary((pending + extras.map(\.stop) + (first.map { [$0] } ?? [])).map { (idx($0), $0) },
                                uniquingKeysWith: { a, _ in a })
        var cut: [[Int]]
        // §48 item 5: the rank of each optional place (the model's order); last-ranked are dropped first.
        var rank: [Int: Int] = [:]
        var spareNodes: [Int] = []
        var moves = 0
        let fitStarted = clock.now
        if let fit {
            let days = min(TripPlan.maxDays, max(1, dayCount))
            let visit: (Int) -> Int = { (stopOf[$0]?.visitMinutes ?? 0) * 60 }
            let required = pending.filter { !$0.optional }
            let optional = pending.filter(\.optional).map { (day: sourceDay[$0.place.id], stop: $0) } + extras
            // §49 item 3: by importance, then the model's order.
            for (i, o) in optional.enumerated() where rank[idx(o.stop)] == nil { rank[idx(o.stop)] = (3 - o.stop.importance) * 1000 + i }
            var requiredDays: [[Int]]
            if fit.groups {
                requiredDays = (0..<days).map { d in required.filter { min(sourceDay[$0.place.id] ?? 0, days - 1) == d }.map(idx) }
            } else {
                let path = TripOptimizer.path(required.map(idx), from: origin, to: endIdx, time: time)
                requiredDays = TripOptimizer.cut(path, from: origin, days: days, visit: visit, time: time)
                if path.isEmpty { requiredDays = [] }
            }
            while requiredDays.count < days { requiredDays.append([]) }
            var group: [Int: Int] = [:]
            if fit.groups {
                for o in optional { group[idx(o.stop)] = min(o.day ?? 0, days - 1) }
                // §49 item 3: exchanges keep the driver's day groups too.
                for (d, day) in requiredDays.enumerated() { for node in day { group[node] = d } }
            }
            let importance: (Int) -> Int = { stopOf[$0]?.importance ?? 3 }
            let fitted = TripFitter.fit(required: requiredDays, optional: optional.map { idx($0.stop) }, group: group,
                                        from: origin, to: endIdx, budgetSeconds: fit.budgetSeconds,
                                        maxPerDay: TripList.maxStops, visit: visit, time: time, importance: importance)
            moves = fitted.moves
            cut = fitted.days
            if let first { cut[0].insert(idx(first), at: 0) }
            spareNodes = fitted.spare
        } else {
            let rest = pending.map(idx)
            let path = (first.map { [idx($0)] } ?? []) + TripOptimizer.path(rest, from: origin, to: endIdx, time: time)
            cut = TripOptimizer.cut(path, from: origin, days: dayCount, time: time)
        }
        let markedDays = (sights.filter { $0.stop.mark != nil }.map(\.day).max() ?? -1) + 1
        let dayTotal = min(TripPlan.maxDays, max(cut.count, markedDays))
        let nights = max(dayTotal - 1, 0)
        // §37 item 1: one hotel for every night, or one per night.
        // Same nights as the plan: as they are (a hotel not found stays left out). Other nights: one hotel of every
        // night only when the plan had one hotel on every night.
        let oneBase = Set(anyHotel.map(\.place.id)).count == 1 && anyHotel.count == plannedHotels.count
        var nightHotel: [TripStop?] = (0..<nights).map { k in
            if nights != plannedHotels.count, oneBase { return anyHotel[0] }
            return k < plannedHotels.count ? plannedHotels[k] : nil
        }
        var picked = 0
        var withoutHotel: [Int] = []
        var choices: [Int: [(place: Place, meters: Int)]] = [:]
        if pickHotels, anyHotel.isEmpty, (2...5).contains(dayTotal) {
            for k in 0..<nights {
                guard k + 1 < cut.count, let last = cut[k].last.flatMap({ stopOf[$0] }),
                      let next = cut[k + 1].first.flatMap({ stopOf[$0] }) else { withoutHotel.append(k + 1); continue }
                let mid = GeoCoordinate(latitude: (last.place.coordinate.latitude + next.place.coordinate.latitude) / 2,
                                        longitude: (last.place.coordinate.longitude + next.place.coordinate.longitude) / 2,
                                        datum: last.place.coordinate.datum)
                let found = await hotelPlaces(near: mid, abroad: abroad)
                if let hotel = found.first {
                    nightHotel[k] = TripStop(index: 0, asked: "酒店", place: hotel, distanceMeters: nil, role: .hotel, picked: true)
                    picked += 1
                    // §49 item 4 `hotel`: the choices with their distance to that day's last place.
                    choices[k + 1] = found.prefix(TripChecks.hotelChoices).map {
                        ($0, Int(SelfPosition.distanceMeters(last.place.coordinate, $0.coordinate).rounded()))
                    }
                } else {
                    withoutHotel.append(k + 1)
                }
            }
            guard !Task.isCancelled else { return .failed(.optionsStale) }
            if picked > 0 {
                nightHotel.compactMap { $0 }.forEach(addNode)
                guard let again = await timeTable(startNode, nodes) else {
                    log(false, requests: requests, cached: cached)
                    return .failed(.routeTimesUnavailable)
                }
                table = again
                requests += again.requests
                cached += again.cached
            }
        }
        plannedHotels = nightHotel
        // Each day between its fixed ends (§37 item 3).
        var days: [TripList] = []
        var previous: Int? = startNode == nil ? nil : 0
        for d in 0..<dayTotal {
            func fixed(_ stop: TripStop?) -> TripStop? {
                guard var stop else { return nil }
                stop.mark = frameMarks["\(d)|\(stop.place.id)|\(stop.role.rawValue)"]
                stop.legSeconds = nil
                return stop
            }
            let head: TripStop? = d == 0 ? (first == nil ? fixed(startStop) : nil) : fixed(nightHotel[d - 1])
            let tail: TripStop? = d == dayTotal - 1 ? fixed(endStop) : fixed(nightHotel[d])
            // §45 item 4: the rental stops, fixed beside the day's ends.
            let rentalHead: TripStop? = d == 0 ? fixed(pickupStop) : nil
            let rentalTail: TripStop? = d == dayTotal - 1 ? fixed(dropoffStop) : nil
            let kept = sights.filter { $0.stop.mark != nil && min($0.day, dayTotal - 1) == d }.map(\.stop)
            var daySights = d < cut.count ? cut[d] : []
            var leading: [Int] = []
            if d == 0, let first, daySights.first == idx(first) {
                leading = [daySights.removeFirst()]
            }
            let from = leading.first ?? rentalHead.map(idx) ?? head.map(idx) ?? previous ?? origin
            let to = (rentalTail ?? tail).map(idx)
            var order = leading + TripOptimizer.path(daySights, from: from, to: to, time: { table.time($0, $1) })
            // §48 item 5: a day the frame (hotels, rental) made over budget drops its last-ranked optional places.
            if let fit {
                let frame = [head, rentalHead, rentalTail, tail].compactMap { $0 }
                func dayCost(_ order: [Int]) -> Int {
                    let seq = [rentalHead].compactMap { $0.map(idx) } + order + [rentalTail, tail].compactMap { $0.map(idx) }
                    var here = head.map(idx) ?? previous ?? origin
                    var total = 0
                    for node in seq {
                        let stop = stopOf[node] ?? frame.first { idx($0) == node }
                        total += table.time(here, node) + (stop?.visitMinutes ?? 0) * 60
                        here = node
                    }
                    return total
                }
                while dayCost(order) > fit.budgetSeconds,
                      let worst = daySights.filter({ rank[$0] != nil }).max(by: { rank[$0]! < rank[$1]! }) {
                    daySights.removeAll { $0 == worst }
                    spareNodes.append(worst)
                    order = leading + TripOptimizer.path(daySights, from: from, to: to, time: { table.time($0, $1) })
                }
            }
            var out: [TripStop] = []
            if let head {
                out.append(head)
                previous = idx(head)
            }
            if var pick = rentalHead {
                pick.legSeconds = previous.map { table.time($0, idx(pick)) }
                out.append(pick)
                previous = idx(pick)
            }
            out += kept
            for node in order {
                guard var s = stopOf[node] else { continue }
                // §29 item 4: minutes from the stop before; none into a named start (the car is not counted).
                s.legSeconds = previous.map { table.time($0, node) }
                if node == leading.first, d == 0 { s.legSeconds = nil }
                out.append(s)
                previous = node
            }
            if var back = rentalTail {
                back.legSeconds = previous.map { table.time($0, idx(back)) }
                out.append(back)
                previous = idx(back)
            }
            if var tail {
                tail.legSeconds = previous.map { table.time($0, idx(tail)) }
                out.append(tail)
                previous = idx(tail)
            }
            var list = TripList()
            list.arrange(out)
            days.append(list)
        }
        if let tamper { days = tamper(days) }
        // §48 item 6: the spare places in the model's order.
        let spare = spareNodes.sorted { (rank[$0] ?? 0) < (rank[$1] ?? 0) }.compactMap { node -> TripStop? in
            guard var s = stopOf[node] else { return nil }
            s.legSeconds = nil
            return s
        }
        let spareIDs = Set(spare.map(\.place.id))
        // §27 item 4 with §37 item 2: exactly the places and roles decided, the same count.
        var expected = (sights.map(\.stop) + extras.map(\.stop)).filter { !spareIDs.contains($0.place.id) }
            .map { "\($0.place.id)|sight" }
        if first == nil, let startStop { expected.append("\(startStop.place.id)|start") }
        if let endStop { expected.append("\(endStop.place.id)|end") }
        if let pickupStop { expected.append("\(pickupStop.place.id)|rental_pickup") }
        if let dropoffStop { expected.append("\(dropoffStop.place.id)|rental_return") }
        for hotel in plannedHotels.compactMap({ $0 }) { expected += Array(repeating: "\(hotel.place.id)|hotel", count: 2) }
        let after = days.flatMap { $0.stops.map { "\($0.place.id)|\($0.role.rawValue)" } }
        guard expected.sorted() == after.sorted() else {
            log(false, requests: requests, cached: cached)
            return .failed(.planChanged)
        }
        log(true, requests: requests, cached: cached, days: days.count)
        let named = plannedHotels.contains { $0 != nil && $0?.picked == false }
        frameLine(start: first != nil || startStop != nil ? "named" : label, end: endStop != nil,
                  hotels: named ? "named" : picked > 0 || plannedHotels.contains { $0?.picked == true } ? "picked" : "none",
                  nights: nights, picked: picked, rental: rental)
        var minutes: [Int]?
        if let fit {
            let m = days.map(Self.dayMinutes)
            minutes = m
            let budget = fit.pace.budgetMinutes
            let optionalCount = pending.filter(\.optional).count + extras.count
            // §48 item 12: numbers and enums only (I-8).
            onLine("trip fit days=\(days.count) pace=\(fit.pace.rawValue) budget=\(budget) required=\(total - pending.filter(\.optional).count) optional=\(optionalCount) kept=\(optionalCount - spare.count) dropped=\(spare.count) over=\(m.filter { $0 > budget }.count) under=\(m.filter { $0 * 2 < budget }.count) max_day=\(m.max() ?? 0) min_day=\(m.min() ?? 0) moves=\(moves) ms=\(ms(since: fitStarted))")
        }
        return .success(Ordered(days: days, picked: picked, nightsWithoutHotel: withoutHotel, estimated: table.estimated,
                                spare: spare, dayMinutes: minutes, hotelChoices: choices))
    }

    /// §48 item 3 (T-040t): a day's minutes: the known drives into and between its stops plus their visit minutes.
    static func dayMinutes(_ day: TripList) -> Int {
        let seconds = day.stops.reduce(0) { $0 + ($1.legSeconds ?? 0) + $1.visitMinutes * 60 }
        return Int((Double(seconds) / 60).rounded())
    }

    static func hours(_ minutes: Int) -> Int { Int((Double(minutes) / 60).rounded()) }

    /// §48 item 7: what she says once per fitted plan: the load, the places left out, a day too full, a day half empty.
    static func fitNotes(_ dayMinutes: [Int], budget: Int, spare: [String]) -> [String] {
        guard let lo = dayMinutes.min(), let hi = dayMinutes.max() else { return [] }
        var notes: [String] = []
        let (a, b) = (hours(lo), hours(hi))
        notes.append(a == b ? "每天大约\(a)小时" : "每天大约\(a)到\(b)小时")
        if !spare.isEmpty { notes.append("时间不够，没排进：\(spare.joined(separator: "、"))") }
        for (d, m) in dayMinutes.enumerated() where m > budget { notes.append("第\(d + 1)天大约\(hours(m))小时，比较紧") }
        if spare.isEmpty {
            for (d, m) in dayMinutes.enumerated() where m * 2 < budget {
                notes.append("第\(d + 1)天还空大约\(max(1, hours(budget - m)))小时，可以再加几个地方")
            }
        }
        return notes
    }

    /// §48 item 9: after an edit, the current day over its budget is said; nothing is dropped.
    private func overNote() -> String {
        guard let budget = plan.budgetMinutes else { return "" }
        let m = Self.dayMinutes(list)
        return m > budget ? "第\(plan.currentDay)天大约\(Self.hours(m))小时，比较紧。" : ""
    }

    /// §42: `trip frame start= end= hotels= nights= picked=`, and §45 item 11's `rental=` when the plan has or asked
    /// for a rental (a plan without one logs as before, row 102).
    private func frameLine(start: String, end: Bool, hotels: String, nights: Int, picked: Int, rental: String? = nil) {
        let r = rental.map { " rental=\($0)" } ?? ""
        onLine("trip frame start=\(start) end=\(end ? "named" : "none") hotels=\(hotels) nights=\(nights) picked=\(picked)\(r)")
    }

    /// §45 item 11: `both`, `pickup`, `return`, `missing` (asked, none found); nil when not asked and none in the plan.
    static func rentalLabel(_ days: [TripList], asked: Bool) -> String? {
        let roles = Set(days.flatMap { $0.stops.map(\.role) })
        switch (roles.contains(.rentalPickup), roles.contains(.rentalReturn)) {
        case (true, true): return "both"
        case (true, false): return "pickup"
        case (false, true): return "return"
        case (false, false): return asked ? "missing" : nil
        }
    }

    /// §45 item 3: a rental brand: the name before 「レンタカー」/「租车」/"Rent", else the whole name.
    static func rentalBrand(_ name: String) -> String {
        var brand = name
        for marker in ["レンタカー", "租车", "rent"] {
            if let r = brand.range(of: marker, options: .caseInsensitive) { brand = String(brand[..<r.lowerBound]) }
        }
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    /// §45 item 2: 「租车」 places around `center`, nearest first, within 3 km, else 10 km (Photon's amenity:car_rental
    /// tag abroad, 高德's category search at home).
    private func rentalPlaces(near center: GeoCoordinate, abroad: Bool) async -> [Place] {
        let vendor = abroad ? (abroadSearch ?? search) : search
        for radius in tuning.rentalRadii {
            guard !Task.isCancelled else { return [] }
            let found = (try? await vendor.aroundOnly("租车", center: center, radiusMeters: radius, sort: .distance)) ?? []
            let usable = abroad ? found.filter { $0.countryCode == nil || !TripRegion.isChina($0.countryCode) } : found
            if !usable.isEmpty { return usable }
        }
        return []
    }

    /// §45 items 2, 3 and 5: the pickup near the start (named, else the phone), the return near the end (else the last
    /// day's last sight as asked), preferring the pickup's brand; one search when both are around the same point.
    private func pickRentals(start: TripStop?, end: TripStop?, here: GeoCoordinate?, lastSight: TripStop?,
                             abroad: Bool) async -> (pickup: TripStop?, dropoff: TripStop?, notes: [String]) {
        var notes: [String] = []
        let startCenter = start?.place.coordinate ?? here
        let startName = start?.place.name ?? "出发点"
        var startFound: [Place] = []
        if let startCenter { startFound = await rentalPlaces(near: startCenter, abroad: abroad) }
        let pickup = startFound.first.map {
            TripStop(index: 0, asked: "租车", place: $0, distanceMeters: nil, role: .rentalPickup, picked: true)
        }
        if pickup == nil { notes.append("\(startName)附近没找到租车点") }
        let endPoint = end ?? lastSight
        let endName = endPoint?.place.name ?? "终点"
        var endFound: [Place] = []
        if let endCenter = endPoint?.place.coordinate {
            endFound = endCenter == startCenter ? startFound : await rentalPlaces(near: endCenter, abroad: abroad)
        }
        let brand = pickup.map { Self.rentalBrand($0.place.name) }
        let chosen = endFound.first { brand != nil && Self.rentalBrand($0.name) == brand } ?? endFound.first
        let dropoff = chosen.map {
            TripStop(index: 0, asked: "租车", place: $0, distanceMeters: nil, role: .rentalReturn, picked: true)
        }
        // Said once: the same place as the start is not named twice.
        if dropoff == nil, !(pickup == nil && endName == startName) { notes.append("\(endName)附近没找到租车点") }
        return (pickup, dropoff, notes)
    }

    /// §37 item 4: the first 「酒店」 within 3 km of `center`, else 10 km (高德 at home, Apple abroad); nil when none.
    /// §49 item 4 (T-040u): every hotel of that first radius, nearest first (the first is the one taken).
    private func hotelPlaces(near center: GeoCoordinate, abroad: Bool) async -> [Place] {
        let vendor = abroad ? (abroadSearch ?? search) : search
        for radius in tuning.hotelRadii {
            guard !Task.isCancelled else { return [] }
            let found = (try? await vendor.aroundOnly("酒店", center: center, radiusMeters: radius, sort: .distance)) ?? []
            let usable = abroad ? found.filter { $0.countryCode == nil || !TripRegion.isChina($0.countryCode) } : found
            if !usable.isEmpty { return usable }
        }
        return []
    }

    /// §28 item 3 and §37 item 5: the whole plan ordered again, from a named stop of the plan, a start searched as a
    /// place of the trip (added with `role: start`), the plan's start, or the car.
    private func reorganize(start: String?, days: Int?) async -> ToolResult {
        var named: String?
        var source = plan.days
        let generation = plan.revision
        if let start {
            // Matched as `remove` by name, over the whole plan.
            let found = plan.allStops.filter { TripList.matches($0.stop, start) }
            guard found.count <= 1 else { return failure(.ambiguous) }
            if let only = found.first {
                named = only.stop.place.id
            } else {
                // §37 item 5: not in the plan: searched once, as a place of the trip.
                let asked = TranscriptText.normalize(start)
                let lookup = await resolve([asked], city: nil, abroad: plan.abroad, near: regionHint()).first ?? .missing("failed")
                guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
                guard case .found(let place) = lookup else {
                    if case .missing(let reason) = lookup { onLine("trip lookup index=0 ok=no reason=\(reason)") }
                    return failure(.notFound)
                }
                // The new start replaces the old one on day 1.
                source = source.map { day in
                    var list = TripList()
                    list.arrange(day.stops.filter { $0.role != .start })
                    return list
                }
                if var day1 = source.first {
                    day1.arrange([TripStop(index: 0, asked: asked, place: place, distanceMeters: nil, role: .start)] + day1.stops)
                    source[0] = day1
                }
            }
        }
        // §48 item 9 (T-040t): fitted again over the plan's places plus the spare ones.
        let pace = TripFitter.Pace(budgetMinutes: plan.budgetMinutes)
        let fit = FitRequest(pace: pace, extra: plan.spare.map { (day: nil, stop: $0) })
        let result = await ordered(source, dayCount: days ?? plan.dayCount, named: named, pickHotels: true, fit: fit)
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        switch result {
        case .failed(let code): return failure(code)
        case .success(let o):
            plan.arrange(days: o.days)
            var fitNote = ""
            if let m = o.dayMinutes {
                plan.spare = o.spare
                plan.budgetMinutes = pace.budgetMinutes
                fitNote = Self.fitNotes(m, budget: pace.budgetMinutes, spare: o.spare.map(\.place.name)).joined(separator: "；") + "。"
            }
            changed()
            // A visited or skipped stop keeps its day, so fewer days than that can't be kept: say so.
            let kept = days.map { $0 < plan.dayCount ? "已去过或跳过的站留在原来那天，所以还是\(plan.dayCount)天。" : "" } ?? ""
            let hotels = o.nightsWithoutHotel.isEmpty ? "" : "第\(o.nightsWithoutHotel.map(String.init).joined(separator: "、"))晚附近没找到酒店。"
            let estimated = o.estimated ? "时间是估算的。" : ""
            return listResult(changed: "reorganized",
                              next: "\(kept)\(hotels)\(estimated)\(fitNote)用一两句话按 plan 说每天去哪（\(plan.dayCount)天），不要念距离。",
                              extra: o.estimated ? ["times": "estimated"] : [:])
        }
    }

    /// §28 item 4: stop `index` of the current day to the end of day `toDay`, then that day ordered from its first stop.
    private func moveToDay(index: Int?, toDay: Int) async -> ToolResult {
        guard let index, (1...list.count).contains(index) else { return outOfRange() }
        guard (1...plan.dayCount).contains(toDay) else { return dayOutOfRange() }
        let from = plan.currentDay
        var days = plan.days
        let moved = days[from - 1].stops[index - 1]
        guard toDay != from else {
            return listResult(changed: "none", next: "只说一句：\(moved.place.name)已经在第\(toDay)天了。")
        }
        days[from - 1].remove(at: index)
        days[toDay - 1].insert(moved)
        let generation = plan.revision
        let target = days[toDay - 1]
        // §37 item 3: a day's fixed ends (start or hotel first, hotel or end last) stay; it is ordered between them.
        var framed = target.stops
        let head = framed.first.flatMap { $0.role != .sight ? $0 : nil }
        let tail = framed.count > 1 ? framed.last.flatMap { $0.role != .sight ? $0 : nil } : nil
        if var h = head { h.role = .start; framed[0] = h }
        if var t = tail { t.role = .end; framed[framed.count - 1] = t }
        var asOne = TripList()
        asOne.arrange(framed)
        let result = await ordered([asOne], dayCount: 1, named: head == nil ? target.stops.first?.place.id : nil)
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        switch result {
        case .failed(let code): return failure(code)
        case .success(let o):
            var back = o.days.first?.stops ?? target.stops
            if let head, let i = back.firstIndex(where: { $0.role == .start }) { back[i].role = head.role; back[i].picked = head.picked }
            if let tail, let i = back.lastIndex(where: { $0.role == .end }) { back[i].role = tail.role; back[i].picked = tail.picked }
            var list = TripList()
            list.arrange(back)
            days[toDay - 1] = list
            let before = plan.allStops.map(\.stop.place.id).sorted()
            guard before == days.flatMap({ $0.stops.map(\.place.id) }).sorted() else { return failure(.planChanged) }
            plan.arrange(days: days)
            changed()
            return listResult(changed: "moved",
                              next: "只说一句：\(moved.place.name)放到了第\(toDay)天，第\(toDay)天按车程排好了\(Self.estimateNote(result))。",
                              extra: o.estimated ? ["times": "estimated"] : [:])
        }
    }

    // MARK: trip_next (§29)

    private func next(_ args: JSONValue) async -> ToolResult {
        if let day = Self.int(args["day"]) {
            guard plan.select(day) else { return dayOutOfRange() }
            onChange(list)
            persist()
        }
        guard !list.isEmpty else { return failure(.noTripList) }
        let target: TripStop
        if let asked = args["stop"]?.stringValue {
            if let n = Int(asked) {
                guard (1...list.count).contains(n) else { return outOfRange() }
                target = list.stops[n - 1]
            } else {
                let found = list.matches(asked)
                guard found.count <= 1 else { return failure(.ambiguous) }
                guard let only = found.first else { return failure(.notFound) }
                target = list.stops[only - 1]
            }
        } else if let open = list.stops.first(where: { $0.mark == nil }) {
            target = open
        } else {
            onLine("trip next index=0 day=\(plan.currentDay) ok=no code=DAY_DONE")
            let more = plan.currentDay < plan.dayCount
            return .failure(.dayDone, advice: more ? "第\(plan.currentDay)天的地点都去过或跳过了。请问司机要不要开始第\(plan.currentDay + 1)天。"
                            : "行程里的地点都去过或跳过了。请用一句话说今天的行程走完了。")
        }
        // §47 item 1 (T-040s): an `abroad` trip's stop is routed by OSRM inside the app.
        let result = await navigation.tripNext(target.place, abroad: plan.abroad)
        onLine("trip next index=\(target.index) day=\(plan.currentDay) ok=\(result.ok ? "yes" : "no") code=\(result.code?.rawValue ?? "none")")
        if !result.ok, let handed = await handoff(target, after: result) { return handed }
        guard result.ok else { return result }
        let after = list.stops.first { $0.index > target.index && $0.mark == nil }
        var data = result.data
        data["status"] = "trip_next"
        data["index"] = .int(Int64(target.index))
        data["name"] = .string(target.place.name)
        data["day"] = .int(Int64(plan.currentDay))
        data["after"] = after.map { .string($0.place.name) } ?? .null
        let minutes = data["duration_min"]?.intValue.map { "，大约\($0)分钟" } ?? ""
        data["next"] = .string("只说一句：去第\(target.index)站\(target.place.name)\(minutes)。不要念其他路线。")
        return .success(data)
    }

    /// The other day's copy of night k's hotel: day d's last stop is day d+1's first, day d's first is day d−1's last.
    private func otherCopy(day: Int, index: Int) -> (day: Int, index: Int)? {
        let stops = plan.days[day - 1].stops
        guard stops.indices.contains(index - 1), stops[index - 1].role == .hotel else { return nil }
        let id = stops[index - 1].place.id
        if index == stops.count, day < plan.dayCount, let morning = plan.days[day].stops.first,
           morning.role == .hotel, morning.place.id == id { return (day + 1, 1) }
        if index == 1, day > 1, let evening = plan.days[day - 2].stops.last,
           evening.role == .hotel, evening.place.id == id { return (day - 1, plan.days[day - 2].count) }
        return nil
    }

    private func markOtherCopy(day: Int, index: Int, _ mark: TripMark) {
        guard let other = otherCopy(day: day, index: index), plan.days[other.day - 1].stops[other.index - 1].mark == nil else { return }
        plan.mark(day: other.day, index: other.index, mark)
    }

    /// §37 item 4: `replace` of a night's hotel changes both copies of that night.
    private func replaceOtherCopy(day: Int, index: Int, of old: TripStop, with new: TripStop) {
        var days = plan.days
        let stops = days[day - 1].stops
        // Find the copy as it was before the replace: same old place id, at the far end of the next or previous day.
        if index == stops.count, day < days.count, let morning = days[day].stops.first, morning.role == .hotel,
           morning.place.id == old.place.id {
            days[day].set(new, at: 1)
        } else if index == 1, day > 1, let evening = days[day - 2].stops.last, evening.role == .hotel,
                  evening.place.id == old.place.id {
            days[day - 2].set(new, at: days[day - 2].count)
        } else { return }
        let current = plan.currentDay
        plan.arrange(days: days)
        _ = plan.select(current)
    }

    /// §36 item 2: Apple's region for one more name of a trip abroad: the plan's first place.
    private func regionHint() -> GeoCoordinate? {
        plan.abroad ? plan.allStops.first?.stop.place.coordinate : nil
    }

    /// §38 item 2 (T-040o), §47 item 6: abroad, a failed route (OSRM) opens Apple Maps to the stop instead. nil when
    /// this does not apply (at home, a refusal that is not a route failure, or no hand-off).
    private func handoff(_ target: TripStop, after result: ToolResult) async -> ToolResult? {
        guard let onHandoff, plan.abroad || !TripRegion.isChina(target.place.countryCode),
              result.code != .optionsNotReady, result.code != .optionsStale, !Task.isCancelled else { return nil }
        guard await onHandoff(target.place) else { return nil }
        onLine("trip handoff vendor=apple_maps reason=route_failed")
        return .success(["status": "apple_maps", "index": .int(Int64(target.index)), "name": .string(target.place.name),
                         "day": .int(Int64(plan.currentDay)),
                         "next": .string("只说一句：已在苹果地图打开导航，去第\(target.index)站\(target.place.name)。到了请说「已经到了」。")])
    }

    /// §29 items 2–3: guidance arrived at a plan stop: it is visited, and a connected session gets the note.
    func arrived(_ placeID: String) {
        // The current day first: a trip that starts and ends at the same airport has it on day 1 and the last day.
        let open = plan.allStops.filter { $0.stop.place.id == placeID && $0.stop.mark == nil }
        guard let (day, stop) = open.first(where: { $0.day == plan.currentDay }) ?? open.first else { return }
        plan.mark(day: day, index: stop.index, .visited)
        // §37 item 7: a night's hotel ends the day; the next morning starts there, so it is reached too.
        markOtherCopy(day: day, index: stop.index, .visited)
        changed()
        onLine("trip visit index=\(stop.index) day=\(day) by=arrival")
        let rest = plan.days[day - 1].stops.first { $0.index > stop.index && $0.mark == nil }
        let note: String
        if let rest {
            let minutes = rest.legSeconds.map { "，约\(max(1, ($0 + 59) / 60))分钟" } ?? ""
            note = "[系统] 已到达第\(stop.index)站\(stop.place.name)。下一站是\(rest.place.name)\(minutes)。问司机要不要现在去下一站。"
        } else {
            note = stop.role == .hotel
                ? "[系统] 已到达酒店\(stop.place.name)，今天的行程结束了。用一句话告诉司机，明天说「开始第\(min(day + 1, plan.dayCount))天」。"
                : "[系统] 已到达第\(stop.index)站\(stop.place.name)。这一天的地点都去完了。问司机要不要开始下一天。"
        }
        onNote(note)
    }

    // MARK: Resolving (§4)

    enum Lookup: Sendable {
        case found(Place)
        /// 高德's top results for a name, before the picker (§4 item 6); never returned by `resolve`.
        case candidates([Place])
        case missing(String)
        case keyMissing
    }

    /// §36 items 2–4 (T-040o): a trip's names on 高德, or on Apple when `abroad`; with `abroad=false` and fewer than
    /// half found on 高德, the missing names are tried on Apple, and when most of what Apple finds is outside China the
    /// trip becomes `abroad` and every name is searched again there. `trip search …` after the lookups.
    private func resolveTrip(_ names: [String], city: String?, abroad asked: Bool) async -> (lookups: [Lookup], abroad: Bool) {
        let started = clock.now
        work?.step(WorkProgress.tripCheck)
        var abroad = asked && abroadSearch != nil
        var switched = false
        var lookups: [Lookup]
        var dropped = 0
        func found(_ l: [Lookup]) -> Int { l.filter { if case .found = $0 { true } else { false } }.count }
        // §36 item 2a: every abroad lookup is searched around the city's centre.
        var center: GeoCoordinate?
        area = nil
        pickerNames = 0
        // §50 item 3 (T-040v): the city's centre and country; lookups stay inside its box.
        if abroadSearch != nil, let abroadArea, let city, !city.isEmpty, asked {
            area = await abroadArea(city)
            center = area?.center
        }
        if center == nil, abroadSearch != nil, let abroadCenter, let city, !city.isEmpty, asked {
            center = await abroadCenter(city)
        }
        if abroad {
            (lookups, dropped) = await resolveCounting(names, city: nil, abroad: true, near: center)
        } else {
            lookups = await resolve(names, city: city)
            let keyMissing = lookups.contains { if case .keyMissing = $0 { true } else { false } }
            if abroadSearch != nil, !keyMissing, !names.isEmpty, found(lookups) * 2 < names.count, !Task.isCancelled {
                let missed = names.indices.filter { if case .found = lookups[$0] { false } else { true } }
                let (probe, _) = await resolveCounting(missed.map { names[$0] }, city: nil, abroad: true, guardCountry: false,
                                                       near: center)
                let places = probe.compactMap { if case .found(let p) = $0 { p } else { nil } }
                let outside = places.filter { !TripRegion.isChina($0.countryCode) }.count
                if !places.isEmpty, outside * 2 > places.count, !Task.isCancelled {
                    switched = true
                    abroad = true
                    (lookups, dropped) = await resolveCounting(names, city: nil, abroad: true, near: center)
                }
            }
        }
        // §50 item 7: with an area, the dropped results are `area_dropped`, and `picker=` names went to the picker.
        let areaPart = area == nil ? "" : " area_dropped=\(dropped) picker=\(pickerNames)"
        if area != nil, dropped > 0 { work?.fail(WorkProgress.outOfArea(dropped)) }
        onLine("trip search vendor=\(abroad ? "apple" : "amap") abroad=\(abroad ? "yes" : "no") switched=\(switched ? "yes" : "no") names=\(names.count) found=\(found(lookups)) country_dropped=\(area == nil ? dropped : 0) ms=\(ms(since: started)) center=\(center == nil ? "no" : "yes")\(areaPart)")
        return (lookups, abroad)
    }

    private func resolve(_ names: [String], city: String?, abroad: Bool = false, near: GeoCoordinate? = nil) async -> [Lookup] {
        await resolveCounting(names, city: city, abroad: abroad, near: near).0
    }

    /// Each name through `PlaceSearch.text` (Apple's around the first found name when `abroad`, §36 item 2), at
    /// most `parallelLookups` at once, all within `resolveLimit`; a lookup still running then is `timeout`. Results
    /// are in `names` order; the count is the results dropped by the wrong-country guard (§36 item 3).
    private func resolveCounting(_ names: [String], city: String?, abroad: Bool, guardCountry: Bool = true,
                                 near hint: GeoCoordinate? = nil) async -> ([Lookup], Int) {
        let vendor: any PlaceSearch = abroad ? (abroadSearch ?? search) : search
        let keys = names.map { "\(abroad ? "apple|" : "")\(city ?? "")|\($0)" }
        let cached = keys.map { foundCache[$0] }
        let missing = names.indices.filter { cached[$0] == nil }
        var fetched: [(Lookup, Int)] = []
        if !missing.isEmpty {
            if abroad {
                // The region of the first found name (a cached one counts), else no region.
                var near = hint ?? cached.compactMap { $0 }.first?.coordinate
                var done = 0
                while near == nil, done < missing.count {
                    let one = await fetch([names[missing[done]]], city: nil, search: vendor, guardCountry: guardCountry, near: nil)
                    fetched += one
                    done += 1
                    if case .candidates(let places) = one[0].0 { near = places.first?.coordinate }
                }
                if done < missing.count {
                    fetched += await fetch(missing[done...].map { names[$0] }, city: nil, search: vendor,
                                           guardCountry: guardCountry, near: near)
                }
            } else {
                fetched = await fetch(missing.map { names[$0] }, city: city, search: vendor, guardCountry: false, near: nil)
            }
        }
        var results = cached.map { $0.map(Lookup.found) ?? .missing("timeout") }
        var dropped = 0
        for (slot, index) in missing.enumerated() where slot < fetched.count {
            results[index] = fetched[slot].0
            dropped += fetched[slot].1
        }
        let (chosen, sure) = await choose(names, results, city: city)
        // §4 item 6 cache: only a place that is the only result or the picker's choice; a fallback is asked again.
        for index in missing where sure.contains(index) {
            if guardCountry || !abroad, case .found(let place) = chosen[index] { remember(keys[index], place) }
        }
        return (chosen, dropped)
    }

    /// §4 item 6: one result is taken; names with two or more go to the picker in one call. No picker, an error, an
    /// unreadable answer or no answer within `pickLimit`: 高德's first result. "None" is not found (`none`).
    private func choose(_ names: [String], _ lookups: [Lookup], city: String?) async -> ([Lookup], Set<Int>) {
        var out = lookups
        var sure = Set(lookups.indices)
        var open: [(index: Int, places: [Place])] = []
        for (i, lookup) in lookups.enumerated() {
            guard case .candidates(let places) = lookup else { continue }
            out[i] = .found(places[0])
            if places.count > 1 {
                open.append((i, places))
                sure.remove(i)
            }
        }
        guard !open.isEmpty, !Task.isCancelled else { return (out, sure) }
        let started = clock.now
        guard let picker else {
            onLine("trip pick names=\(open.count) none=0 ok=no reason=nokey ms=0")
            return (out, sure)
        }
        pickerNames += open.count
        let choices = open.map { PlaceChoice(asked: names[$0.index], city: city, candidates: $0.places) }
        let (stream, feed) = AsyncStream.makeStream(of: PickAnswer.self)
        let work = Task {
            do { feed.yield(.picks(try await picker.pick(choices))) } catch is PlacePickerNotConfigured {
                feed.yield(.nokey)
            } catch { feed.yield(.failed) }
        }
        let clock = clock, limit = tuning.pickLimit
        let timer = Task {
            try? await clock.sleep(until: started + limit)
            if !Task.isCancelled { feed.yield(.timeout) }
        }
        var answer = PickAnswer.cancelled
        for await a in stream {
            answer = a
            break
        }
        work.cancel()
        timer.cancel()
        feed.finish()
        let elapsed = ms(since: started)
        guard case .picks(let picks) = answer, picks.count == open.count else {
            let reason = switch answer {
            case .timeout: "timeout"; case .nokey: "nokey"; case .cancelled: "cancelled"; default: "failed"
            }
            onLine("trip pick names=\(open.count) none=0 ok=no reason=\(reason) ms=\(elapsed)")
            return (out, sure)
        }
        var none = 0
        for (slot, pick) in zip(open, picks) {
            if let pick {
                if slot.places.indices.contains(pick) {
                    out[slot.index] = .found(slot.places[pick])
                    sure.insert(slot.index)
                }
            } else {
                out[slot.index] = .missing("none")
                none += 1
            }
        }
        onLine("trip pick names=\(open.count) none=\(none) ok=yes ms=\(elapsed)")
        return (out, sure)
    }

    private enum PickAnswer: Sendable {
        case picks([Int?])
        case failed
        case nokey
        case timeout
        case cancelled
    }

    private func remember(_ key: String, _ place: Place) {
        if foundCache.updateValue(place, forKey: key) == nil { cacheOrder.append(key) }
        while cacheOrder.count > Self.cacheLimit { foundCache[cacheOrder.removeFirst()] = nil }
    }

    private func fetch(_ names: [String], city: String?, search: any PlaceSearch, guardCountry: Bool,
                       near: GeoCoordinate?) async -> [(Lookup, Int)] {
        let limit = tuning.parallelLookups, clock = clock, retry = tuning.retryDelay, kept = tuning.candidates
        let region = near.map { ($0, tuning.abroadRegionMeters) }
        // §50 item 3: only trip lookups abroad (the country guard on) stay inside the area.
        let inside: AreaCheck? = guardCountry ? area.map { AreaCheck(area: $0, km: tuning.areaKm, limit: tuning.areaLimit) } : nil
        let deadline = clock.now + tuning.resolveLimit
        let (stream, feed) = AsyncStream.makeStream(of: (Int, Lookup, Int)?.self)
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < names.count else { return }
                    let i = next
                    next += 1
                    _ = group.addTaskUnlessCancelled {
                        let (lookup, dropped) = await Self.lookup(names[i], city: city, search: search, retryDelay: retry, kept: kept,
                                                                  guardCountry: guardCountry, region: region, area: inside)
                        feed.yield((i, lookup, dropped))
                    }
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
        var results = [(Lookup, Int)?](repeating: nil, count: names.count)
        for await item in stream {
            guard let (i, lookup, dropped) = item else { break }
            results[i] = (lookup, dropped)
        }
        work.cancel()
        timer.cancel()
        feed.finish()
        return results.map { $0 ?? (.missing("timeout"), 0) }
    }

    /// §50 item 3 (T-040v): the trip area a lookup abroad is kept inside.
    struct AreaCheck: Sendable {
        let area: TripArea
        let km: Double
        let limit: Int
    }

    private static func lookup(_ name: String, city: String?, search: any PlaceSearch, retryDelay: NovaDuration,
                               kept: Int, guardCountry: Bool = false, region: (GeoCoordinate, Int)? = nil,
                               area: AreaCheck? = nil) async -> (Lookup, Int) {
        // §4 item 7: up to 2 retries, waiting retryDelay then twice that (高德 rejects requests over the per-second
        // limit and answers those within it).
        var result = await lookupOnce(name, city: city, search: search, kept: kept, guardCountry: guardCountry, region: region, area: area)
        for attempt in 0..<2 {
            guard case .missing(let reason) = result.0, reason != "nomatch", reason != "country", reason != "area", !Task.isCancelled else { return result }
            try? await Task.sleep(for: .milliseconds(retryDelay.milliseconds << attempt))
            if Task.isCancelled { return result }
            result = await lookupOnce(name, city: city, search: search, kept: kept, guardCountry: guardCountry, region: region, area: area)
        }
        return result
    }

    private static func lookupOnce(_ name: String, city: String?, search: any PlaceSearch, kept: Int, guardCountry: Bool,
                                   region: (GeoCoordinate, Int)?, area: AreaCheck? = nil) async -> (Lookup, Int) {
        do {
            var places: [Place]
            if let area {
                // §50 item 3: Photon's `bbox` restricts the search; the country and 50 km checks cover the rest.
                if let boxed = search as? any AreaPlaceSearch {
                    places = try await boxed.inArea(name, box: GeoBox.around(area.area.center), limit: area.limit)
                } else {
                    places = try await search.around(name, center: area.area.center, radiusMeters: Int(area.km * 1000), sort: .weight)
                }
                guard !places.isEmpty else { return (.missing("nomatch"), 0) }
                let (inside, dropped) = TripGround.inArea(places, area: area.area, km: area.km)
                guard !inside.isEmpty else { return (.missing("area"), dropped) }
                return (.candidates(Array(inside.prefix(max(kept, 1)))), dropped)
            }
            if let (center, radius) = region {
                places = try await search.around(name, center: center, radiusMeters: radius, sort: .weight)
            } else {
                places = try await search.text(name, city: city, cityLimit: city != nil)
            }
            guard !places.isEmpty else { return (.missing("nomatch"), 0) }
            var dropped = 0
            if guardCountry {
                // §36 item 3: a result in China (CN, HK, MO, TW) is dropped in a trip abroad.
                let kept = places.filter { $0.countryCode == nil || !TripRegion.isChina($0.countryCode) }
                dropped = places.count - kept.count
                places = kept
                guard !places.isEmpty else { return (.missing("country"), dropped) }
            }
            return (.candidates(Array(places.prefix(max(kept, 1)))), dropped)
        } catch let error as AmapWebError where error == .keyMissing || error == .keyRejected {
            return (.keyMissing, 0)
        } catch AmapWebError.quota {
            return (.missing("busy"), 0)
        } catch AmapWebError.timeout {
            return (.missing("timeout"), 0)
        } catch {
            return (.missing("failed"), 0)
        }
    }


    // MARK: Results

    private func listResult(changed: String?, notFound: [String] = [], duplicates: [String] = [],
                            next: String,
                            extra: [String: JSONValue] = [:]) -> ToolResult {
        var data: [String: JSONValue] = [
            "status": "trip_list",
            "count": .int(Int64(list.count)),
            "stops": .array(list.stops.map { stop in
                var o: [String: JSONValue] = ["index": .int(Int64(stop.index)), "name": .string(stop.place.name)]
                o["district"] = stop.place.district.map(JSONValue.string) ?? .null
                // §37 item 2: the frame's stops say what they are; a picked hotel says so.
                if stop.role != .sight { o["role"] = .string(stop.role.rawValue) }
                if stop.picked { o["picked"] = .bool(true) }
                // §48 item 8 (T-040t): the visit minutes counted.
                o["minutes"] = .int(Int64(stop.visitMinutes))
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
        data["plan"] = planValue()
        // §48 item 8: the budget, each day's minutes and the spare places of a fitted plan.
        if let budget = plan.budgetMinutes {
            data["budget_minutes"] = .int(Int64(budget))
            data["day_minutes"] = .array(plan.days.map { .int(Int64(Self.dayMinutes($0))) })
            data["spare"] = .array(plan.spare.map { .string($0.place.name) })
        }
        data.merge(extra) { _, new in new }
        return .success(data)
    }

    /// §28 item 6: each day's stop names in order, with the visited / skipped marks.
    private func planValue() -> JSONValue {
        .array(plan.days.map { day in
            .array(day.stops.map { s in
                .string(s.place.name + Self.roleNote(s.role) + (s.mark == .visited ? "（已去过）" : s.mark == .skipped ? "（跳过）" : ""))
            })
        })
    }

    static func roleNote(_ role: TripRole) -> String {
        switch role {
        case .start: "（出发）"
        case .hotel: "（酒店）"
        case .end: "（结束）"
        case .rentalPickup: "（取车）"
        case .rentalReturn: "（还车）"
        case .sight: ""
        }
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
        applyKnownPhotos()
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
                         "days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)), "plan": planValue(),
                         "next": .string("只说一句：打开了「\(name)」，\(note)有\(plan.dayCount)天\(plan.stopCount)个地点。要导航就说去下一站。")])
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
            case .next:
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_next", arguments: [:]))
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
                result = add(place)
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
        case .next: what = "开始了去\(result.data["name"]?.stringValue ?? "下一站")的导航"
        case .add(let place):
            // An already listed place changed nothing: no note.
            if result.data["changed"] == "none" { return (result, nil) }
            what = "加入了\(place.name)"
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

    /// A place resolved again gets the link this launch already found (text search gives none), before the screen
    /// and the file see the list.
    private func applyKnownPhotos() {
        for place in plan.days.flatMap(\.stops).map(\.place) where place.photoURL == nil {
            if let known = photoKnown[place.id] { plan.setPhoto(placeID: place.id, url: known) }
        }
    }

    /// After a change: one detail call per stop without a photo link, `parallelLookups` (2) at once, after the tool result,
    /// so it never delays her reply. A stop that already has a link (a saved plan) makes no call.
    private func photos() {
        // §12 item 5: only failures count toward the one retry per launch.
        let abroadPhotos = abroadPhotos
        let asked = plan.days.flatMap(\.stops).filter { stop in
            let place = stop.place
            // §36 item 7 (T-040o): 高德 has no photos abroad; §46 (T-040r): Wikipedia there instead.
            return place.photoURL == nil && !place.id.hasPrefix("saved_") && !photoNone.contains(place.id)
                && (TripRegion.isChina(place.countryCode) || abroadPhotos != nil)
                && !photoPending.contains(place.id) && (photoTries[place.id] ?? 0) < 2
        }
        let unique = Dictionary(asked.map { ($0.place.id, $0) }, uniquingKeysWith: { a, _ in a }).values.map { $0 }
        guard !unique.isEmpty else { return }
        for stop in unique {
            photoTries[stop.place.id, default: 0] += 1
            photoPending.insert(stop.place.id)
        }
        let search = search, clock = clock, limit = tuning.parallelLookups
        let previous = photoTask
        let wanted = unique
        photoTask = Task { [weak self] in
            await previous?.value
            let started = clock.now
            var found: [PhotoFound] = []
            await withTaskGroup(of: PhotoFound.self) { group in
                var next = 0
                func add() {
                    guard next < wanted.count else { return }
                    let stop = wanted[next]
                    next += 1
                    group.addTask {
                        let place = stop.place
                        if TripRegion.isChina(place.countryCode) {
                            do {
                                let detail = try await search.detail(id: place.id)
                                return PhotoFound(id: place.id, url: detail?.photoURL, reached: true, vendor: "amap")
                            } catch {
                                return PhotoFound(id: place.id, url: nil, reached: false, vendor: "amap")
                            }
                        }
                        do {
                            let url = try await abroadPhotos?.photo(asked: stop.asked, near: place.coordinate)
                            return PhotoFound(id: place.id, url: url, reached: true, vendor: "wikipedia")
                        } catch {
                            return PhotoFound(id: place.id, url: nil, reached: false, vendor: "wikipedia")
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

    struct PhotoFound: Sendable {
        let id: String
        let url: URL?
        let reached: Bool
        let vendor: String
    }

    private func photosArrived(_ found: [PhotoFound], since started: NovaInstant) {
        var counts: [String: (ok: Int, none: Int, failed: Int)] = [:]
        for item in found {
            let id = item.id, url = item.url
            photoPending.remove(id)
            var ok = 0, none = 0, failed = 0
            defer {
                let c = counts[item.vendor] ?? (0, 0, 0)
                counts[item.vendor] = (c.ok + ok, c.none + none, c.failed + failed)
            }
            if !item.reached {
                failed += 1
                photoFailed.insert(id)
            } else if let url {
                ok += 1
                photoFailed.remove(id)
                photoTries[id] = 0
                photoKnown[id] = url
                plan.setPhoto(placeID: id, url: url)
            } else {
                none += 1
                photoFailed.remove(id)
                photoNone.insert(id)
            }
        }
        // §46 item 8: one line per vendor.
        let elapsed = ms(since: started)
        for vendor in counts.keys.sorted() {
            let c = counts[vendor]!
            onLine("trip photo vendor=\(vendor) ok=\(c.ok) none=\(c.none) failed=\(c.failed) ms=\(elapsed)")
        }
        // Saved plans keep the link, not the image (§12 item 4).
        if counts.values.contains(where: { $0.ok > 0 }) { persist() }
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
