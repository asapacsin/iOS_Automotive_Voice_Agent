import Foundation

/// F-15b §49 item 4 (T-040u): the checks code runs after every fit. Pure. Each is pass or fail; a failure carries one
/// line for the model, and all failed lines go back together (LLM-Modulo, Gundawar et al. 2024: binary critics whose
/// back-prompts a metacontroller concatenates for the LLM to revise).
public enum TripChecks {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case notFound = "not_found", over, driving, under, hotel
    }

    public struct Issue: Sendable, Hashable {
        public let kind: Kind
        public let line: String
    }

    /// One fitted day: its minutes (drives plus visits), the driving among them, whether its sights are all must-sees
    /// (importance 3), and the area to add places in (a district, else a place name).
    public struct Day: Sendable, Hashable {
        public let minutes: Int
        public let drivingMinutes: Int
        public let onlyMustSee: Bool
        public let area: String?
        public init(minutes: Int, drivingMinutes: Int, onlyMustSee: Bool, area: String?) {
            self.minutes = minutes
            self.drivingMinutes = drivingMinutes
            self.onlyMustSee = onlyMustSee
            self.area = area
        }
    }

    /// §49 item 4 `hotel`: a hotel found for a night, with its distance to that day's last place.
    public struct HotelChoice: Sendable, Hashable {
        public let name: String
        public let meters: Int
        public init(name: String, meters: Int) {
            self.name = name
            self.meters = meters
        }
    }

    /// §49 item 4 `driving`: a day whose driving is more than this share of its cost.
    public static let drivingShare = 0.4
    /// §49 item 4 `hotel`: up to this many hotels per night.
    public static let hotelChoices = 3

    /// The failed checks in the order of §49 item 4. `hotels` maps a 1-based night to its choices (only given when
    /// the driver has wishes and the model has not picked that night's hotel yet).
    public static func run(notFound: [String], days: [Day], budgetMinutes: Int, spareEmpty: Bool,
                           hotels: [Int: [HotelChoice]] = [:]) -> [Issue] {
        var out: [Issue] = []
        for name in notFound { out.append(Issue(kind: .notFound, line: "\(name)没找到，换一个附近类似的或者去掉")) }
        for (d, day) in days.enumerated() where day.minutes > budgetMinutes && day.onlyMustSee {
            out.append(Issue(kind: .over, line: "第\(d + 1)天超了约\(hours(day.minutes - budgetMinutes))小时，减少或换掉一个必去的地方"))
        }
        for (d, day) in days.enumerated() where day.minutes > 0 && Double(day.drivingMinutes) > drivingShare * Double(day.minutes) {
            out.append(Issue(kind: .driving, line: "第\(d + 1)天大半时间在开车，考虑把这天换到一个区域"))
        }
        if spareEmpty {
            for (d, day) in days.enumerated() where day.minutes * 2 < budgetMinutes {
                let area = day.area.map { "在\($0)附近" } ?? ""
                out.append(Issue(kind: .under, line: "第\(d + 1)天还空约\(hours(budgetMinutes - day.minutes))小时，\(area)加1到2个"))
            }
        }
        for night in hotels.keys.sorted() {
            let list = (hotels[night] ?? []).prefix(hotelChoices)
            guard !list.isEmpty else { continue }
            let named = list.map { "\($0.name)（\(km($0.meters))公里）" }.joined(separator: "、")
            out.append(Issue(kind: .hotel, line: "第\(night)晚从这几个里挑一个：\(named)"))
        }
        return out
    }

    /// Hours, rounded, at least 1.
    static func hours(_ minutes: Int) -> Int { max(1, Int((Double(minutes) / 60).rounded())) }

    /// Kilometres with one decimal.
    static func km(_ meters: Int) -> String { String(format: "%.1f", Double(meters) / 1000) }
}
