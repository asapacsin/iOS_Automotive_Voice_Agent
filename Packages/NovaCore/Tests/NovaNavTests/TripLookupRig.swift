import Foundation
import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

/// Shared rig of the F-15b §67–§69 tests (T-040zt, T-040zu, T-040zv): a scripted planner model and a 高德 stand-in that
/// records every request (keywords, city, city limit, when) and answers from a table or a scripted error.

/// A planner model with scripted answers, one per call. `gate` (when set) holds each call until released.
final class ScriptPlanner: TripPlannerModel, @unchecked Sendable {
    /// `stubborn`: ignores cancellation for that long (a call that is slow to wind down), then fails.
    enum Answer { case text(String), hang, stubborn(Duration) }
    let answers: Mutex<[Answer]>
    let calls = Mutex<[[TripPlannerMessage]]>([])
    let cancelled = Mutex(0)
    init(_ answers: [Answer]) { self.answers = Mutex(answers) }
    var model: String { "script-planner" }
    func complete(system: String, messages: [TripPlannerMessage]) async throws -> String {
        calls.withLock { $0.append(messages) }
        let next = answers.withLock { a -> Answer in a.isEmpty ? .hang : a.removeFirst() }
        switch next {
        case .text(let t): return t
        case .stubborn(let d):
            await Task.detached { try? await Task.sleep(for: d) }.value
            cancelled.withLock { $0 += 1 }
            throw CancellationError()
        case .hang:
            do { try await Task.sleep(for: .seconds(3600)) } catch {
                cancelled.withLock { $0 += 1 }
                throw CancellationError()
            }
            throw CancellationError()
        }
    }
    var count: Int { calls.withLock { $0.count } }
}

/// One 高德 request as the trip planner sent it.
struct LookupRequest: Sendable, Hashable {
    let keywords: String
    let city: String?
    let cityLimit: Bool
    let at: ContinuousClock.Instant
}

/// 高德 stand-in: answers `city|name`, else `name`; `errors[name]` throws (one per request, then the table).
final class AmapLookupSearch: PlaceInfoSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let errors: Mutex<[String: [any Error]]>
    let requests = Mutex<[LookupRequest]>([])
    init(_ table: [String: [Place]], errors: [String: [any Error]] = [:]) {
        self.table = table
        self.errors = Mutex(errors)
    }
    func textInfo(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        requests.withLock { $0.append(LookupRequest(keywords: keywords, city: city, cityLimit: cityLimit, at: .now)) }
        let failure = errors.withLock { e -> (any Error)? in
            guard var list = e[keywords], !list.isEmpty else { return nil }
            let first = list.removeFirst()
            e[keywords] = list
            return first
        }
        if let failure { throw failure }
        return table["\(city ?? "-")|\(keywords)"] ?? table[keywords] ?? []
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] {
        try await textInfo(keywords, city: city, cityLimit: false)
    }
    func text(_ keywords: String, city: String?, cityLimit: Bool) async throws -> [Place] {
        try await textInfo(keywords, city: city, cityLimit: cityLimit)
    }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] { [] }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
    var asked: [String] { requests.withLock { $0.map(\.keywords) } }
}

func mapPlace(_ name: String, _ lat: Double, city: String, adcode: String? = nil) -> Place {
    Place(id: name, name: name, address: nil, coordinate: GeoCoordinate(latitude: lat, longitude: 113.5, datum: .gcj02),
          distanceMeters: nil, city: city, district: nil, adcode: adcode)
}

struct LookupRig {
    let planner: TripPlanner
    let model: ScriptPlanner
    let search: AmapLookupSearch
    let lines = TripLines()
    let clock = ManualClock()
    init(_ answers: [ScriptPlanner.Answer], search: AmapLookupSearch, tuning: TripTuning = TripTuning()) async {
        let lines = self.lines
        self.search = search
        let model = ScriptPlanner(answers)
        self.model = model
        let nav = NavigationController(search: search, engine: ScriptedNaviEngine(routes: [route(1, meters: 9_000, seconds: 900)]),
                                       location: NoLocation(), clock: clock, onTripLine: { lines.append($0) })
        await nav.start()
        planner = TripPlanner(search: search, navigation: nav, origin: { GeoCoordinate(latitude: 22.27, longitude: 113.5, datum: .gcj02) },
                              clock: clock, tuning: tuning, onLine: { lines.append($0) }, plannerModel: model)
        await planner.connectCards()
    }
    func run(_ call: ToolCall) async -> ToolResult { await planner.execute(call) }
    func line(_ prefix: String) -> [String] { lines.withLock { $0 }.filter { $0.hasPrefix(prefix) } }
}

/// One planner answer: days of sights given as JSON objects, no stays, `done`.
func plannerAnswer(_ days: [[JSONValue]], done: Bool = true, note: String = "") -> ScriptPlanner.Answer {
    .text(TripPlanJSON.text(.object([
        "days": .array(days.map { .object(["sights": .array($0), "stay": .null]) }),
        "done": .bool(done), "note": .string(note),
    ])))
}

func planCall(_ text: String = "珠海一天", days: Int = 1, city: String = "珠海", id: String = "plan") -> ToolCall {
    ToolCall(id: CallID(id)!, name: "plan_trip", arguments: ["asked": ["text": .string(text), "days": .int(Int64(days)), "city": .string(city)]])
}
