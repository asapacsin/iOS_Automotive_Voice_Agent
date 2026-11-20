import NovaKit
import NovaPorts

/// F-15b §51 item 8 (T-040z): where `navigate_to` is centred, as the model names it. Code resolves it to
/// coordinates and checks it; it never picks the centre itself.
public enum NearKind: String, Sendable, Hashable, CaseIterable {
    case here, place, trip, route
}

extension String {
    /// nil when empty.
    var nonEmpty: String? { isEmpty ? nil : self }
}

/// One stop of the shown plan, as `near=trip` matches it.
public struct NearTripStop: Sendable, Hashable {
    public let day: Int
    public let name: String
    /// What the driver or the model called it when it was added.
    public let asked: String
    public let role: TripRole
    public let coordinate: GeoCoordinate
    public let countryCode: String?

    public init(day: Int, name: String, asked: String, role: TripRole, coordinate: GeoCoordinate, countryCode: String?) {
        self.day = day
        self.name = name
        self.asked = asked
        self.role = role
        self.coordinate = coordinate
        self.countryCode = countryCode?.uppercased()
    }
}

/// The plan as `navigate_to` may see it: `near=trip` (its stops) and
/// §51 item 9 (T-040za) `near=here` while shown (`next`).
public struct NearTrip: Sendable, Hashable {
    public let hidden: Bool
    public let abroad: Bool
    public let city: String?
    public let stops: [NearTripStop]
    /// §51 item 9: the trip's next stop: the first stop of the current day not yet marked (as `trip_next`, §29); none
    /// left, the first stop of the plan. nil only without stops.
    public let next: NearTripStop?

    public init(hidden: Bool, abroad: Bool, city: String?, stops: [NearTripStop], next: NearTripStop? = nil) {
        self.hidden = hidden
        self.abroad = abroad
        self.city = city
        self.stops = stops
        self.next = next ?? stops.first
    }

    /// §51 item 8 `trip`: `near_name` against the stops: the name contains a stop's name (or the stop's name contains
    /// it), else a day and a role said in it (「第一天的酒店」 → day 1 `role=hotel`). A day narrows name matches.
    public func match(_ said: String) -> [NearTripStop] {
        let text = said.trimmingCharacters(in: .whitespaces)
        let day = Self.day(in: text)
        let role = Self.role(in: text)
        let byName = stops.filter { stop in
            !text.isEmpty && ((!stop.name.isEmpty && (text.contains(stop.name) || stop.name.contains(text)))
                || (!stop.asked.isEmpty && (text.contains(stop.asked) || stop.asked.contains(text))))
        }
        if !byName.isEmpty {
            let onDay = day.map { d in byName.filter { $0.day == d } } ?? byName
            return Self.unique(onDay.isEmpty ? byName : onDay)
        }
        guard day != nil || role != nil else { return [] }
        return Self.unique(stops.filter { (day == nil || $0.day == day) && (role == nil || $0.role == role) })
    }

    private static func unique(_ stops: [NearTripStop]) -> [NearTripStop] {
        var out: [NearTripStop] = []
        for s in stops where !out.contains(where: { $0.name == s.name && $0.coordinate == s.coordinate }) { out.append(s) }
        return out
    }

    private static let numerals: [Character: Int] = ["一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5,
                                                     "1": 1, "2": 2, "3": 3, "4": 4, "5": 5]

    /// 「第一天」「第2天」「day 1」; nil when no day is said.
    static func day(in text: String) -> Int? {
        let chars = Array(text)
        for i in chars.indices where chars[i] == "第" && i + 2 < chars.count {
            if chars[i + 2] == "天", let d = numerals[chars[i + 1]] { return d }
        }
        let lower = text.lowercased()
        if let r = lower.range(of: "day ") ?? lower.range(of: "day"), let c = lower[r.upperBound...].first, let d = numerals[c] {
            return d
        }
        return nil
    }

    /// The stop's role said in words; nil when none is.
    static func role(in text: String) -> TripRole? {
        let lower = text.lowercased()
        if ["还车"].contains(where: lower.contains) { return .rentalReturn }
        if ["取车", "租车"].contains(where: lower.contains) { return .rentalPickup }
        if ["酒店", "住的地方", "住处", "宾馆", "旅馆", "hotel"].contains(where: lower.contains) { return .hotel }
        if ["起点", "出发"].contains(where: lower.contains) { return .start }
        if ["终点"].contains(where: lower.contains) { return .end }
        return nil
    }
}
