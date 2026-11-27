import Foundation

/// F-15b §49 item 4 (T-040u), §55 item 8 (T-040zh): the checks code runs after every plan write. Pure. Each is pass or fail; a failure carries one
/// line for the model, and all failed lines go back together (LLM-Modulo, Gundawar et al. 2024: binary critics whose
/// back-prompts a metacontroller concatenates for the LLM to revise).
public enum TripChecks {
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case empty, over, under, driving, notFound = "not_found", hotel
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

    /// §49 item 4 `driving`: a day whose driving is more than this share of its cost.
    public static let drivingShare = 0.4
    /// §55 item 8 `over`: a day's minutes above this share of the budget B.
    public static let overShare = 1.25
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

    /// §55 item 8 `over`: above `overShare` × B; a day with a sight of `fullDaySightMinutes` or more is over only when
    /// the rest of the day (its other stops and the driving) adds more than B on top.
    public static func isOver(_ day: Day, budgetMinutes: Int) -> Bool {
        if day.longestSightMinutes >= fullDaySightMinutes { return day.minutes - day.longestSightMinutes > budgetMinutes }
        return Double(day.minutes) > overShare * Double(budgetMinutes)
    }

    /// §55 item 8: the failed checks in §55's order (empty, over, under, driving, not_found, hotel), one line each.
    /// `nightsWithoutHotel`: 1-based nights of a plan of 2 days or more with no hotel stop.
    public static func run(days: [Day], budgetMinutes: Int, spareEmpty: Bool = true, notFound: [String] = [],
                           nightsWithoutHotel: [Int] = [], city: String = "城市") -> [Issue] {
        var out: [Issue] = []
        // The fullest and the emptiest day by minutes (the first such day on a tie).
        let fullest = days.indices.max { days[$0].minutes < days[$1].minutes }.map { $0 + 1 } ?? 1
        func emptiest(besides d: Int) -> Int {
            days.indices.filter { $0 != d }.min { days[$0].minutes < days[$1].minutes }.map { $0 + 1 } ?? d + 2
        }
        let empty = Set(days.indices.filter { (days[$0].sights ?? 1) == 0 })
        for d in days.indices where empty.contains(d) {
            out.append(Issue(kind: .empty, line: "第\(d + 1)天没有安排，把第\(fullest)天的一部分挪过来或者加几个地方"))
        }
        for (d, day) in days.enumerated() where isOver(day, budgetMinutes: budgetMinutes) {
            out.append(Issue(kind: .over, line: "第\(d + 1)天大约\(hours(day.minutes))小时，太满了，挪一部分到第\(emptiest(besides: d))天"))
        }
        // §53 item 3 (thin day), its line unchanged; an empty day is `empty`, not thin.
        if spareEmpty {
            for (d, day) in days.enumerated() where !empty.contains(d) && isThin(day, budgetMinutes: budgetMinutes, dayCount: days.count) {
                let area = day.area.map { "在\($0)附近" } ?? ""
                out.append(Issue(kind: .under, line: "第\(d + 1)天还空约\(hours(budgetMinutes - day.minutes))小时，\(area)加1到2个"))
            }
        }
        for (d, day) in days.enumerated() where day.minutes > 0 && Double(day.drivingMinutes) > drivingShare * Double(day.minutes) {
            out.append(Issue(kind: .driving, line: "第\(d + 1)天大半时间在开车，考虑把这天换到一个区域"))
        }
        for name in notFound { out.append(Issue(kind: .notFound, line: "\(name)在\(city)没找到，换一个或者去掉")) }
        if days.count >= 2 {
            for night in nightsWithoutHotel {
                out.append(Issue(kind: .hotel, line: "第\(night)晚还没有酒店，写一个酒店或者 near"))
            }
        }
        return out
    }

    /// Hours, rounded, at least 1.
    static func hours(_ minutes: Int) -> Int { max(1, Int((Double(minutes) / 60).rounded())) }

    /// Kilometres with one decimal.
    static func km(_ meters: Int) -> String { String(format: "%.1f", Double(meters) / 1000) }
}
