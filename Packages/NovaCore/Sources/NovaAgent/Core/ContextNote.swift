import Foundation
import NovaKit
import NovaNav
import NovaPorts

/// F-09b §14 item 1 (T-031p): the place the `现在` note names: city and district from the reverse geocode, and the
/// trip location's name while the trip cards are shown (F-15b §51 item 9).
public struct ContextPlace: Sendable, Hashable {
    public let city: String?
    public let district: String?
    /// The trip location (next stop or 「模拟车」); nil when the place is the phone's.
    public let trip: String?

    public init(city: String?, district: String?, trip: String? = nil) {
        self.city = city?.isEmpty == true ? nil : city
        self.district = district?.isEmpty == true ? nil : district
        self.trip = trip?.isEmpty == true ? nil : trip
    }

    /// The place from a center and its regeo address. The city is cut from the formatted address: the text before
    /// the district, without the province (「广东省珠海市香洲区…」 → 珠海市; 「北京市朝阳区…」 → 北京市).
    public init(center: ContextCenter, address: PlaceAddress?) {
        self.init(city: address.flatMap { Self.city(formatted: $0.formatted, district: $0.district) },
                  district: address?.district, trip: center.trip)
    }

    public static func city(formatted: String, district: String?) -> String? {
        var head = formatted
        if let district, !district.isEmpty, let r = formatted.range(of: district) { head = String(formatted[..<r.lowerBound]) }
        for end in ["自治区", "特别行政区", "省"] {
            if let r = head.range(of: end) {
                // A special administrative region is the city itself (澳门特别行政区).
                if end == "特别行政区" { return String(head[..<r.upperBound]) }
                head = String(head[r.upperBound...])
                break
            }
        }
        for end in ["自治州", "地区", "市", "州", "盟"] {
            if let r = head.range(of: end) { return String(head[..<r.upperBound]) }
        }
        return head.isEmpty || district == nil ? nil : head
    }

    var text: String {
        let area = [city, district].compactMap { $0 }.joined()
        if let trip { return "行程位置（\(trip)）" + (area.isEmpty ? "" : "，\(area)") }
        return area.isEmpty ? "不知道" : area
    }
}

/// F-09b §14 item 1 (T-031p): the facts of the `[系统] 现在` note. `localTime` is the text of the local date and
/// time at the moment the app made the snapshot; it is sent with the note but is no reason for one. What the screen
/// shows (navigating, the trip) is the `屏幕` line's (F-09b §16 item 4, T-031z), not this note's.
public struct ContextSnapshot: Sendable, Hashable {
    public var place: ContextPlace?
    /// From the route when known; nil leaves the field out.
    public var onHighway: Bool?
    public var localTime: String
    /// F-15b §52 item 2 (T-040zb): the trip line, the whole plan (`TripPlanJSON.noteLine`); nil without a plan.
    public var tripPlan: String?
    /// F-18 §37 item 2 (T-046z): 「后台在查：活动（已过40秒）」, 「后台在查：行程」 per running background job; set by the
    /// agent when the note is sent, never part of `key`.
    public var running: [String] = []

    public init(place: ContextPlace?, onHighway: Bool?, localTime: String, tripPlan: String? = nil) {
        self.place = place
        self.onHighway = onHighway
        self.localTime = localTime
        self.tripPlan = tripPlan
    }

    /// The local date and time as the note says it (「11月20日 星期五 14:05」).
    public static func localTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.month, .day, .weekday, .hour, .minute], from: date)
        let week = ["日", "一", "二", "三", "四", "五", "六"][((c.weekday ?? 1) - 1) % 7]
        return "\(c.month ?? 0)月\(c.day ?? 0)日 星期\(week) " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// What a change is measured on: everything but the time (a minute passing, or a GPS fix in the same district,
    /// is no change).
    var key: ContextSnapshot { var k = self; k.localTime = ""; k.running = []; return k }

    /// Item 8: the field names the note carries (no values, I-8).
    public var fields: [ContextNoteField] {
        [.place] + (onHighway == nil ? [] : [.highway]) + [.time] + (tripPlan == nil ? [] : [.trip])
    }

    /// Item 1, exact form.
    public var note: String {
        var parts = ["位置：\(place?.text ?? "不知道")"]
        if let onHighway { parts.append(onHighway ? "在高速上" : "不在高速上") }
        parts.append("当地时间 \(localTime)")
        if let tripPlan { parts.append(tripPlan) }
        parts += running
        return "[系统] 现在：" + parts.joined(separator: "；") + "。这句不用回答。"
    }
}

/// F-09b §14 item 1 (T-031p): when the app looks the place up again. A new lookup only when the center moved
/// `moveMeters` or the trip location changed; otherwise the last place is kept (a GPS fix is no lookup).
public struct ContextPlaceTracker: Sendable {
    public static let moveMeters = 500.0
    private var last: (center: ContextCenter, place: ContextPlace?)?

    public init() {}

    /// The place for `center` if it is still the last one; nil when a lookup is needed.
    public func known(_ center: ContextCenter) -> ContextPlace?? {
        guard let last, last.center.trip == center.trip,
              SelfPosition.distanceMeters(last.center.coordinate, center.coordinate) < Self.moveMeters else { return nil }
        return .some(last.place)
    }

    public mutating func looked(_ center: ContextCenter, _ place: ContextPlace?) { last = (center, place) }
}
