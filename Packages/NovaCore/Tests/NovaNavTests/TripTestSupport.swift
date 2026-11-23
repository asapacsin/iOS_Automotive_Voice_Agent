import Synchronization
import Testing
@testable import NovaKit
@testable import NovaNav
@testable import NovaPorts
@testable import NovaTools

// Shared trip test helpers (moved from TripGroundTests and TripReviseTests when §55, T-040zh, removed make_trip_list).

/// §50 item 1 stand-in for Qwen `ground`: a fixed answer, an error, or never answering.
final class FakeGrounder: TripGrounder, @unchecked Sendable {
    let answer: TripGroundAnswer?
    let error: TripGroundError?
    let hang: Bool
    let calls = Mutex<[TripGroundRequest]>([])
    init(_ answer: TripGroundAnswer? = nil, error: TripGroundError? = nil, hang: Bool = false) {
        self.answer = answer
        self.error = error
        self.hang = hang
    }
    func ground(_ request: TripGroundRequest) async throws -> TripGroundAnswer {
        calls.withLock { $0.append(request) }
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if let error { throw error }
        return answer!
    }
}

/// §50 item 3 stand-in for Photon with `bbox`: each asked name answers the table entry whose key it contains (longest
/// key first); 「酒店」 around a point answers `hotels`. Boxes and limits asked are recorded.
final class FakeAreaSearch: AreaPlaceSearch, @unchecked Sendable {
    let table: [String: [Place]]
    let hotels: @Sendable (GeoCoordinate) -> [Place]
    let boxes = Mutex<[(GeoBox, Int)]>([])
    init(_ table: [String: [Place]], hotels: @escaping @Sendable (GeoCoordinate) -> [Place] = { [hotelAt($0, country: "JP")] }) {
        self.table = table
        self.hotels = hotels
    }
    private func find(_ keywords: String) -> [Place] {
        table.keys.sorted { $0.count > $1.count }.first { keywords.contains($0) }.flatMap { table[$0] } ?? []
    }
    func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place] {
        boxes.withLock { $0.append((box, limit)) }
        return Array(find(keywords).prefix(limit))
    }
    func text(_ keywords: String, city: String?) async throws -> [Place] { find(keywords) }
    func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        keywords == "酒店" ? hotels(center) : find(keywords)
    }
    func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    func detail(id: String) async throws -> Place? { nil }
}

/// §49 (T-040u) with §52 (T-040zb): a `trip_needs_fix` answered as a model that changes nothing would (the same plan
/// written back by id with `set_trip_plan`), until the normal `trip_list` comes back (at most 2 rounds). For tests of
/// earlier sections whose plans now fail a check.
/// F-15b §61 (T-040zn): there are no rounds any more; the first result is the result.
func settle(_ rig: TripRig, _ first: ToolResult) async -> ToolResult { first }

/// The current plan written back unchanged, every stop by id.
func sameCall(_ rig: TripRig) async -> ToolCall { await sameCall(rig.planner) }

func sameCall(_ planner: TripPlanner) async -> ToolCall {
    let plan = await planner.currentPlan
    let d: [JSONValue] = plan.days.map { day in .array(day.stops.map { .object(["id": .string($0.id)]) }) }
    return trip("set_trip_plan", ["days": .array(d)])
}

/// §55 (T-040zh): a new plan written whole with `set_trip_plan`, from the fields older tests gave `make_trip_list`:
/// `places` (one day) or `days`, `start`/`end` (the first and last stop), `hotels` (one for every night, or one per
/// night), `city` (default 天津; 「Tokyo, Japan」 for `abroad`), `pace` and `optimise`. Code never splits days.
func planCall(_ args: [String: JSONValue]) -> ToolCall {
    func stops(_ v: JSONValue?) -> [JSONValue] {
        guard case .array(let a)? = v else { return [] }
        return a.map { $0.stringValue.map { .object(["name": .string($0)]) } ?? $0 }
    }
    var days: [[JSONValue]] = if case .array(let d)? = args["days"] { d.map { stops($0) } } else { [stops(args["places"])] }
    let hotels: [String] = if case .array(let h)? = args["hotels"] { h.compactMap(\.stringValue) } else { [] }
    for night in 0..<max(days.count - 1, 0) where !hotels.isEmpty {
        let name = hotels.count == 1 ? hotels[0] : (night < hotels.count ? hotels[night] : nil)
        guard let name else { continue }
        let hotel: JSONValue = ["name": .string(name), "role": "hotel"]
        days[night].append(hotel)
        days[night + 1].insert(hotel, at: 0)
    }
    if let start = args["start"]?.stringValue { days[0].insert(["name": .string(start), "role": "start"], at: 0) }
    if let end = args["end"]?.stringValue { days[days.count - 1].append(["name": .string(end), "role": "end"]) }
    let abroad = args["abroad"]?.boolValue ?? false
    var out: [String: JSONValue] = ["days": .array(days.map { .array($0) }),
                                    "city": args["city"] ?? .string(abroad ? "Tokyo, Japan" : "天津")]
    for k in ["pace", "optimise"] { if let v = args[k] { out[k] = v } }
    return trip("set_trip_plan", out)
}

/// §52 item 13: the whole plan cleared (`set_trip_plan` with no stops; `edit_trip_list clear` is removed, §55 item 11).
func clearCall() -> ToolCall { trip("set_trip_plan", ["days": [[]]]) }
