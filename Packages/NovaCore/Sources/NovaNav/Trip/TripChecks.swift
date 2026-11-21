import Foundation

/// F-15b §49 item 4 (T-040u): the checks code runs after every fit. Pure. Each is pass or fail; a failure carries one
/// line for the model, and all failed lines go back together (LLM-Modulo, Gundawar et al. 2024: binary critics whose
/// back-prompts a metacontroller concatenates for the LLM to revise).
public enum TripChecks {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case notFound = "not_found", over, driving, under, hotel, far
    }

    public struct Issue: Sendable, Hashable {
        public let kind: Kind
        public let line: String
    }

    /// One fitted day: its minutes (drives plus visits), the driving among them, whether its sights are all must-sees
    /// (importance 3), the area to add places in (a district, else a place name), and (§53 item 3, T-040zf) its
    /// number of sights and its longest sight's visit minutes (nil: not known, the sight-count part is skipped).
    public struct Day: Sendable, Hashable {
        public let minutes: Int
        public let drivingMinutes: Int
        public let onlyMustSee: Bool
        public let area: String?
        public let sights: Int?
        public let longestSightMinutes: Int
        public init(minutes: Int, drivingMinutes: Int, onlyMustSee: Bool, area: String?, sights: Int? = nil,
                    longestSightMinutes: Int = 0) {
            self.minutes = minutes
            self.drivingMinutes = drivingMinutes
            self.onlyMustSee = onlyMustSee
            self.area = area
            self.sights = sights
            self.longestSightMinutes = longestSightMinutes
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
    /// F-15b §53 item 3 (T-040zf): a day under this share of its budget is thin. No published threshold (TripScore and
    /// TravelAgent score day density without one); a named constant so it can be tuned.
    public static let thinShare = 0.75
    /// §53 item 3: a day with fewer sights is thin while this many minutes of its budget are left (room for one more).
    public static let roomForOneMinutes = 90
    /// §53 item 3: a sight this long is the day (a theme park): the day is never thin.
    public static let fullDaySightMinutes = 360

    /// §53 item 3: sights a day of this budget should have: one more than the guides' major sights per pace
    /// (slow 1, moderate 2, fast 3), for the minor stops on top. A budget of no known pace counts as normal.
    public static func minSights(budgetMinutes: Int) -> Int {
        switch TripFitter.Pace(budgetMinutes: budgetMinutes) {
        case .relaxed: 2
        case .normal: 3
        case .packed: 4
        }
    }

    /// §53 item 3: the day's minutes are under `thinShare` of the budget.
    public static func underMinutes(_ minutes: Int, budgetMinutes: Int) -> Bool {
        Double(minutes) < thinShare * Double(budgetMinutes)
    }

    /// §53 item 3: a thin day of a plan of `dayCount` days (the exemptions first, then minutes or sights).
    public static func isThin(_ day: Day, budgetMinutes: Int, dayCount: Int) -> Bool {
        if day.longestSightMinutes >= fullDaySightMinutes { return false }
        if dayCount == 1 && day.onlyMustSee { return false }
        if underMinutes(day.minutes, budgetMinutes: budgetMinutes) { return true }
        guard let sights = day.sights else { return false }
        return sights < minSights(budgetMinutes: budgetMinutes) && budgetMinutes - day.minutes >= roomForOneMinutes
    }

    /// The failed checks in the order of §49 item 4. `hotels` maps a 1-based night to its choices (only given when
    /// the driver has wishes and the model has not picked that night's hotel yet).
    public static func run(notFound: [String], days: [Day], budgetMinutes: Int, spareEmpty: Bool,
                           hotels: [Int: [HotelChoice]] = [:], notHotels: [String] = [], far: [String] = [],
                           city: String = "城市") -> [Issue] {
        var out: [Issue] = []
        for name in notFound { out.append(Issue(kind: .notFound, line: "\(name)没找到，换一个附近类似的或者去掉")) }
        // F-15b §50 item 2 (T-040v): a named hotel whose map kind is not lodging.
        for name in notHotels { out.append(Issue(kind: .notFound, line: "\(name)不是酒店")) }
        // §50 item 4: a place no road reaches, or over 4 h on the straight-line estimate.
        for name in far { out.append(Issue(kind: .far, line: "\(name)开车到不了或者太远，换一个\(city)附近的")) }
        for (d, day) in days.enumerated() where day.minutes > budgetMinutes && day.onlyMustSee {
            out.append(Issue(kind: .over, line: "第\(d + 1)天超了约\(hours(day.minutes - budgetMinutes))小时，减少或换掉一个必去的地方"))
        }
        for (d, day) in days.enumerated() where day.minutes > 0 && Double(day.drivingMinutes) > drivingShare * Double(day.minutes) {
            out.append(Issue(kind: .driving, line: "第\(d + 1)天大半时间在开车，考虑把这天换到一个区域"))
        }
        if spareEmpty {
            for (d, day) in days.enumerated() where isThin(day, budgetMinutes: budgetMinutes, dayCount: days.count) {
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
