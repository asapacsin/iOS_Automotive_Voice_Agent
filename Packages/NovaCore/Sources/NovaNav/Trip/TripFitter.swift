import Foundation

/// F-15b §48 (T-040t): fits each day of a trip to a time budget. Pure. The model proposes the places (required and
/// optional, with visit minutes); this keeps every required place, inserts optional places where they fit (the
/// insertion step of iterated local search for the tourist trip design problem, Vansteenwegen et al. 2009, without the
/// random shake so results repeat) and leaves the rest as spare.
/// §49 item 3 (T-040u): then exchanges between days by score (Google's LLM trip planning optimizer, 2025).
///
/// Nodes are integers as in `TripOptimizer`; `time(a, b)` is driving seconds, `visit(n)` a node's visit seconds.
/// Day d runs from day d−1's last stop (day 1 from `start`) and the last day ends at `end` when given.
public enum TripFitter {
    /// §48 item 1: `places` takes up to 24 items.
    public static let maxCandidates = 24
    /// §48 item 4.3: re-order and retry at most this many rounds.
    public static let maxRounds = 3
    /// §49 item 3 (T-040u): at most this many kept exchanges between days.
    public static let maxMoves = 50
    /// §49 item 3: to judge a trial move a day of up to this many stops is ordered with every order tried, a longer
    /// one with nearest + 2-opt (every order of 8 stops is too slow for each trial); a kept move is ordered fully.
    static let judgeExhaustiveLimit = 5

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
        /// Optional nodes that fit nowhere, in rank order (importance, then the model's order).
        public let spare: [Int]
        /// §49 item 3 (T-040u): the exchanges kept.
        public var moves: Int = 0
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

    /// §48 item 4 with §49 item 3 (T-040u): `required` is already one list per day (cut as §27 item 3 with visit
    /// times, or the driver's day groups); `optional` is in the model's order; `group` pins a node to a day.
    /// The others are inserted highest `importance` first (the model's order within one importance), then improved by
    /// exchanges (`improve`). Required places are never dropped; a day over budget with them alone stays over.
    public static func fit(required: [[Int]], optional: [Int], group: [Int: Int] = [:], from start: Int, to end: Int?,
                           budgetSeconds: Int, maxPerDay: Int, visit: (Int) -> Int, time: (Int, Int) -> Int,
                           importance: (Int) -> Int = { _ in 1 }) -> Result {
        var days = required.isEmpty ? [[]] : required
        days = reordered(days, from: start, to: end, time: time, full: true)
        // Stable: the model's order within one importance.
        let ranked = optional.enumerated().sorted { a, b in
            let (ia, ib) = (importance(a.element), importance(b.element))
            return ia != ib ? ia > ib : a.offset < b.offset
        }.map(\.element)
        var left = ranked
        for _ in 0..<maxRounds {
            let (next, skipped, inserted) = insert(left, into: days, group: group, from: start, to: end,
                                                   budgetSeconds: budgetSeconds, maxPerDay: maxPerDay, visit: visit, time: time)
            days = reordered(next, from: start, to: end, time: time, full: true)
            left = skipped
            if !inserted || left.isEmpty { break }
        }
        return improve(days: days, left: left, required: Set(required.flatMap { $0 }), group: group, from: start, to: end,
                       budgetSeconds: budgetSeconds, maxPerDay: maxPerDay, visit: visit, time: time, importance: importance)
    }

    /// §49 item 3: a day's score is the sum of its places' importance when it is within budget, else 0.
    public static func score(_ days: [[Int]], from start: Int, to end: Int?, budgetSeconds: Int, visit: (Int) -> Int,
                             time: (Int, Int) -> Int, importance: (Int) -> Int) -> Int {
        let c = costs(days, from: start, to: end, visit: visit, time: time)
        return days.indices.reduce(0) { total, d in
            c[d] <= budgetSeconds ? total + days[d].reduce(0) { $0 + importance($1) } : total
        }
    }

    /// §49 item 3: the exchanges, from a fitted plan and its left-out places (in rank order). Tried in a fixed order:
    /// move one place from one day to another, swap one place of each of two days, swap a left-out place in for a kept
    /// one of lower importance. After each trial move the days are ordered again and the left-out places inserted where
    /// they now fit; the first move that raises the plan's score is kept and the search starts again, at most
    /// `maxMoves` times. Required places are never left out.
    public static func improve(days start0: [[Int]], left left0: [Int], required: Set<Int> = [], group: [Int: Int] = [:],
                               from start: Int, to end: Int?, budgetSeconds: Int, maxPerDay: Int,
                               visit: (Int) -> Int, time: (Int, Int) -> Int, importance: (Int) -> Int) -> Result {
        var days = start0
        var left = left0
        func value(_ d: [[Int]]) -> Int {
            score(d, from: start, to: end, budgetSeconds: budgetSeconds, visit: visit, time: time, importance: importance)
        }
        func allowed(_ node: Int, on day: Int) -> Bool { group[node] == nil || group[node] == day }
        var moves = 0
        var best = value(days)
        search: while moves < maxMoves {
            var trials: [([[Int]], [Int])] = []
            // Move one place from day a to day b.
            for a in days.indices {
                for node in days[a] {
                    for b in days.indices where b != a && allowed(node, on: b) {
                        var t = days
                        t[a].removeAll { $0 == node }
                        t[b].append(node)
                        trials.append((t, left))
                    }
                }
            }
            // Swap one place of each of two days.
            for a in days.indices {
                for b in days.indices where b > a {
                    for x in days[a] where allowed(x, on: b) {
                        for y in days[b] where allowed(y, on: a) {
                            var t = days
                            t[a] = t[a].map { $0 == x ? y : $0 }
                            t[b] = t[b].map { $0 == y ? x : $0 }
                            trials.append((t, left))
                        }
                    }
                }
            }
            // A left-out place in for a kept one of lower importance (never a required one).
            for x in left {
                for d in days.indices where allowed(x, on: d) {
                    for y in days[d] where !required.contains(y) && importance(y) < importance(x) {
                        var t = days
                        t[d] = t[d].map { $0 == y ? x : $0 }
                        trials.append((t, left.filter { $0 != x } + [y]))
                    }
                }
            }
            for (t, out) in trials where t.allSatisfy({ $0.count <= maxPerDay }) {
                let ordered = reordered(t, from: start, to: end, time: time, full: false)
                let (filled, skipped, _) = insert(out, into: ordered, group: group, from: start, to: end,
                                                  budgetSeconds: budgetSeconds, maxPerDay: maxPerDay, visit: visit, time: time)
                guard value(filled) > best else { continue }
                days = reordered(filled, from: start, to: end, time: time, full: true)
                left = skipped
                best = value(days)
                moves += 1
                continue search
            }
            break
        }
        return Result(days: days, spare: left, moves: moves)
    }

    /// §48 item 4 step 2: each node to the cheapest place in any day that keeps every day within budget (or no worse
    /// than it was); the ones that fit nowhere are skipped, in their order.
    static func insert(_ nodes: [Int], into start0: [[Int]], group: [Int: Int], from start: Int, to end: Int?,
                       budgetSeconds: Int, maxPerDay: Int, visit: (Int) -> Int,
                       time: (Int, Int) -> Int) -> (days: [[Int]], skipped: [Int], inserted: Bool) {
        var days = start0
        var skipped: [Int] = []
        var inserted = false
        for node in nodes {
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
        return (days, skipped, inserted)
    }

    /// Each day ordered between its ends (§27 item 1, §37 item 3): day d from day d−1's last stop, the last to `end`.
    static func reordered(_ days: [[Int]], from start: Int, to end: Int?, time: (Int, Int) -> Int, full: Bool) -> [[Int]] {
        var out = days
        var here = start
        for d in out.indices {
            let to = d == out.count - 1 ? end : nil
            if full || out[d].count <= judgeExhaustiveLimit {
                out[d] = TripOptimizer.path(out[d], from: here, to: to, time: time)
            } else {
                let quick = TripOptimizer.twoOpt(TripOptimizer.nearest(out[d], from: here, time: time), from: here, to: to, time: time)
                if TripOptimizer.cost(quick, from: here, to: to, time: time) < TripOptimizer.cost(out[d], from: here, to: to, time: time) {
                    out[d] = quick
                }
            }
            here = out[d].last ?? here
        }
        return out
    }
}
