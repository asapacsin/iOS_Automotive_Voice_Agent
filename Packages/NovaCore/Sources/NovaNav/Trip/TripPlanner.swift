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
    /// §11 item 5, §15, §52 item 9: a day tab (shows that day; not a plan change).
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
    /// §4 item 4: lookups at once, and the limit of a whole `set_trip_plan` lookup batch.
    /// Device 2026-11-17: 2 of 5 lookups failed with 4 at once (高德's per-second limit); now 2 at once, and a busy,
    /// timed-out or failed lookup is tried up to twice more (`retryDelay`, then twice that).
    public var parallelLookups = 2
    /// §52 item 11 (T-040zd): each name has its own limit (12 s), counted from when its lookup starts; there is no
    /// budget for the whole batch. A lookup still running then is `timeout` (said as `search_slow` by set_trip_plan).
    public var nameLimit = NovaDuration.seconds(12)
    /// §52 item 11: lookups abroad (Photon, no per-second limit like 高德's) run 4 at once.
    public var abroadParallelLookups = 4
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
    /// F-15b §54 item 3 (T-040zg): a new stop farther than this from every kept stop of `set_trip_plan` is a new trip.
    public var newTripKilometres = 300.0
    /// §50 item 3: a place abroad is kept only within this many km of the trip city's centre.
    public var areaKm = 50.0
    /// §50 item 3: Photon results asked per trip lookup inside the box.
    public var areaLimit = 5
    /// §50 item 4 `far`: a straight-line estimate over this (4 h) to every other place is "far".
    public var unreachableSeconds = 4 * 3600
    /// §50 item 2: hotels within 1 km of `hotel_near`, else 3 km, at most 5.
    public var hotelNearRadii = [1_000, 3_000]
    public var hotelNearMax = 5
    /// F-15b §52 item 4 (T-040zb): the wait between background tries for a stop not on the map yet.
    public var placeRetryGap: NovaDuration = .seconds(10)
    /// F-15b §62 item 7 (T-040zo): one planner call may take this long; then the plan is `PLANNER_FAILED` (timeout).
    public var plannerTimeout = NovaDuration.seconds(30)
    public init() {}
}

/// F-15b (T-040i, §55 T-040zh): `set_trip_plan` (makes and changes every plan), `trip_next` and `trip_plans`. Owns the app's one trip list (§3), resolves
/// the model's names through 高德 (§4, never taken as places), and routes the list through `NavigationController`
/// one stop at a time (§29). Record lines are codes and numbers only (§7, I-8).
public actor TripPlanner: ToolExecutor {
    /// F-15b §62 item 1 (T-040zo): `plan_trip` replaces `set_trip_plan` in the catalog. `set_trip_plan` stays an
    /// internal call of this actor (the old write path, used by tests to lay out a plan); it is never declared.
    public static let tools: Set<String> = ["plan_trip", "check_trip_plan", "trip_next", "trip_plans"]
    /// §56 item 4 with §49 item 6: at most this many `PLAN_CHECK` refusals carry the fix-and-resend `next`.
    public static let maxFixRounds = 2
    /// F-15b §61 item 3a (T-040zn): from this saved write in one driver request on, `next` says stop revising.
    public static let stopRevisingFrom = 3

    /// F-15b §61 items 3a-4 (T-040zn): the current driver request (its turn; nil without a turn count, then every
    /// call is a new request), the saved writes in it, and the stop names of the plan at the driver's last words.
    private var requestTurn: Int??
    private var requestSaves = 0
    private var requestStartNames: [String] = []
    /// §50 item 1: Qwen with web search; nil keeps the model's own names.
    private let grounder: (any TripGrounder)?
    /// F-15b §62 (T-040zo): the planner model `plan_trip` hands the request to; nil fails every `plan_trip`
    /// (`PLANNER_FAILED`, no fallback planner).
    private var plannerModel: (any TripPlannerModel)?
    public func setPlannerModel(_ model: (any TripPlannerModel)?) { plannerModel = model }
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
    /// §4 item 9: plan writes still running (`set_trip_plan`); `trip_next` waits for them.
    private var changes: [Int: Task<ToolResult, Never>] = [:]
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
    /// §52 item 9 (T-040zc): the whole plan, on every change and every day-view change.
    private let onPlan: @Sendable (TripPlan) -> Void
    /// §52 item 13 (T-040ze): the count of driver utterances (as `navigate_to`'s `CONFIRM_FIRST`); nil counts each call
    /// as a later turn.
    private let driverTurns: (@Sendable () async -> Int)?
    /// §52 item 13: the turn a whole-trip clear was asked on (`.some(nil)` with no turn count); nil when none waits.
    private var clearAsked: Int??
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
    /// Tests only (§55 item 11 removed `edit_trip_list visited|skip`): marks stop `index` (1-based) of the current day
    /// (or `day`), as a voice mark did: a reached night's hotel marks the next morning's copy too.
    func markForTests(index: Int, _ mark: TripMark, day: Int? = nil) {
        if let day { _ = plan.select(day) }
        guard (1...max(list.count, 1)).contains(index), list.count > 0 else { return }
        list.setMark(at: index, mark)
        if mark == .visited { markOtherCopy(day: plan.currentDay, index: index, mark) }
        changed()
    }
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
                onPlan: @escaping @Sendable (TripPlan) -> Void = { _ in },
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
                abroadArea: (@Sendable (String) async -> TripArea?)? = nil,
                driverTurns: (@Sendable () async -> Int)? = nil,
                plannerModel: (any TripPlannerModel)? = nil) {
        self.plannerModel = plannerModel
        self.driverTurns = driverTurns
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
        self.onPlan = onPlan
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
        // §51 item 3 (T-040y): a restored trip starts hidden; a new plan or 我的行程 (trip_plans open) shows it (§55 item 11 removed 「打开行程」). Nothing is deleted.
        if plan.stopCount > 0 { setHidden(true) }
        onLine("trip load ok=\(ok ? "yes" : "no") days=\(plan.dayCount) stops=\(plan.stopCount) hidden=\(cardsHidden ? "yes" : "no")")
        publish()
        onPlans(TripPlansSummary(plan, saved))
        photos()
    }

    /// The screen's inputs: the day in front (`onChange`) and the whole plan (§52 item 9, `onPlan`).
    private func publish() {
        onChange(list)
        onPlan(plan)
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
        // §51 item 8 (T-040z): `navigate_to near=trip` and a shown `near=here` (item 9) see the plan's stops and whether it is shown.
        await navigation.setNearTrip { [weak self] in await self?.nearTrip() }
    }

    /// §51 item 8: the plan as `navigate_to` sees it; nil when it has no stops.
    public func nearTrip() -> NearTrip? {
        guard plan.stopCount > 0 else { return nil }
        func near(_ day: Int, _ stop: TripStop) -> NearTripStop {
            NearTripStop(day: day, name: stop.place.name, asked: stop.asked, role: stop.role,
                         coordinate: stop.place.coordinate, countryCode: stop.place.countryCode)
        }
        // §52 item 4: a stop not on the map yet has a dummy (0,0) coordinate; it is never a search centre
        // (review 2026-11-21: near=here searched around 0°,0°).
        let stops = plan.allStops.filter(\.stop.placed).map { near($0.day, $0.stop) }
        guard !stops.isEmpty else { return nil }
        // §51 item 9 (T-040za): the next stop as `trip_next` takes it (the current day's first unmarked placed stop).
        let next = plan.days[plan.currentDay - 1].stops.first { $0.mark == nil && $0.placed }.map { near(plan.currentDay, $0) }
        return NearTrip(hidden: cardsHidden, abroad: plan.abroad, city: plan.city, stops: stops, next: next)
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
        // §51 item 2 (T-040y, replaces §22 item 3): trip commands only while the cards are shown. Blocked while hidden:
        // nothing runs, the plan and the hidden cards stay as they are.
        if cardsHidden, Self.blockedWhileHidden(call) {
            onLine("trip blocked tool=\(call.name) reason=hidden")
            return withPlan(Self.tripHiddenResult)
        }
        // Shows the cards: a new plan (§55 item 1), trip_plans open.
        if Self.showsCards(call) { setHidden(false) }
        switch call.name {
        case "plan_trip":
            // F-15b §62 (T-040zo): a write; it waits for the writes already running and `trip_next` waits for it.
            await waitFor()
            return withPlan(await trackedPlanTrip(call))
        case "set_trip_plan":
            // §4 item 9: a write waits for the writes already running.
            await waitFor()
            let result = await tracked(call)
            // F-15b §61 item 1 (T-040zn): `saved` is the generic `ok` and means only that the plan was stored.
            var data = result.data
            data["saved"] = .bool(result.ok)
            return withPlan(ToolResult(ok: result.ok, code: result.code, data: data, advice: result.advice))
        case "check_trip_plan":
            // §61 item 2: read-only; it counts the finished plan (or a draft), so it waits for running writes.
            await waitFor()
            work?.start(.trip, step: WorkProgress.tripChecking)
            onLine("work step=trip_check state=running")
            let result = await run(call)
            work?.clear(.trip)
            return withPlan(result)
        default:
            // §4 item 9: trip_next and trip_plans use the finished list: they wait until no change is running.
            await waitFor()
            return withPlan(await run(call))
        }
    }

    /// §52 item 2 (T-040zb): every trip tool result carries the whole plan (`TripPlanJSON`), every day.
    private func withPlan(_ result: ToolResult) -> ToolResult {
        var data = result.data
        data["plan"] = TripPlanJSON.value(plan)
        // F-15b §61 item 3 (T-040zn): the driver's request at the top of every trip result.
        if let asked = plan.asked { data["asked"] = asked.json }
        return ToolResult(ok: result.ok, code: result.code, data: data, advice: result.advice)
    }

    /// §51 item 2, F-09b §13 item 4 (T-031m): a trip command refused while the cards are hidden; nothing ran.
    public static let tripHiddenResult = ToolReply.notDone(
        .tripHidden, facts: ["trip_cards": "hidden", "plan_kept": true, "show_command": "打开我的行程"],
        may: [.nameCommand]).result
    /// The `next` of that refusal.
    public static var tripHiddenNext: String { tripHiddenResult.data["next"]?.stringValue ?? "" }

    /// §51 item 2: `trip_next` and a `set_trip_plan` that changes the plan (§52, replaces `revise_trip_list`). A new
    /// plan (§55 item 1: stops written, none kept by id) is what `make_trip_list` was: it runs and shows the cards.
    static func blockedWhileHidden(_ call: ToolCall) -> Bool {
        call.name == "trip_next" || (call.name == "set_trip_plan" && !makesNewPlan(call))
            || (call.name == "plan_trip" && planTripChange(call) != nil)
    }

    /// F-15b §62 item 1 (T-040zo): `ToolCatalog.validate`, except for `set_trip_plan`, which is internal now (not in
    /// the catalog) and keeps its own field checks (§56 item 2).
    static func validateWrite(_ call: ToolCall) -> ToolErrorCode? {
        guard call.name == "set_trip_plan" else { return ToolCatalog.validate(call) }
        guard case .object(let a) = call.arguments else { return .malformedJson }
        return ToolCatalog.tripPlanProblems(a).isEmpty ? nil : .invalidFields
    }

    /// F-15b §62 item 1 (T-040zo): the driver's words of a `plan_trip` change; nil for a new plan.
    static func planTripChange(_ call: ToolCall) -> String? {
        guard call.name == "plan_trip", let c = call.arguments["change"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !c.isEmpty else { return nil }
        return c
    }

    /// §55 item 1 (T-040zh): a `set_trip_plan` with stops, none of them kept by `id`.
    static func makesNewPlan(_ call: ToolCall) -> Bool {
        guard call.name == "set_trip_plan" else { return false }
        let stops = TripPlanner.writtenDays(call.arguments).joined()
        return !stops.isEmpty && !stops.contains { $0.id != nil }
    }

    /// §52 item 13: `set_trip_plan` with no stops.
    static func clearsWhole(_ call: ToolCall) -> Bool {
        call.name == "set_trip_plan" && TripPlanner.writtenDays(call.arguments).allSatisfy(\.isEmpty)
    }

    /// §51 item 2: the calls that show the cards; `trip_plans` list/save/delete/rename leave them as they are.
    static func showsCards(_ call: ToolCall) -> Bool {
        makesNewPlan(call) || (call.name == "trip_plans" && call.arguments["action"]?.stringValue == "open")
            || (call.name == "plan_trip" && planTripChange(call) == nil)
    }

    private func waitFor() async {
        waiting += 1
        defer { waiting -= 1 }
        var done = Set<Int>()
        while let next = changes.first(where: { !done.contains($0.key) }) {
            _ = await next.value.value
            done.insert(next.key)
        }
    }

    private func tracked(_ call: ToolCall) async -> ToolResult {
        let id = nextChange
        nextChange += 1
        let task = Task { await self.run(call) }
        changes[id] = task
        // F-15b §58 item 5 (T-040zk): an edit (the plan's ids kept) shows 正在改行程 from the start.
        let edit = call.name == "set_trip_plan" && !Self.makesNewPlan(call) && !Self.clearsWhole(call)
        // F-15b §60 item 1 (T-040zm): every `set_trip_plan` call opens its own panel (a fix round is a new call).
        work?.start(.trip, step: edit ? WorkProgress.tripEdit : nil)
        if edit { onLine("work step=trip_edit state=running") }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        changes[id] = nil
        if !result.ok, result.code == .invalidFields || result.code == .planCheck {
            // §58 item 5, §61 item 5 (T-040zn): a refused write: the cards stay, 「没保存：<first problems line>」 for 5 s.
            work?.finish(WorkProgress.tripNotSaved(Self.firstProblem(result)), failed: true)
            onLine("work step=trip_edit state=refused")
        } else if edit, result.ok {
            // §58 item 5, §61 item 5: the cards update; 「已加入<名字>」 (the new names) or 「行程已更新」 for 3 s.
            let added = Self.writtenDays(call.arguments).joined().filter { $0.id == nil }.compactMap { $0.name ?? $0.near }
            var names: [String] = []
            for n in added where !names.contains(n) { names.append(n) }
            work?.finish(names.isEmpty ? WorkProgress.tripUpdated : WorkProgress.tripAdded(names), failed: false)
            onLine("work step=trip_edit state=saved")
        } else {
            // The cards replace the steps of a new plan; any other failure keeps its line.
            result.ok ? work?.clear(.trip) : work?.end()
            if edit { onLine("work step=trip_edit state=refused") }
        }
        return result
    }

    /// §58 item 5: the first `problems` line of a refused write (top level, or `facts.problems` of `PLAN_CHECK`).
    static func firstProblem(_ result: ToolResult) -> String {
        let lines = result.data["problems"] ?? result.data["facts"]?["problems"]
        if case .array(let a)? = lines, let first = a.first?.stringValue { return first }
        return result.code?.rawValue ?? "失败"
    }

    private func run(_ call: ToolCall) async -> ToolResult {
        // The dispatcher validated the call (ToolCatalog.validate); this is the backstop for direct callers.
        if let code = Self.validateWrite(call) { return ToolDispatcher.refusal(call, code) }
        // §52 item 13: a waiting whole-trip clear is answered only by the next clear; any other trip call forgets it.
        if !Self.clearsWhole(call) { clearAsked = nil }
        switch call.name {
        case "set_trip_plan": return await setPlan(call.arguments)
        case "plan_trip": return await planTrip(call.arguments)
        case "check_trip_plan": return await checkPlan(call.arguments)
        case "trip_next": return await next(call.arguments)
        case "trip_plans": return await plans(call.arguments)
        default: return .failure(.unknownTool)
        }
    }

    // MARK: plan_trip (F-15b §62, T-040zo)

    /// §62 item 7: why a planner call gave no plan.
    enum PlannerFailure: String, Error, Sendable { case http, timeout, json }

    /// §62 item 1: `plan_trip` is a write: registered like `set_trip_plan` so `trip_next` waits for it. The spinner row
    /// (`handoff`) starts at once with 「已交给规划助手」 and ends with the result line (§62 item 12, §60 item 2).
    private func trackedPlanTrip(_ call: ToolCall) async -> ToolResult {
        let id = nextChange
        nextChange += 1
        work?.start(.handoff, step: WorkProgress.handedOver, immediate: true)
        onLine("work step=plan_trip state=running")
        let task = Task { await self.run(call) }
        changes[id] = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        changes[id] = nil
        if result.ok {
            work?.finish(WorkProgress.tripUpdated, failed: false)
            onLine("work step=plan_trip state=saved")
        } else {
            work?.finish(WorkProgress.tripNotSaved(result.code == .plannerFailed ? "规划没做成" : Self.firstProblem(result)), failed: true)
            onLine("work step=plan_trip state=failed")
        }
        return result
    }

    /// §62 items 1-8: the voice model hands the request on; the planner writes the plan in its own shape; code looks
    /// every stop up with its own city, counts, and sends the numbers back every round (no verdict); the planner
    /// revises. Code stops at `done=true` from round 2 on, or after round 3, and saves the last plan. No fallback
    /// planner: a failed call is `PLANNER_FAILED` with the cards unchanged.
    private func planTrip(_ args: JSONValue) async -> ToolResult {
        planWrites += 1
        defer { planWrites -= 1 }
        let started = clock.now
        let change = Self.planTripChange(ToolCall(id: CallID("plan")!, name: "plan_trip", arguments: args))
        let askedArg = TripAsked(args["asked"])
        if change != nil, plan.isEmpty { return failure(.noTripList) }
        guard let asked = askedArg ?? (change != nil ? plan.asked : nil) ?? change.map({ TripAsked(text: $0) }) else {
            return failure(.invalidFields)
        }
        let before = plan.allStops.map(\.stop.place.name)
        let first: String = if let change {
            TripPlannerShape.changeRequest(plan: TripPlannerShape.shape(plan), asked: askedArg ?? plan.asked, change: change)
        } else {
            TripPlannerShape.newRequest(asked)
        }
        var messages = [TripPlannerMessage(role: .user, content: first)]
        let model = plannerModel?.model ?? "none"
        var lookups: [String: Lookup] = [:]
        var areas: [String: TripArea?] = [:]
        var last: (plan: TripPlannerShape.Plan, built: PlannerBuilt)?
        var rounds = 0
        for round in 1...TripPlannerShape.maxRounds {
            rounds = round
            work?.step(round == 1 ? WorkProgress.tripPlanning : WorkProgress.tripRevising(round))
            let asking = clock.now
            let answer = await askPlanner(messages)
            guard !Task.isCancelled else { return .failure(.optionsStale) }
            guard case .success(let (text, written)) = answer else {
                if case .failure(let why) = answer {
                    onLine("trip planner failed reason=\(why.rawValue) round=\(round) ms=\(ms(since: asking)) model=\(model)")
                }
                return Self.plannerFailed()
            }
            guard !Task.isCancelled else { return .failure(.optionsStale) }
            work?.step(WorkProgress.tripCounting(round))
            let built = await buildPlanner(written, asked: asked, lookups: &lookups, areas: &areas)
            guard !Task.isCancelled else { return .failure(.optionsStale) }
            if built.keyMissing {
                return LookupReply.failed(.amapWebKeyMissing, what: "trip", cause: .keyMissing, facts: ["changed": false], mustNot: [.claimDone])
            }
            let counts = TripPlannerShape.countsText(built.counts)
            onLine("trip planner round=\(round) ms=\(ms(since: asking)) done=\(written.done ? "yes" : "no") days=\(written.days.count) stops=\(written.stopCount) model=\(model)")
            // §62 item 9: the planner's JSON and the counts message, in the local record only (names, as stop names).
            onLine("trip planner text plan=" + TripPlanJSON.text(written.json))
            onLine("trip planner text counts=" + counts.replacingOccurrences(of: "\n", with: " | "))
            last = (written, built)
            // §62 item 5: a done in round 1 still gets one counts round; then done or round 3 ends it.
            if (written.done && round >= 2) || round == TripPlannerShape.maxRounds { break }
            messages.append(TripPlannerMessage(role: .assistant, content: text))
            messages.append(TripPlannerMessage(role: .user, content: counts))
        }
        guard let (written, built) = last else { return Self.plannerFailed() }
        // Save (§62 item 5): the last plan as the planner wrote it, every stop placed or kept `placed=false`.
        let lists = built.days.map { stops in
            var list = TripList()
            list.arrange(stops)
            return list
        }
        if change != nil {
            plan.write(days: lists)
            plan.budgetMinutes = plan.budgetMinutes ?? TripFitter.Pace.normal.budgetMinutes
            if plan.city == nil { plan.city = asked.city ?? built.city }
        } else {
            plan.replaceAll(withDays: lists)
            plan.city = asked.city ?? built.city
            plan.abroad = built.abroad
            plan.budgetMinutes = TripFitter.Pace.normal.budgetMinutes
            area = nil
        }
        if let askedArg { plan.asked = askedArg } else if change == nil { plan.asked = asked }
        onLine("trip asked must=\(asked.must.count) days=\(asked.days.map(String.init) ?? "-") notes=\(asked.notes.count)")
        changed()
        retryUnplaced()
        let now = Set(plan.allStops.map(\.stop.place.name))
        var removed: [String] = []
        for n in before where !now.contains(n) && !removed.contains(n) { removed.append(n) }
        var data: [String: JSONValue] = [
            "status": "trip_plan",
            "saved": true,
            "asked": asked.json,
            "plan_text": .string(TripPlanJSON.planText(plan)),
            "note": .string(written.note),
            "rounds": .int(Int64(rounds)),
            "next": .string(TripPlannerShape.savedNext),
        ]
        if !built.notPlaced.isEmpty {
            data["not_placed"] = .array(built.notPlaced.map { n in
                .object(["name": .string(n.name), "searched": .string(n.range)])
            })
        }
        if change != nil, !removed.isEmpty { data["removed"] = .array(removed.map(JSONValue.string)) }
        onLine("trip planner saved rounds=\(rounds) days=\(plan.dayCount) stops=\(plan.stopCount) not_placed=\(built.notPlaced.count) new_plan=\(change == nil ? "yes" : "no") ms=\(ms(since: started))")
        return .success(data)
    }

    /// §62 item 7: one planner round: the call within `plannerTimeout`; an answer that is not the plan JSON is asked
    /// once more in the same round (not JSON twice fails).
    private func askPlanner(_ messages: [TripPlannerMessage]) async -> Result<(String, TripPlannerShape.Plan), PlannerFailure> {
        guard let plannerModel else { return .failure(.http) }
        for _ in 1...2 {
            switch await Self.complete(plannerModel, messages, clock: clock, limit: tuning.plannerTimeout) {
            case .failure(let why): return .failure(why)
            case .success(let text):
                if let written = TripPlannerShape.parse(text), written.stopCount > 0 { return .success((text, written)) }
                onLine("trip planner unreadable chars=\(text.count)")
            }
        }
        return .failure(.json)
    }

    /// §62 item 7: `saved=false`, `PLANNER_FAILED`, the cards unchanged, item 7's `next`.
    static func plannerFailed() -> ToolResult {
        var data = ToolReply.notDone(.plannerFailed, facts: ["plan_kept": true]).result.data
        data["saved"] = false
        data["next"] = .string(TripPlannerShape.failedNext)
        return ToolResult(ok: false, code: .plannerFailed, data: data, advice: nil)
    }

    /// The model's answer, or `http` (any error it throws) or `timeout` (no answer within `limit`).
    private static func complete(_ model: any TripPlannerModel, _ messages: [TripPlannerMessage], clock: any NovaClock,
                                 limit: NovaDuration) async -> Result<String, PlannerFailure> {
        let deadline = clock.now + limit
        return await withTaskGroup(of: Result<String, PlannerFailure>?.self) { group in
            group.addTask {
                do { return .success(try await model.complete(system: TripPlannerShape.system, messages: messages)) } catch {
                    return Task.isCancelled ? nil : .failure(.http)
                }
            }
            group.addTask {
                do { try await clock.sleep(until: deadline) } catch { return nil }
                return .failure(.timeout)
            }
            var out: Result<String, PlannerFailure> = .failure(.timeout)
            for await r in group {
                guard let r else { continue }
                out = r
                break
            }
            group.cancelAll()
            return out
        }
    }

    /// One unplaced stop and where it was looked for.
    struct PlannerMiss: Sendable, Hashable {
        let name: String
        let range: String
    }

    /// A planner plan as code laid it out: the days as stops (timed), the counts, the misses.
    struct PlannerBuilt: Sendable {
        var days: [[TripStop]]
        var counts: [TripPlannerShape.DayCount]
        var notPlaced: [PlannerMiss]
        var abroad: Bool
        var city: String?
        var keyMissing: Bool
    }

    /// §62 items 2, 4: each stop looked up with its own `city` (the asked city when the planner gave none; a lookup
    /// already made in this call is not made again). A stay that is a sight of the same day is that place: one lookup,
    /// visited that day and slept in, and the next day starts there. Then the day is timed (§48 `TripTimes`) and
    /// counted.
    private func buildPlanner(_ written: TripPlannerShape.Plan, asked: TripAsked,
                              lookups: inout [String: Lookup], areas: inout [String: TripArea?]) async -> PlannerBuilt {
        let fallbackCity = asked.city ?? plan.city
        func cityOf(_ c: String?) -> String? { c ?? fallbackCity }
        func key(_ name: String, _ city: String?) -> String { (city ?? "") + "|" + name }
        // The stay of a day that is also one of its sights takes that sight's city (one place).
        var days = written.days
        for d in days.indices {
            guard let stay = days[d].stay, let sight = days[d].sights.first(where: { $0.name == stay.name }) else { continue }
            days[d].stay = TripPlannerShape.Stay(name: stay.name, city: sight.city ?? stay.city)
        }
        // The names to look up, grouped by city, in first-seen order.
        var byCity: [(city: String?, names: [String])] = []
        for day in days {
            for (name, city) in day.sights.map({ ($0.name, cityOf($0.city)) }) + (day.stay.map { [($0.name, cityOf($0.city))] } ?? []) {
                guard lookups[key(name, city)] == nil else { continue }
                if let i = byCity.firstIndex(where: { $0.city == city }) {
                    if !byCity[i].names.contains(name) { byCity[i].names.append(name) }
                } else {
                    byCity.append((city, [name]))
                }
            }
        }
        var anyAbroad = false
        func isAbroad(_ a: TripArea??) -> Bool {
            if case .some(.some(let found)) = a { return !TripRegion.isChina(found.countryCode) }
            return false
        }
        for group in byCity {
            // §50 vendor rule: a city outside China searches abroad, around its centre; else 高德 inside the city.
            if let city = group.city, areas[city] == nil {
                if abroadSearch != nil, let abroadArea { areas[city] = .some(await abroadArea(city)) } else { areas[city] = .some(nil) }
            }
            let cityArea = group.city.flatMap { areas[$0] } ?? nil
            let abroad = isAbroad(group.city.map { areas[$0] } ?? nil)
            let found: [Lookup] = abroad
                ? await resolveCounting(group.names, city: nil, abroad: true, near: cityArea?.center).0
                : await resolve(group.names, city: group.city)
            for (i, name) in group.names.enumerated() where i < found.count { lookups[key(name, group.city)] = found[i] }
        }
        var keyMissing = false
        func range(_ city: String?) -> String {
            guard let city else { return "当前位置附近" }
            return isAbroad(areas[city]) ? "\(city)周围\(Int(tuning.areaKm))公里" : city
        }
        // The stops: sights in order, the night's place last; the next day starts at it.
        var stopOf: [String: TripStop] = [:]
        var misses: [PlannerMiss] = []
        func stop(_ name: String, _ city: String?, role: TripRole, minutes: Int?) -> TripStop {
            let k = key(name, city) + "|" + role.rawValue
            if role == .hotel, let made = stopOf[k] { return made }
            var place: Place?
            switch lookups[key(name, city)] {
            case .found(let p)?:
                place = p
                if city.map({ isAbroad(areas[$0]) }) == true { anyAbroad = true }
            case .keyMissing?: keyMissing = true
            default: break
            }
            if place == nil, !misses.contains(where: { $0.name == name }) { misses.append(PlannerMiss(name: name, range: range(city))) }
            let made = TripStop(index: 0, asked: name,
                                place: place ?? Self.unplacedPlace(name, key: "\(revisionKey)|plan|\(name)"),
                                distanceMeters: nil, role: role, minutes: minutes, placed: place != nil, pickedBy: .model)
            stopOf[k] = made
            return made
        }
        var stops: [[TripStop]] = []
        var morning: TripStop?
        for (d, day) in days.enumerated() {
            var list: [TripStop] = morning.map { [$0] } ?? []
            for s in day.sights { list.append(stop(s.name, cityOf(s.city), role: .sight, minutes: s.minutes)) }
            morning = nil
            if d < days.count - 1, let stay = day.stay {
                let hotel = stop(stay.name, cityOf(stay.city), role: .hotel, minutes: nil)
                list.append(hotel)
                morning = hotel
            }
            stops.append(list)
        }
        // F-15b §63 item 4 (T-040zp): the counts are of the merged plan, as saved.
        stops = stops.map(TripList.mergedAdjacent)
        let timed = await timedDays(stops, abroad: anyAbroad, keepFirstLegs: false, showStep: false).days
        let budget = plan.budgetMinutes ?? TripFitter.Pace.normal.budgetMinutes
        let counts: [TripPlannerShape.DayCount] = timed.enumerated().map { d, list in
            let ownStops = list.enumerated().filter { i, s in !(d > 0 && i == 0 && s.role == .hotel && s.visitMinutes == 0) }.map(\.element)
            let legs: [Int?] = list.dropFirst().map { s in s.legSeconds.map { Int((Double($0) / 60).rounded()) } }
            return TripPlannerShape.DayCount(
                stops: ownStops.map { s in
                    TripPlannerShape.StopCount(name: s.asked, found: s.placed ? s.place : nil, minutes: s.visitMinutes,
                                               isStay: s.role == .hotel,
                                               range: misses.first { $0.name == s.asked }?.range ?? range(fallbackCity))
                },
                legs: legs, budget: budget)
        }
        let city = days.lazy.flatMap(\.sights).compactMap(\.city).first ?? fallbackCity
        return PlannerBuilt(days: timed, counts: counts, notPlaced: misses, abroad: anyAbroad, city: city, keyMissing: keyMissing)
    }

    // MARK: §50 grounding and hotels near a place (§55 items 4, 7)

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

    // MARK: set_trip_plan (§52, T-040zb)

    /// §52 item 3: one stop as the model wrote it: `{id}` (kept, maybe with a new role or minutes) or a new `name`.
    struct WrittenStop: Sendable, Hashable {
        var id: String?
        var name: String?
        var role: TripRole?
        var minutes: Int?
        var importance: Int?
        /// §55 item 7 (T-040zh): `{role: hotel, near}`: the app picks the hotel closest to this place.
        var near: String?
    }

    static func writtenDays(_ args: JSONValue) -> [[WrittenStop]] {
        guard case .array(let days)? = args["days"] else { return [] }
        return days.map { day in
            guard case .array(let stops) = day else { return [] }
            return stops.map { s in
                WrittenStop(id: s["id"]?.stringValue,
                            name: s["name"]?.stringValue.map(TranscriptText.normalize),
                            role: s["role"]?.stringValue.flatMap(TripRole.init(rawValue:)),
                            minutes: s["minutes"]?.intValue.map { TripStop.clampMinutes(Int($0)) },
                            importance: s["importance"]?.intValue.map { TripStop.clampImportance(Int($0)) },
                            near: s["near"]?.stringValue.map(TranscriptText.normalize))
            }
        }
    }

    /// §52 item 5: what is wrong with a written plan, as lines for the model; empty when it can be saved. A stop's
    /// role is its written role, else its role in `old`, else `sight`. Two stops are the same place when they have the
    /// same id, or (new) the same name. A night with no hotel is not a problem: the app picks one (item 6).
    static func planProblems(_ days: [[WrittenStop]], old: TripPlan) -> [String] {
        var problems: [String] = []
        guard (1...TripPlan.maxDays).contains(days.count) else { return ["天数要在1到\(TripPlan.maxDays)天之间"] }
        let known = Dictionary(old.allStops.map { ($0.stop.id, $0) }, uniquingKeysWith: { a, _ in a })
        func role(_ s: WrittenStop) -> TripRole { s.role ?? s.id.flatMap { known[$0]?.stop.role } ?? .sight }
        func key(_ s: WrittenStop) -> String {
            s.id.map { "id:" + $0 } ?? s.name.map { "name:" + $0 } ?? "near:" + (s.near ?? "")
        }
        func label(_ s: WrittenStop) -> String {
            s.name ?? s.id.flatMap { known[$0]?.stop.place.name } ?? s.id ?? s.near.map { "\($0)附近的酒店" } ?? ""
        }
        // Unknown ids.
        for s in days.joined() { if let id = s.id, known[id] == nil { problems.append("没有这个 id：\(id)") } }
        // start: at most one, the first stop of day 1; end: at most one, the last stop of the last day.
        let positions = days.enumerated().flatMap { d, day in day.enumerated().map { (d, $0.offset, $0.element) } }
        let starts = positions.filter { role($0.2) == .start }
        if starts.count > 1 || starts.contains(where: { $0.0 != 0 || $0.1 != 0 }) {
            problems.append("出发点（start）最多一个，而且要是第一天第一个")
        }
        let ends = positions.filter { role($0.2) == .end }
        let lastDay = days.count - 1
        if ends.count > 1 || ends.contains(where: { $0.0 != lastDay || $0.1 != days[lastDay].count - 1 }) {
            problems.append("终点（end）最多一个，而且要是最后一天最后一个")
        }
        // Hotels: each night k (1…days−1) at most one, the last stop of day k and the first of day k+1, the same place.
        var allowed = Set<String>()
        for k in 0..<max(days.count - 1, 0) {
            let evening = days[k].last.flatMap { role($0) == .hotel ? $0 : nil }
            let morning = days[k + 1].first.flatMap { role($0) == .hotel ? $0 : nil }
            switch (evening, morning) {
            case (nil, nil): break
            case let (e?, m?) where key(e) == key(m):
                allowed.insert("\(k)|\(days[k].count - 1)")
                allowed.insert("\(k + 1)|0")
            case let (e?, m?):
                problems.append("第\(k + 1)晚有两个酒店（\(label(e))、\(label(m))），每晚只能住一个：当天最后一个和第二天第一个要是同一家")
                allowed.insert("\(k)|\(days[k].count - 1)")
                allowed.insert("\(k + 1)|0")
            case let (e?, nil):
                problems.append("第\(k + 1)晚的酒店\(label(e))也要写成第\(k + 2)天第一个")
                allowed.insert("\(k)|\(days[k].count - 1)")
            case let (nil, m?):
                problems.append("第\(k + 1)晚的酒店\(label(m))也要写成第\(k + 1)天最后一个")
                allowed.insert("\(k + 1)|0")
            }
        }
        for (d, i, s) in positions where role(s) == .hotel && !allowed.contains("\(d)|\(i)") {
            problems.append("第\(d + 1)天的酒店\(label(s))要是当天最后一个（第二天第一个也写它）；最后一天没有酒店")
        }
        // Duplicate ids: only a hotel may appear more than once, and only at night positions (one hotel for many nights).
        var places: [String: [(Int, Int, WrittenStop)]] = [:]
        for p in positions { if let id = p.2.id { places[id, default: []].append(p) } }
        for (id, at) in places.sorted(by: { $0.key < $1.key }) where at.count > 1 {
            if !at.allSatisfy({ role($0.2) == .hotel && allowed.contains("\($0.0)|\($0.1)") }) { problems.append("id 重复：\(id)") }
        }
        // A visited or skipped stop keeps its day. A night's hotel is on two days (evening and next morning), so either
        // of the days it was on is its day (review 2026-11-21: a reached hotel could not be written back).
        var daysOf: [String: Set<Int>] = [:]
        for s in old.allStops { daysOf[s.stop.id, default: []].insert(s.day) }
        for (d, _, s) in positions {
            guard let id = s.id, let was = known[id], was.stop.mark != nil, daysOf[id]?.contains(d + 1) != true else { continue }
            problems.append("\(was.stop.place.name)已经去过或跳过，要留在第\(was.day)天")
        }
        var unique = Set<String>()
        return problems.filter { unique.insert($0).inserted }
    }

    /// §52 item 4: a stop not on the map yet: its name, no coordinate the routes can use (`placed=false`).
    static func unplacedPlace(_ name: String, key: String) -> Place {
        Place(id: "unplaced:" + key, name: name, address: nil,
              coordinate: GeoCoordinate(latitude: 0, longitude: 0, datum: .gcj02), distanceMeters: nil)
    }

    /// F-15b §61 item 3a (T-040zn): every saved `set_trip_plan` result's `next`, exactly as §61 gives it.
    public static let reviewNext = "行程已存上，先别跟司机说话，对照 asked 自己检查一遍 plan：1. must 里的地点、天数、城市、notes 都做到没有；2. 有没有空的一天；3. 每天的安排合不合理（时间、路程要核对就调用 check_trip_plan）。有问题就自己改好，再调用 set_trip_plan。都没问题了再跟司机说：简短说安排了什么；没做到的说哪个、为什么，问司机怎么办。must 里的地点没找到，不要自己换掉或去掉，问司机。plan 里没有的不要说有。"
    /// §61 item 3a: the `next` from the third saved write in one driver request on.
    public static let stopRevisingNext = "已经改了几次了，别再改，照 plan 跟司机说：安排了什么，还有哪些没做到、为什么。"
    /// §61 item 3: the `PLAN_CHECK` line of a new plan without `asked`.
    public static let askedMissing = "新行程要写 asked（司机要什么：text、must、days、city、notes）"
    /// §55 item 2: the line of a new plan without `city` (§56 item 2: now an `INVALID_FIELDS` problem).
    public static let cityMissing = ToolCatalog.tripCityMissing

    /// §52 items 3–8 with §55 (T-040zh): `set_trip_plan` makes and changes every plan. A call that keeps no `id` is a
    /// new plan: `city` is required and the plan in hand is replaced (no `CONFIRM_CLEAR`). New names are looked up
    /// inside the plan's city (a name not found there is kept with `placed=false`, never a nationwide guess); a
    /// `{role: hotel, near}` stop is the hotel closest to that place, picked by the app. Code never moves a stop to
    /// another day and never asks for a start. F-15b §61 (T-040zn): it saves and reports, it does not check: no critics,
    /// no `trip_needs_fix`, no rounds; the driver's request (`asked`) is kept with the plan and she reviews it herself.
    private func setPlan(_ args: JSONValue) async -> ToolResult {
        planWrites += 1
        defer { planWrites -= 1 }
        let started = clock.now
        let written = Self.writtenDays(args)
        let stopTotal = written.reduce(0) { $0 + $1.count }
        let newPlan = !written.joined().contains { $0.id != nil }
        let cityArg = args["city"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        // §56 item 1 (T-040zi): keys ignored, listed once in facts and counted in the record.
        let ignored: [String] = if case .object(let o) = args { ToolCatalog.tripIgnoredFields(o) } else { [] }
        var counts = (kept: 0, new: 0, removed: 0, notPlaced: 0)
        let askedArg = TripAsked(args["asked"])
        // §61 items 3a-4 (T-040zn): new driver words start a new request: its save count and the plan it started from.
        let turn = await driverTurns?()
        if turn == nil || requestTurn != .some(turn) {
            requestTurn = .some(turn)
            requestSaves = 0
            var names: [String] = []
            for r in plan.allStops where !names.contains(r.stop.place.name) { names.append(r.stop.place.name) }
            requestStartNames = names
        }
        // §61 item 5: `saved=yes|no` (the `check=`, `issues=` and `round=` fields are gone).
        func log(_ saved: Bool) {
            onLine("trip set days=\(written.count) stops=\(stopTotal) kept=\(counts.kept) new=\(counts.new) removed=\(counts.removed) not_placed=\(counts.notPlaced) new_plan=\(newPlan ? "yes" : "no") saved=\(saved ? "yes" : "no") ms=\(ms(since: started)) ignored=\(ignored.count)")
        }
        // §50 item 6: a new plan's first step is the place check; a change is 正在改行程 (§58 item 5).
        work?.step(newPlan ? WorkProgress.tripCheck : WorkProgress.tripEdit)
        // §52 item 13 (T-040ze): a plan with no stops is a clear of the whole trip.
        if stopTotal == 0 { return await clearWhole(viaPlan: true) }
        // §56 item 2 (T-040zi): a new plan without city is refused before this (`INVALID_FIELDS`, `ToolCatalog`).
        var problems = Self.planProblems(written, old: newPlan ? TripPlan() : plan)
        // §61 item 3: a new plan needs `asked`, like `city`; a change keeps the saved one when it is not sent.
        if newPlan, askedArg == nil { problems.append(Self.askedMissing) }
        guard problems.isEmpty else {
            log(false)
            planCheckRounds += 1
            var result = failure(.planCheck, facts: ["problems": .array(problems.map(JSONValue.string)), "plan_kept": true])
            // §49 item 6's round limit: within it she fixes the plan and sends it again without a word.
            if planCheckRounds <= Self.maxFixRounds {
                var data = result.data
                data["next"] = "先不要跟司机说话，按 problems 改好整份行程，再调用 set_trip_plan。"
                result = ToolResult(ok: false, code: .planCheck, data: data, advice: result.advice)
            }
            return result
        }
        planCheckRounds = 0
        let generation = plan.revision
        let known = newPlan ? [:] : Dictionary(plan.allStops.map { ($0.stop.id, $0.stop) }, uniquingKeysWith: { a, _ in a })
        let city = newPlan ? cityArg : plan.city
        var abroad = newPlan ? false : plan.abroad
        // New names, once each (a night's hotel is written twice), looked up as places of the trip.
        var newNames: [String] = []
        var nears: [String] = []
        for s in written.joined() where s.id == nil {
            if let n = s.name, !newNames.contains(n) { newNames.append(n) }
            if s.name == nil, let n = s.near, !nears.contains(n) { nears.append(n) }
        }
        var lookups: [Lookup] = []
        var groundHotels: [TripGroundHotel] = []
        if newPlan {
            // §55 item 2: `abroad` comes from where the city is (§36): the city's country when it is known.
            var asked = false
            var countryKnown = false
            area = nil
            if abroadSearch != nil, let abroadArea, let city, let found = await abroadArea(city) {
                asked = !TripRegion.isChina(found.countryCode)
                countryKnown = found.countryCode != nil
            }
            if newNames.isEmpty {
                abroad = asked
                if asked, let abroadArea, let city { area = await abroadArea(city) }
            } else {
                // §55 item 4 with §50 item 1: abroad, the written names go to Qwen with web search first; a name it
                // matches (on `name` or `english`) is searched as 「中文名 (English)」. The model's days stay as written:
                // places Qwen adds are not put in the plan (only the model writes it).
                var asks = newNames
                if asked, let grounder, let city {
                    let model = written.joined().filter { $0.id == nil && $0.name != nil && $0.role != .hotel }
                        .map { TripGroundPlace(name: $0.name!, minutes: $0.minutes, importance: $0.importance ?? 3) }
                    let start = written.first?.first.flatMap { $0.role == .start ? $0.name : nil }
                    let end = written.last?.last.flatMap { $0.role == .end ? $0.name : nil }
                    let request = TripGroundRequest(city: city, days: written.count, places: model, start: start, end: end,
                                                    hotelNear: nears.first)
                    work?.step(WorkProgress.tripFind)
                    if let answer = await ground(request, with: grounder) {
                        groundHotels = answer.hotels
                        asks = newNames.map { n in
                            answer.places.first { TripGround.matches($0.name, n) || ($0.english.map { TripGround.matches($0, n) } ?? false) }
                                .map { TranscriptText.normalize(TripGround.written($0)) } ?? n
                        }
                    }
                    guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
                }
                // §55 item 4: at home 高德 with `city` and `citylimit=true`; abroad the box around the city's centre.
                (lookups, abroad) = await resolveTrip(asks, city: city, abroad: asked, countryKnown: countryKnown)
            }
        } else {
            if plan.abroad, area == nil, let abroadArea, let city = plan.city { area = await abroadArea(city) }
            if !newNames.isEmpty {
                // §58 item 5: 「正在找<名字>」 for each new name (names that will be on the cards).
                for n in newNames { work?.step(WorkProgress.tripFinding(n)) }
                lookups = await resolve(newNames, city: plan.abroad ? nil : plan.city, abroad: plan.abroad, near: regionHint())
            }
        }
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        if lookups.contains(where: { if case .keyMissing = $0 { true } else { false } }) {
            return LookupReply.failed(.amapWebKeyMissing, what: "trip", cause: .keyMissing, facts: ["changed": false], mustNot: [.claimDone])
        }
        var placeOf: [String: Place] = [:]
        var notPlaced: [String] = []
        var slow: [String] = []
        for (i, name) in newNames.enumerated() {
            switch lookups[i] {
            case .found(let place): placeOf[name] = place
            case .missing(let reason):
                notPlaced.append(name)
                onLine("trip lookup index=\(i + 1) ok=no reason=\(reason)")
                // §52 item 11 seam (T-040zd): a lookup out of tries comes back `slow`; it is said as `search_slow`.
                // A lookup still running at its own limit (`timeout`) is slow too, never "not found" (§52 item 4).
                if Self.isSlow(reason) { slow.append(name) }
            case .candidates, .keyMissing: notPlaced.append(name)
            }
        }
        // §55 item 7: `{role: hotel, near}`: the hotel closest to that place (§50 item 2), one for every night it is written.
        var nearHotel: [String: Place] = [:]
        for n in nears {
            if let first = await hotelsNear(n, city: city, abroad: abroad, grounded: groundHotels)?.first { nearHotel[n] = first.place }
        }
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        let here = await origin()
        // The plan as written: kept stops as they were (place, photo, times, mark), with a changed role or minutes; new
        // ones. A `near` hotel that found no hotel is left out (that night gets the `hotel` issue).
        var newStopOf: [String: TripStop] = [:]
        var days: [[TripStop]] = written.map { day in
            day.compactMap { w -> TripStop? in
                if let id = w.id, var s = known[id] {
                    if let role = w.role, role != s.role {
                        s.role = role
                        s.pickedBy = .model
                    }
                    if let m = w.minutes { s.minutes = m }
                    return s
                }
                if w.name == nil, let near = w.near {
                    if let made = newStopOf["near:" + near] { return made }
                    guard let hotel = nearHotel[near] else { return nil }
                    let stop = TripStop(index: 0, asked: near, place: hotel, distanceMeters: nil, role: .hotel, pickedBy: .app)
                    newStopOf["near:" + near] = stop
                    return stop
                }
                let name = w.name ?? ""
                let role = w.role ?? .sight
                if role == .hotel, let made = newStopOf[name] { return made }
                let place = placeOf[name]
                let stop = TripStop(index: 0, asked: name, place: place ?? Self.unplacedPlace(name, key: "\(revisionKey)|\(name)"),
                                    distanceMeters: place.flatMap { distance(here, $0) }, role: role, minutes: w.minutes,
                                    importance: w.importance, placed: place != nil, pickedBy: .model)
                newStopOf[name] = stop
                return stop
            }
        }
        let keptIDs = Set(written.joined().compactMap(\.id))
        var removedNames: [String] = []
        for r in plan.allStops where !keptIDs.contains(r.stop.id) && !removedNames.contains(r.stop.place.name) {
            removedNames.append(r.stop.place.name)
        }
        counts = (keptIDs.count, newNames.count + nears.count, removedNames.count, notPlaced.count)
        // §52 item 8, §55 item 5: the model's days and order are kept; `optimise` reorders within each day only.
        if args["optimise"]?.boolValue == true {
            for d in days.indices { days[d] = await optimisedDay(days[d]) }
        }
        let timed = await timedDays(days, abroad: abroad, keepFirstLegs: !newPlan)
        guard !Task.isCancelled, plan.revision == generation else { return .failure(.optionsStale) }
        let lists = timed.days.map { stops in
            var list = TripList()
            list.arrange(stops)
            return list
        }
        let pace = args["pace"]?.stringValue.flatMap(TripFitter.Pace.init(rawValue:))
        if newPlan {
            // §55 item 3: a new plan replaces the plan in hand (its name goes with the old plan).
            plan.replaceAll(withDays: lists)
            plan.city = city
            plan.abroad = abroad
            plan.budgetMinutes = (pace ?? .normal).budgetMinutes
        } else {
            plan.write(days: lists)
            // §48 item 3: B is the pace's budget; a plan of no pace yet is `normal`.
            plan.budgetMinutes = pace?.budgetMinutes ?? plan.budgetMinutes ?? TripFitter.Pace.normal.budgetMinutes
        }
        plan.spare.removeAll { s in plan.allStops.contains { $0.stop.place.id == s.place.id } }
        // §61 item 3: `asked` replaced when sent, kept when not (a new plan always sends it).
        if let askedArg {
            plan.asked = askedArg
            onLine("trip asked must=\(askedArg.must.count) days=\(askedArg.days.map(String.init) ?? "-") notes=\(askedArg.notes.count)")
        }
        changed()
        // §52 item 4: names not on the map are searched again in the background.
        retryUnplaced()
        var facts: [String: JSONValue] = ["kept": .int(Int64(counts.kept)), "new": .int(Int64(counts.new))]
        if newPlan { facts["new_plan"] = true }
        if !ignored.isEmpty { facts["ignored_fields"] = .array(ignored.map(JSONValue.string)) }
        if !removedNames.isEmpty { facts["removed"] = .array(removedNames.map(JSONValue.string)) }
        if !notPlaced.isEmpty { facts["not_placed"] = .array(notPlaced.map(JSONValue.string)) }
        if !slow.isEmpty { facts["search_slow"] = .array(slow.map(JSONValue.string)) }
        if timed.estimated { facts["times"] = "estimated" }
        // §61 item 3a: no critics; she reviews the plan against `asked`. From the 3rd save in a request: stop revising.
        requestSaves += 1
        // §55 item 6: no start is not an error; she may ask for one after the plan is saved.
        let hasStart = plan.days.first?.stops.first?.role == .start
        let may: [ReplyMay] = newPlan && !hasStart ? [.askStart] : []
        // §61 item 4: `removed` over the driver request: the plan at the driver's last words, less the plan now.
        let now = Set(plan.allStops.map(\.stop.place.name))
        let removedOverRequest = requestStartNames.filter { !now.contains($0) }
        facts["removed"] = removedOverRequest.isEmpty ? nil : .array(removedOverRequest.map(JSONValue.string))
        if !notPlaced.isEmpty { facts["not_placed_range"] = .string(searchedRange()) }
        var data = listResult(changed: "set", facts: facts, may: may, mustNot: [.readList, .readDistances]).data
        // §61 item 3a: the plan as she wrote it, one line per day, ahead of the JSON.
        data["plan_text"] = .string(TripPlanJSON.planText(plan))
        data["next"] = .string(requestSaves >= Self.stopRevisingFrom ? Self.stopRevisingNext : Self.reviewNext)
        log(true)
        return .success(data)
    }

    /// F-15b §61 item 2 (T-040zn): `check_trip_plan`, the counting assistant. No arguments: the plan in hand. `days` in
    /// `set_trip_plan`'s shape: a draft (kept ids as they are, new names looked up as `set_trip_plan` does), nothing
    /// saved, the cards unchanged. Numbers and facts only: no verdict, no advice, no thresholds.
    private func checkPlan(_ args: JSONValue) async -> ToolResult {
        let started = clock.now
        let written = Self.writtenDays(args)
        let draft = !written.isEmpty
        var days: [[TripStop]] = plan.days.map(\.stops)
        var notFound: [String] = []
        if draft {
            let known = Dictionary(plan.allStops.map { ($0.stop.id, $0.stop) }, uniquingKeysWith: { a, _ in a })
            var newNames: [String] = []
            for s in written.joined() where s.id == nil { if let n = s.name, !newNames.contains(n) { newNames.append(n) } }
            let lookups = newNames.isEmpty ? [] : await resolve(newNames, city: plan.abroad ? nil : plan.city,
                                                                abroad: plan.abroad, near: regionHint())
            var placeOf: [String: Place] = [:]
            for (i, n) in newNames.enumerated() { if case .found(let p) = lookups[i] { placeOf[n] = p } }
            var nearOf: [String: Place] = [:]
            for s in written.joined() where s.id == nil && s.name == nil {
                guard let near = s.near, nearOf[near] == nil else { continue }
                if let h = await hotelsNear(near, city: plan.city, abroad: plan.abroad, grounded: [])?.first { nearOf[near] = h.place }
            }
            days = written.map { day in
                day.compactMap { w -> TripStop? in
                    if let id = w.id {
                        guard var stop = known[id] else { return nil }
                        if let r = w.role { stop.role = r }
                        if let m = w.minutes { stop.minutes = m }
                        return stop
                    }
                    let name = w.name ?? w.near.map { "\($0)附近的酒店" } ?? ""
                    let place = w.name.flatMap { placeOf[$0] } ?? w.near.flatMap { nearOf[$0] }
                    return TripStop(index: 0, asked: name, place: place ?? Self.unplacedPlace(name, key: "draft|\(name)"),
                                    distanceMeters: nil, role: w.role ?? (w.near != nil ? .hotel : .sight), minutes: w.minutes,
                                    importance: w.importance, placed: place != nil, pickedBy: .model)
                }
            }
            days = await timedDays(days, abroad: plan.abroad, keepFirstLegs: false).days
            guard !Task.isCancelled else { return .failure(.optionsStale) }
        }
        let budget = plan.budgetMinutes ?? TripFitter.Pace.normal.budgetMinutes
        let range = searchedRange()
        var unknown: [JSONValue] = []
        var dayValues: [JSONValue] = []
        for (d, stops) in days.enumerated() {
            var list = TripList()
            list.arrange(stops)
            let sight = list.stops.reduce(0) { $0 + $1.visitMinutes }
            let driving = Int((Double(list.stops.reduce(0) { $0 + ($1.legSeconds ?? 0) }) / 60).rounded())
            for s in list.stops where !s.placed && !notFound.contains(s.place.name) { notFound.append(s.place.name) }
            for (a, b) in zip(list.stops, list.stops.dropFirst()) where !a.placed || !b.placed {
                unknown.append(.string("第\(d + 1)天：\(a.place.name)→\(b.place.name)"))
            }
            // The night after day d+1 has its hotel when the day ends with one (the last day has no night).
            let hotel: JSONValue = d == days.count - 1 ? .null
                : list.stops.last.flatMap { $0.role == .hotel ? JSONValue.string($0.place.name) : nil } ?? .null
            dayValues.append(.object([
                "day": .int(Int64(d + 1)),
                "sight_minutes": .int(Int64(sight)),
                "driving_minutes": .int(Int64(driving)),
                "total_minutes": .int(Int64(Self.dayMinutes(list))),
                "budget_minutes": .int(Int64(budget)),
                "stops": .array(list.stops.map { .object(["name": .string($0.place.name), "placed": .bool($0.placed)]) }),
                "hotel": hotel,
            ]))
        }
        onLine("trip check-call draft=\(draft ? "yes" : "no") days=\(days.count) not_found=\(notFound.count) unknown_driving=\(unknown.count) ms=\(ms(since: started))")
        let data: [String: JSONValue] = [
            "status": "trip_check",
            "draft": .bool(draft),
            "days": .array(dayValues),
            "not_found": .array(notFound.map { .object(["name": .string($0), "searched": .string(range)]) }),
            "unknown_driving": .array(unknown),
        ]
        return .success(data)
    }

    /// §61 items 1-2 (T-040zn): where new names are looked up: the trip's city at home, the box around it abroad.
    private func searchedRange() -> String {
        let city = plan.city ?? "当前位置附近"
        return plan.abroad ? "\(city)周围\(Int(tuning.areaKm))公里" : city
    }

    /// `clear` without `day`, or `set_trip_plan` with no stops: the whole plan is cleared.
    /// §52 item 13 (T-040ze): the first time it returns `CONFIRM_CLEAR` and changes nothing; only a clear on the
    /// driver's next turn (his yes) clears. `trip clear confirm=asked|yes via=edit|plan`.
    private func clearWhole(viaPlan: Bool) async -> ToolResult {
        let via = viaPlan ? "plan" : "edit"
        let turn = await driverTurns?()
        let answered: Bool = switch clearAsked {
        case .some(.some(let asked)): turn.map { $0 == asked + 1 } ?? true
        case .some(.none): true
        case .none: false
        }
        // An empty plan has nothing to lose: cleared at once.
        let confirmed = plan.isEmpty || answered
        guard confirmed else {
            clearAsked = .some(turn)
            onLine("trip clear confirm=asked via=\(via)")
            return ToolReply.notDone(.confirmClear, facts: ["days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)),
                                                            "plan_kept": true], may: [.askConfirm]).result
        }
        clearAsked = nil
        onLine("trip clear confirm=yes via=\(via)")
        plan.clearAll()
        retryTask?.cancel()
        changed()
        return listResult(changed: "cleared")
    }

    /// A key that makes an unplaced stop's place id unique within the plan's life.
    private var revisionKey: Int { plan.revision }

    /// §52 item 8 with §28 item 3: one day ordered again between its fixed ends (a start or hotel first, a hotel or end
    /// last), as `move … to_day` did; the day as written when it cannot be ordered. Unplaced stops stay at the end.
    private func optimisedDay(_ stops: [TripStop]) async -> [TripStop] {
        let placed = stops.filter(\.placed)
        let unplaced = stops.filter { !$0.placed }
        guard placed.count > 2 else { return stops }
        var framed = placed
        let head = framed.first.flatMap { $0.role != .sight ? $0 : nil }
        let tail = framed.last.flatMap { $0.role != .sight ? $0 : nil }
        if var h = head { h.role = .start; framed[0] = h }
        if var t = tail { t.role = .end; framed[framed.count - 1] = t }
        var asOne = TripList()
        asOne.arrange(framed)
        guard case .success(let o) = await ordered([asOne], dayCount: 1, named: head == nil ? framed.first?.place.id : nil),
              var back = o.days.first?.stops, back.count == placed.count else { return stops }
        if let head, let i = back.firstIndex(where: { $0.role == .start }) { back[i].role = head.role }
        if let tail, let i = back.lastIndex(where: { $0.role == .end }) { back[i].role = tail.role }
        // Unplaced stops go before a closing hotel or end.
        if let last = back.last, last.role != .sight { return Array(back.dropLast()) + unplaced + [last] }
        return back + unplaced
    }

    /// §52 item 8 with §36 item 6: driving seconds between the placed stops of each day, in the written order (one
    /// table per day; abroad the estimate when OSRM fails). A day whose table fails keeps no times.
    /// `showStep`: false keeps 「计算开车时间」 off the panel (§62 item 12: `plan_trip`'s row shows only its own steps).
    private func timedDays(_ days: [[TripStop]], abroad: Bool, keepFirstLegs: Bool,
                           showStep: Bool = true) async -> (days: [[TripStop]], estimated: Bool) {
        let tableTimes = abroad ? (abroadTimes ?? times) : times
        var estimated = false
        var out = days
        // The drive into a day's first stop (from the car or the start) is kept when that stop was already first.
        let firstBefore = !keepFirstLegs ? [:] : Dictionary(plan.days.enumerated().compactMap { d, day in day.stops.first.map { ("\(d)|\($0.id)", $0.legSeconds) } },
                                     uniquingKeysWith: { a, _ in a })
        for d in out.indices {
            for i in out[d].indices {
                out[d][i].legSeconds = i == 0 ? (firstBefore["\(d)|\(out[d][i].id)"] ?? nil) : nil
            }
            let placed = out[d].indices.filter { out[d][$0].placed }
            guard placed.count > 1 else { continue }
            let nodes = placed.map { TripTimes.Node(key: out[d][$0].place.id, coordinate: out[d][$0].place.coordinate) }
            guard !Set(nodes.map(\.key)).isEmpty, tableTimes != nil || abroad else { continue }
            let asked = clock.now
            if showStep { work?.step(WorkProgress.tripTimes) }
            var table = await tableTimes?.table(start: nil, stops: nodes)
            if table == nil, abroad { table = TripTimes.estimate(start: nil, stops: nodes) }
            let vendor = table?.estimated == true ? "estimate" : abroad && abroadTimes != nil ? "osrm" : "amap"
            onLine("trip times vendor=\(vendor) pairs=\(table?.pairs ?? 0) ms=\(ms(since: asked))")
            guard let table else { continue }
            if table.estimated { estimated = true }
            for (n, i) in placed.enumerated() where n > 0 { out[d][i].legSeconds = table.time(n - 1, n) }
        }
        return (out, estimated)
    }

    /// §52 item 4: each stop with `placed=false` is searched again, 3 tries 10 s apart; a found one is placed (its
    /// id, role and mark kept). `trip place-retry name=<stop id> try=N ok=yes|no` (the id, not the place text, I-8).
    private func retryUnplaced() {
        guard plan.allStops.contains(where: { !$0.stop.placed }) else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            guard let self else { return }
            for attempt in 1...Self.placeRetries {
                guard await self.retryWait() else { return }
                if await self.retryOnce(attempt) { return }
            }
        }
    }

    static let placeRetries = 3
    private var retryTask: Task<Void, Never>?
    private var planCheckRounds = 0
    /// §52 item 4 (review 2026-11-21): a `set_trip_plan` running. The background retry places
    /// nothing meanwhile (placing raises the revision, which made the running write return OPTIONS_STALE).
    private var planWrites = 0

    /// Tests: waits until the background retries are done.
    func retriesSettled() async { await retryTask?.value }

    private func retryWait() async -> Bool {
        do {
            try await clock.sleep(until: clock.now + tuning.placeRetryGap)
            return !Task.isCancelled
        } catch { return false }
    }

    /// One try over every unplaced stop; true when none is left.
    private func retryOnce(_ attempt: Int) async -> Bool {
        var seen = Set<String>()
        let targets = plan.allStops.map(\.stop).filter { !$0.placed && seen.insert($0.id).inserted }
        guard !targets.isEmpty else { return true }
        guard planWrites == 0 else { return false }
        let lookups = await resolve(targets.map(\.asked), city: plan.abroad ? nil : plan.city, abroad: plan.abroad, near: regionHint())
        guard !Task.isCancelled else { return true }
        guard planWrites == 0 else { return false }
        var any = false
        for (i, stop) in targets.enumerated() {
            var ok = false
            if case .found(let place) = lookups[i], plan.stop(id: stop.id)?.stop.placed == false {
                ok = plan.place(id: stop.id, at: place)
                any = any || ok
            }
            onLine("trip place-retry name=\(stop.id) try=\(attempt) ok=\(ok ? "yes" : "no")")
        }
        if any { changed() }
        return !plan.allStops.contains { !$0.stop.placed }
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
                    choices[k + 1] = found.prefix(3).map {
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
            onLine("trip fit days=\(days.count) pace=\(fit.pace.rawValue) budget=\(budget) required=\(total - pending.filter(\.optional).count) optional=\(optionalCount) kept=\(optionalCount - spare.count) dropped=\(spare.count) over=\(m.filter { $0 > budget }.count) under=\(m.filter { TripChecks.underMinutes($0, budgetMinutes: budget) }.count) max_day=\(m.max() ?? 0) min_day=\(m.min() ?? 0) moves=\(moves) ms=\(ms(since: fitStarted))")
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

    /// §48 item 9: after an edit, the current day over its budget is said; nothing is dropped.
    /// §48: the current day over its budget, as facts (F-09b §13 item 5).
    private func overFacts() -> [String: JSONValue] {
        guard let budget = plan.budgetMinutes else { return [:] }
        let m = Self.dayMinutes(list)
        return m > budget ? ["day_hours": .int(Int64(Self.hours(m))), "day_tight": true] : [:]
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

    // MARK: trip_next (§29)

    private func next(_ args: JSONValue) async -> ToolResult {
        if let day = Self.int(args["day"]) {
            guard plan.select(day) else { return dayOutOfRange() }
            publish()
            persist()
        }
        // §52 item 9 (T-040zc): reads use the plan; an empty day in a plan is a day with nothing left, not no trip.
        guard !plan.isEmpty else { return failure(.noTripList) }
        let target: TripStop
        if let asked = args["stop"]?.stringValue {
            if let n = Int(asked) {
                guard (1...list.count).contains(n) else { return outOfRange() }
                target = list.stops[n - 1]
            } else {
                let found = list.matches(asked)
                guard found.count <= 1 else { return ambiguous(found.map { list.stops[$0 - 1].place.name }) }
                guard let only = found.first else { return failure(.notFound) }
                target = list.stops[only - 1]
            }
        } else if let open = list.stops.first(where: { $0.mark == nil && $0.placed }) {
            target = open
        } else {
            onLine("trip next index=0 day=\(plan.currentDay) ok=no code=DAY_DONE")
            let more = plan.currentDay < plan.dayCount
            // F-09b §13 item 6 (T-031o): the day and the day count are the facts; the next day is offered only if any.
            return ToolReply.failure(.dayDone, facts: ["day": .int(Int64(plan.currentDay)), "day_count": .int(Int64(plan.dayCount))],
                                     may: more ? [.askNextDay] : [], mustNot: [.claimStarted, .invent]).result
        }
        // §52 item 4: a stop not on the map yet has no route.
        guard target.placed else { return failure(.notFound, facts: ["name": .string(target.place.name), "placed": false]) }
        // F-15b §57 item 3 (T-040zj): already guiding to this stop: no new route (a misheard 「停止导航」 restarted it).
        let running = await navigation.current
        if running.navigating, running.destination?.id == target.place.id {
            onLine("trip next index=\(target.index) day=\(plan.currentDay) ok=no code=ALREADY_NAVIGATING")
            return Self.alreadyNavigating(target.place.name)
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
        // F-09b §13 item 5 (T-031n): the stop as facts; the route list stays on screen.
        var facts: [String: JSONValue] = ["started": true, "stop_index": .int(Int64(target.index)),
                                          "name": .string(target.place.name)]
        if let minutes = data["duration_min"] { facts["duration_min"] = minutes }
        data.merge(ToolReply.success(facts: facts, mustNot: [.readRoutes]).result.data) { $1 }
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
        plan.abroad ? plan.allStops.first { $0.stop.placed }?.stop.place.coordinate : nil
    }

    /// §38 item 2 (T-040o), §47 item 6: abroad, a failed route (OSRM) opens Apple Maps to the stop instead. nil when
    /// this does not apply (at home, a refusal that is not a route failure, or no hand-off).
    private func handoff(_ target: TripStop, after result: ToolResult) async -> ToolResult? {
        guard let onHandoff, plan.abroad || !TripRegion.isChina(target.place.countryCode),
              result.code != .optionsNotReady, result.code != .optionsStale, !Task.isCancelled else { return nil }
        guard await onHandoff(target.place) else { return nil }
        onLine("trip handoff vendor=apple_maps reason=route_failed")
        return .success(["status": "apple_maps", "index": .int(Int64(target.index)), "name": .string(target.place.name),
                         "day": .int(Int64(plan.currentDay))].merging(ToolReply.success(
            facts: ["opened_in": "apple_maps", "index": .int(Int64(target.index)), "name": .string(target.place.name),
                    "arrived_command": "已经到了"], may: [.nameCommand]).result.data) { $1 })
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
            let minutes = rest.legSeconds.map { Self.minutesText("\(max(1, ($0 + 59) / 60))") } ?? ""
            note = Self.arrivedNextNote(index: "\(stop.index)", name: stop.place.name, next: rest.place.name, minutes: minutes)
        } else {
            note = stop.role == .hotel
                ? Self.arrivedHotelNote(name: stop.place.name, nextDay: "\(min(day + 1, plan.dayCount))")
                : Self.arrivedDayDoneNote(index: "\(stop.index)", name: stop.place.name)
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
    /// `countryKnown`: the city's country is known (§55 item 2), so §36 item 4's wrong-flag probe is not made (a city in
    /// China never switches the trip abroad).
    private func resolveTrip(_ names: [String], city: String?, abroad asked: Bool,
                             countryKnown: Bool = false) async -> (lookups: [Lookup], abroad: Bool) {
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
            if abroadSearch != nil, !countryKnown, !keyMissing, !names.isEmpty, found(lookups) * 2 < names.count, !Task.isCancelled {
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
    /// most `parallelLookups` at once (`abroadParallelLookups` abroad), each within its own `nameLimit` (§52 item 11);
    /// a lookup still running then is `timeout`. Results
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
                    let one = await fetch([names[missing[done]]], city: nil, search: vendor, guardCountry: guardCountry, near: nil,
                                          parallel: tuning.abroadParallelLookups)
                    fetched += one
                    done += 1
                    if case .candidates(let places) = one[0].0 { near = places.first?.coordinate }
                }
                if done < missing.count {
                    fetched += await fetch(missing[done...].map { names[$0] }, city: nil, search: vendor,
                                           guardCountry: guardCountry, near: near, parallel: tuning.abroadParallelLookups)
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
            onLine("trip pick names=\(open.count) none=0 ok=no reason=nokey ms=0 model=none")
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
            onLine("trip pick names=\(open.count) none=0 ok=no reason=\(reason) ms=\(elapsed) model=\(picker.model)")
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
        onLine("trip pick names=\(open.count) none=\(none) ok=yes ms=\(elapsed) model=\(picker.model)")
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
                       near: GeoCoordinate?, parallel: Int? = nil) async -> [(Lookup, Int)] {
        let limit = max(1, parallel ?? tuning.parallelLookups), clock = clock, retry = tuning.retryDelay, kept = tuning.candidates
        let nameLimit = tuning.nameLimit
        let region = near.map { ($0, tuning.abroadRegionMeters) }
        // §50 item 3: only trip lookups abroad (the country guard on) stay inside the area.
        let inside: AreaCheck? = guardCountry ? area.map { AreaCheck(area: $0, km: tuning.areaKm, limit: tuning.areaLimit) } : nil
        let (stream, feed) = AsyncStream.makeStream(of: (Int, Lookup, Int)?.self)
        let work = Task {
            await withTaskGroup(of: Void.self) { group in
                var next = 0
                func add() {
                    guard next < names.count else { return }
                    let i = next
                    next += 1
                    _ = group.addTaskUnlessCancelled {
                        // §52 item 11: this name's own limit, from when its lookup starts.
                        let (lookup, dropped) = await Self.limited(clock: clock, limit: nameLimit) {
                            await Self.lookup(names[i], city: city, search: search, retryDelay: retry, kept: kept,
                                              guardCountry: guardCountry, region: region, area: inside)
                        }
                        feed.yield((i, lookup, dropped))
                    }
                }
                for _ in 0..<min(limit, names.count) { add() }
                while await group.next() != nil { add() }
            }
            feed.yield(nil)
        }
        var results = [(Lookup, Int)?](repeating: nil, count: names.count)
        for await item in stream {
            guard let (i, lookup, dropped) = item else { break }
            results[i] = (lookup, dropped)
        }
        work.cancel()
        feed.finish()
        return results.map { $0 ?? (.missing("timeout"), 0) }
    }

    /// §52 item 11: one lookup within its own limit; still running then → `timeout` (the lookup is cancelled and not
    /// waited for, so a stalled vendor never holds the batch).
    static func limited(clock: any NovaClock, limit: NovaDuration,
                        _ body: @escaping @Sendable () async -> (Lookup, Int)) async -> (Lookup, Int) {
        let (stream, feed) = AsyncStream.makeStream(of: (Lookup, Int).self)
        let deadline = clock.now + limit
        let work = Task { feed.yield(await body()) }
        let timer = Task {
            try? await clock.sleep(until: deadline)
            if !Task.isCancelled { feed.yield((.missing("timeout"), 0)) }
        }
        var out: (Lookup, Int) = (.missing("timeout"), 0)
        for await r in stream {
            out = r
            break
        }
        work.cancel()
        timer.cancel()
        feed.finish()
        return out
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
            // §52 item 11: `slow` (Photon out of its own tries, ~12 s) is not tried again here.
            guard case .missing(let reason) = result.0, reason != "nomatch", reason != "country", reason != "area",
                  reason != "slow", !Task.isCancelled else { return result }
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
        } catch AmapWebError.slow {
            return (.missing("slow"), 0)
        } catch {
            return (.missing("failed"), 0)
        }
    }


    // MARK: Results

    /// F-09b §13 item 5 (T-031n): `facts` say what changed (plus `count`, `day`, `days`); the cards show the list,
    /// so `must_not` keeps `read_list` unless the driver asked to hear it.
    /// §52 item 11 (T-040zd, review 2026-11-21): a lookup out of tries (`slow`) or still running at its limit
    /// (`timeout`) is `search_slow`, never "not found", on every trip path.
    static func isSlow(_ reason: String) -> Bool { reason == "slow" || reason == "timeout" }

    private func listResult(changed: String?, notFound: [String] = [], duplicates: [String] = [],
                            facts: [String: JSONValue] = [:], may: [ReplyMay] = [],
                            mustNot: [ReplyMustNot] = [.readList],
                            extra: [String: JSONValue] = [:]) -> ToolResult {
        var known = facts
        known["count"] = .int(Int64(list.count))
        if let changed { known["changed"] = .string(changed) }
        if !notFound.isEmpty { known["not_found"] = .array(notFound.map(JSONValue.string)) }
        if !duplicates.isEmpty { known["duplicates"] = .array(duplicates.map(JSONValue.string)) }
        let reply = ToolReply.success(facts: known, may: may, mustNot: mustNot).result.data
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
        ]
        data.merge(reply) { _, new in new }
        if let changed { data["changed"] = .string(changed) }
        data["day"] = .int(Int64(plan.currentDay))
        data["days"] = .int(Int64(plan.dayCount))
        // §48 item 8: the budget, each day's minutes and the spare places of a fitted plan.
        if let budget = plan.budgetMinutes {
            data["budget_minutes"] = .int(Int64(budget))
            data["day_minutes"] = .array(plan.days.map { .int(Int64(Self.dayMinutes($0))) })
            data["spare"] = .array(plan.spare.map { .string($0.place.name) })
        }
        data.merge(extra) { _, new in new }
        return .success(data)
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

    private func failure(_ code: ToolErrorCode, facts: [String: JSONValue] = [:]) -> ToolResult {
        ToolFailureAdvice.reply(code, facts: facts)
    }

    /// F-09b §13 item 6 (T-031o): AMBIGUOUS with the matching names as facts.
    private func ambiguous(_ names: [String]) -> ToolResult {
        failure(.ambiguous, facts: ["names": .array(names.map(JSONValue.string))])
    }

    private func tripTooLong() -> ToolResult { failure(.tripTooLong, facts: ["max_stops": .int(Int64(TripList.maxStops))]) }

    private func outOfRange() -> ToolResult {
        // F-09b §13 item 4 (T-031m): choosing; what is on the list, and she may ask which.
        ToolReply.choosing(.outOfRange, onScreen: list.count, names: list.stops.map(\.place.name),
                           facts: ["list": "trip"], mustNot: [.readList]).result
    }

    /// §54 item 3.2: `place` is in another country group than every kept place (China = CN/HK/MO/TW), or farther than
    /// `kilometres` from each of them.
    /// `kilometres` nil (a trip at home, whose lookups have no area): the country group only.
    static func isForeign(_ place: Place, kept: [Place], kilometres: Double?) -> Bool {
        func group(_ code: String?) -> String { TripRegion.isChina(code) ? "CN" : (code ?? "").uppercased() }
        guard kept.contains(where: { group($0.countryCode) == group(place.countryCode) }) else { return true }
        guard let kilometres else { return false }
        return kept.allSatisfy { SelfPosition.distanceMeters($0.coordinate, place.coordinate) > kilometres * 1000 }
    }

    private func distance(_ here: GeoCoordinate?, _ place: Place) -> Int? {
        here.map { Int(SelfPosition.distanceMeters($0, place.coordinate).rounded()) }
    }

    private func changed() {
        applyKnownPhotos()
        publish()
        persist()
        photos()
    }

    private func dayOutOfRange() -> ToolResult {
        ToolReply.choosing(.outOfRange, onScreen: plan.dayCount, facts: ["list": "days"]).result
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
            guard exists || saved.entries.count < SavedTripPlans.maxPlans else {
                return failure(.plansFull, facts: ["max_plans": .int(Int64(SavedTripPlans.maxPlans))])
            }
            let replaced = saved.save(plan, as: name, at: now())
            plan.name = name
            persist()
            persistSaved()
            return .success(["status": "plan_saved", "name": .string(name), "replaced": .bool(replaced),
                             "days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)),
                             ].merging(Self.said(["saved_as": .string(name), "replaced": .bool(replaced)])) { $1 })
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
                             ].merging(Self.said(["count": .int(Int64(saved.entries.count)),
                                                  "names": .array(saved.entries.map { .string($0.name) })],
                                                 may: saved.entries.isEmpty ? [] : [.readListInOrder], mustNot: [])) { $1 })
        case "delete":
            switch find(name) {
            case .success(let i):
                let gone = saved.entries[i].name
                saved.delete(at: i)
                persistSaved()
                return .success(["status": "plan_deleted", "name": .string(gone)]
                    .merging(Self.said(["deleted": .string(gone)])) { $1 })
            case .failure(let box): return box.result
            }
        case "rename":
            let newName = args["new_name"]?.stringValue.map(TranscriptText.normalize) ?? ""
            switch find(name) {
            case .success(let i):
                let old = saved.entries[i].name
                if let other = saved.entries.firstIndex(where: { TranscriptText.normalize($0.name) == newName }), other != i {
                    return ToolReply.notDone(.invalidFields, facts: ["renamed": false, "name_taken": .string(newName)],
                                             may: [.askWhat]).result
                }
                saved.rename(at: i, to: newName)
                if plan.name == old { plan.name = newName; persist() }
                persistSaved()
                return .success(["status": "plan_renamed", "name": .string(newName)]
                    .merging(Self.said(["renamed_to": .string(newName)])) { $1 })
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
        var facts: [String: JSONValue] = ["opened": .string(name), "days": .int(Int64(plan.dayCount)),
                                          "stops": .int(Int64(plan.stopCount)), "next_stop_command": "去下一站"]
        if kept { facts["previous_kept_as"] = .string(SavedTripPlans.previousName) }
        return .success(["status": "plan_opened", "name": .string(name), "kept_previous": .bool(kept),
                         "days": .int(Int64(plan.dayCount)), "stops": .int(Int64(plan.stopCount)), "plan": TripPlanJSON.value(plan),
                         ].merging(Self.said(facts, may: [.nameCommand])) { $1 })
    }

    // MARK: Screen taps (§13)

    /// §13 item 1 (I-6): the tap becomes the tool call of the voice path, through the same validation and executor.
    /// While moving it is refused with `NOT_WHILE_MOVING` and changes nothing. `note` is the §13 item 4 silent note
    /// for a connected session, nil when nothing changed.
    public func tap(_ tap: TripTap, moving: Bool) async -> (result: ToolResult, note: String?) {
        // §52 item 9 (T-040zc): a day tap only changes the day in front; not a tool call, it cannot fail.
        if case .day(let day) = tap { return (viewDay(day), nil) }
        let result: ToolResult
        if moving {
            result = failure(.notWhileMoving)
        } else {
            switch tap {
            case .remove(let index):
                result = cardsHidden ? Self.tripHiddenResult : screenRemove(index)
            case .move(let from, let to):
                result = cardsHidden ? Self.tripHiddenResult : screenMove(from, to)
            case .next:
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_next", arguments: [:]))
            case .day(let day):
                result = viewDay(day)
            case .openPlan(let name):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_plans",
                                                arguments: ["action": "open", "name": .string(name)]))
            case .deletePlan(let name):
                result = await execute(ToolCall(id: CallID("ui-trip")!, name: "trip_plans",
                                                arguments: ["action": "delete", "name": .string(name)]))
            case .add(let place):
                // §51 item 2: an add while the cards are hidden is refused (the screen's 加入清单).
                if cardsHidden {
                    onLine("trip blocked tool=tap_add reason=hidden")
                    result = Self.tripHiddenResult
                } else {
                    result = add(place)
                }
            }
        }
        onLine("trip tap action=\(tap.action) ok=\(result.ok ? "yes" : "no")")
        // F-15b §57 items 5–6 (T-040zj): a tap on 「去下一站」 reaches her as one line, whatever its result.
        if case .next = tap {
            onLine("nav tap action=next")
            return (result, Self.nextTapLine)
        }
        guard result.ok else { return (result, nil) }
        let what: String
        switch tap {
        case .day, .deletePlan:
            // Only the screen changed (a day tab, a saved plan gone): no note.
            return (result, nil)
        case .openPlan(let name): what = Self.editOpened(result.data["name"]?.stringValue ?? name)
        case .remove(let index): what = Self.editRemoved("\(index)", Self.removedName(result) ?? "")
        case .move(let from, let to): what = Self.editMoved("\(from)", "\(to)")
        case .next: return (result, Self.nextTapLine)
        case .add(let place):
            // An already listed place changed nothing: no note.
            if result.data["changed"] == "none" { return (result, nil) }
            what = Self.editAdded(place.name)
        }
        return (result, Self.screenEditNote(what: what, count: "\(list.count)"))
    }

    // F-09b §15 item 1 (T-031y): the note templates, so `AgentSetup` can list them with placeholders.
    public static func arrivedNextNote(index: String, name: String, next: String, minutes: String) -> String {
        "[系统] 已到达第\(index)站\(name)。下一站是\(next)\(minutes)。问司机要不要现在去下一站。"
    }
    public static func arrivedHotelNote(name: String, nextDay: String) -> String {
        "[系统] 已到达酒店\(name)，今天的行程结束了。用一句话告诉司机，明天说「开始第\(nextDay)天」。"
    }
    public static func arrivedDayDoneNote(index: String, name: String) -> String {
        "[系统] 已到达第\(index)站\(name)。这一天的地点都去完了。问司机要不要开始下一天。"
    }
    public static func minutesText(_ minutes: String) -> String { "，约\(minutes)分钟" }
    public static func editOpened(_ name: String) -> String { "打开了行程「\(name)」" }
    public static func editRemoved(_ index: String, _ name: String) -> String { "去掉了第\(index)个：\(name)" }
    public static func editMoved(_ from: String, _ to: String) -> String { "把第\(from)个移到了第\(to)个" }
    /// F-15b §57 item 5 (T-040zj): the line she gets for a tap on 「去下一站」 (queued like the screen line).
    public static let nextTapLine = "[系统] 司机点了「去下一站」。这句不用回答。"
    /// §57 item 3: the `next` of `ALREADY_NAVIGATING`, exactly as §57 gives it.
    public static func alreadyNavigatingNext(_ name: String) -> String {
        "已经在去\(name)的路上了。司机要是想停，调用 exit_navigation_mode。"
    }
    static func alreadyNavigating(_ name: String) -> ToolResult {
        var data = ToolFailureAdvice.reply(.alreadyNavigating, facts: ["name": .string(name), "navigating": true]).data
        data["next"] = .string(alreadyNavigatingNext(name))
        return ToolResult(ok: false, code: .alreadyNavigating, data: data, advice: nil)
    }
    public static func editAdded(_ name: String) -> String { "加入了\(name)" }
    public static func screenEditNote(what: String, count: String) -> String {
        "[系统] 司机在屏幕上\(what)，现在清单有\(count)个地点。这句不用回答。"
    }

    /// §13 item 3: an already-found place added at the end, with no new lookup.
    /// §52 item 9 (T-040zc): the day in front becomes `day` (clamped to the plan's days); hidden cards are shown
    /// (the 「行程」 button). No plan change, no revision: a running change is not made stale by a look at another day.
    /// `trip day-view day=N`.
    private func viewDay(_ day: Int) -> ToolResult {
        let shown = min(max(day, 1), plan.dayCount)
        plan.show(shown)
        setHidden(false)
        onLine("trip day-view day=\(shown)")
        publish()
        onPlans(TripPlansSummary(plan, saved))
        return .success(["status": "trip_day", "day": .int(Int64(shown)), "days": .int(Int64(plan.dayCount))])
    }

    /// §13 (screen taps): the driver's own remove of stop `index` of the day in front. §52 item 14 removed the voice
    /// action; the tap stays.
    private func screenRemove(_ index: Int) -> ToolResult {
        guard (1...max(list.count, 1)).contains(index), index <= list.count else { return outOfRange() }
        let removed = list.stops[index - 1].place.name
        list.remove(at: index)
        changed()
        return listResult(changed: "removed", facts: overFacts().merging(["removed": .string(removed)]) { $1 },
                          extra: ["removed": .string(removed)])
    }

    /// §13: the driver's own drag of a stop within the day in front.
    private func screenMove(_ from: Int, _ to: Int) -> ToolResult {
        let n = list.count
        guard (1...max(n, 1)).contains(from), (1...max(n, 1)).contains(to), from <= n, to <= n else { return outOfRange() }
        let moved = list.stops[from - 1].place.name
        list.move(from: from, to: to)
        changed()
        return listResult(changed: "moved", facts: ["name": .string(moved), "to_index": .int(Int64(to))])
    }

    private func add(_ place: Place) -> ToolResult {
        guard list.count < TripList.maxStops else { return tripTooLong() }
        if list.contains(placeID: place.id) {
            return listResult(changed: "none", duplicates: [place.name], facts: ["already_in_list": .string(place.name)])
        }
        list.insert(TripStop(index: 0, asked: place.name, place: place, distanceMeters: place.distanceMeters, pickedBy: .driver))
        changed()
        return listResult(changed: "added", facts: ["name": .string(place.name)])
    }

    /// F-09b §13 item 5 (T-031n): a saved-plan success as facts and rules (`facts`, `may`, `must_not`, `next`).
    private static func said(_ facts: [String: JSONValue], may: [ReplyMay] = [],
                             mustNot: [ReplyMustNot] = [.readList]) -> [String: JSONValue] {
        ToolReply.success(facts: facts, may: may, mustNot: mustNot).result.data
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
        publish()
    }

    /// Tests: the photo lookups of the last change have finished.
    public func photosSettled() async { await photoTask?.value }

    private func ms(since: NovaInstant) -> Int64 { max(0, (clock.now - since).milliseconds) }

    private static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let v): Int(v)
        case .double(let v): Int(exactly: v)
        default: nil
        }
    }
}
