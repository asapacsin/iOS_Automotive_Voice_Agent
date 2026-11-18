import Foundation

/// F-15b §48 (T-040t): fits each day of a trip to a time budget. Pure. The model proposes the places (required and
/// optional, with visit minutes); this keeps every required place, inserts optional places in the model's order where
/// they fit (the insertion step of iterated local search for the tourist trip design problem, Vansteenwegen et al.
/// 2009, without the random shake so results repeat) and leaves the rest as spare.
///
/// Nodes are integers as in `TripOptimizer`; `time(a, b)` is driving seconds, `visit(n)` a node's visit seconds.
/// Day d runs from day d−1's last stop (day 1 from `start`) and the last day ends at `end` when given.
public enum TripFitter {
    /// §48 item 1: `places` takes up to 24 items.
    public static let maxCandidates = 24
    /// §48 item 4.3: re-order and retry at most this many rounds.
    public static let maxRounds = 3

    /// §48 item 3: the day budget by pace.
    public enum Pace: String, Sendable, Hashable, CaseIterable {
        case relaxed, normal, packed
        public var budgetMinutes: Int {
            switch self {
            case .relaxed: 360
            case .normal: 480
            case .packed: 600
            }
        }
        /// The pace of a stored budget (a plan saved before §48 counts as normal).
        public init(budgetMinutes: Int?) {
            self = Pace.allCases.first { $0.budgetMinutes == budgetMinutes } ?? .normal
        }
    }

    public struct Result: Sendable, Hashable {
        /// One node list per day, in driving order.
        public let days: [[Int]]
        /// Optional nodes that fit nowhere, in the model's order.
        public let spare: [Int]
    }

    /// Each day's seconds: the drive into its first stop and between its stops, plus their visits; the last day also
    /// drives to `end`. An empty day costs nothing and passes the start on.
    public static func costs(_ days: [[Int]], from start: Int, to end: Int?, visit: (Int) -> Int,
                             time: (Int, Int) -> Int) -> [Int] {
        var here = start
        return days.enumerated().map { d, day in
            var total = 0
            for node in day {
                total += time(here, node) + visit(node)
                here = node
            }
            if d == days.count - 1, let end { total += time(here, end) }
            return total
        }
    }

    /// §48 item 4: `required` is already one list per day (cut as §27 item 3 with visit times, or the driver's day
    /// groups); `optional` is in the model's order; `group` pins an optional node to a day (§48 item 4.4).
    /// Required places are never dropped; a day over budget with them alone stays over (§48 item 4.5).
    public static func fit(required: [[Int]], optional: [Int], group: [Int: Int] = [:], from start: Int, to end: Int?,
                           budgetSeconds: Int, maxPerDay: Int, visit: (Int) -> Int, time: (Int, Int) -> Int) -> Result {
        var days = required.isEmpty ? [[]] : required
        func reorder() {
            var here = start
            for d in days.indices {
                let to = d == days.count - 1 ? end : nil
                days[d] = TripOptimizer.path(days[d], from: here, to: to, time: time)
                here = days[d].last ?? here
            }
        }
        reorder()
        var left = optional
        for _ in 0..<maxRounds {
            var skipped: [Int] = []
            var inserted = false
            for node in left {
                let base = costs(days, from: start, to: end, visit: visit, time: time)
                let baseTotal = base.reduce(0, +)
                var best: (day: Int, at: Int, added: Int)?
                for d in days.indices where days[d].count < maxPerDay && (group[node] == nil || group[node] == d) {
                    for at in 0...days[d].count {
                        var trial = days
                        trial[d].insert(node, at: at)
                        let c = costs(trial, from: start, to: end, visit: visit, time: time)
                        // Every day stays within budget, or at least no worse than it was.
                        guard c.indices.allSatisfy({ c[$0] <= budgetSeconds || c[$0] <= base[$0] }) else { continue }
                        let added = c.reduce(0, +) - baseTotal
                        if best == nil || added < best!.added { best = (d, at, added) }
                    }
                }
                if let best {
                    days[best.day].insert(node, at: best.at)
                    inserted = true
                } else {
                    skipped.append(node)
                }
            }
            left = skipped
            reorder()
            if !inserted || left.isEmpty { break }
        }
        return Result(days: days, spare: left)
    }
}
