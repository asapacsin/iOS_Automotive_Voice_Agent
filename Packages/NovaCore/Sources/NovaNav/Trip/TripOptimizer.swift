import Foundation
import NovaKit
import NovaPorts

/// F-15b §27 (T-040n): orders stops by driving time. Pure. Nodes are integers; `time(a, b)` is the driving seconds
/// from node a to node b. The optimizer only returns orders of the nodes it was given (§27 item 4).
public enum TripOptimizer {
    /// §27 item 3: the fixed visit time per stop when days are cut.
    public static let visitSeconds = 90 * 60
    /// §27 item 1: up to this many stops every order is tried.
    public static let exhaustiveLimit = 8

    /// The open path from `start` through every node of `stops` with the smallest total time. `stops` is the current
    /// order: equal totals keep it.
    public static func path(_ stops: [Int], from start: Int, time: (Int, Int) -> Int) -> [Int] {
        guard stops.count > 1 else { return stops }
        if stops.count <= exhaustiveLimit { return exhaustive(stops, from: start, time: time) }
        var best = twoOpt(nearest(stops, from: start, time: time), from: start, time: time)
        if cost(best, from: start, time: time) >= cost(stops, from: start, time: time) { best = stops }
        return best
    }

    public static func cost(_ path: [Int], from start: Int, time: (Int, Int) -> Int) -> Int {
        var total = 0
        var here = start
        for node in path {
            total += time(here, node)
            here = node
        }
        return total
    }

    /// Every order in lexicographic sequence from the current one; only a strictly shorter one replaces the best.
    static func exhaustive(_ stops: [Int], from start: Int, time: (Int, Int) -> Int) -> [Int] {
        var perm = Array(stops.indices)
        var best = stops
        var bestCost = cost(stops, from: start, time: time)
        while nextPermutation(&perm) {
            let order = perm.map { stops[$0] }
            let c = cost(order, from: start, time: time)
            if c < bestCost {
                best = order
                bestCost = c
            }
        }
        // The identity is the first permutation, so every order is seen once.
        return best
    }

    static func nextPermutation(_ a: inout [Int]) -> Bool {
        guard a.count > 1 else { return false }
        var i = a.count - 2
        while i >= 0, a[i] >= a[i + 1] { i -= 1 }
        guard i >= 0 else { return false }
        var j = a.count - 1
        while a[j] <= a[i] { j -= 1 }
        a.swapAt(i, j)
        a[(i + 1)...].reverse()
        return true
    }

    static func nearest(_ stops: [Int], from start: Int, time: (Int, Int) -> Int) -> [Int] {
        var left = stops
        var out: [Int] = []
        var here = start
        while !left.isEmpty {
            // First of equal ones keeps the current order.
            var pick = 0
            for i in left.indices.dropFirst() where time(here, left[i]) < time(here, left[pick]) { pick = i }
            here = left.remove(at: pick)
            out.append(here)
        }
        return out
    }

    /// Reverses segments of the open path while that shortens it.
    static func twoOpt(_ path: [Int], from start: Int, time: (Int, Int) -> Int) -> [Int] {
        var best = path
        var bestCost = cost(path, from: start, time: time)
        var improved = true
        while improved {
            improved = false
            for i in 0..<(best.count - 1) {
                for k in (i + 1)..<best.count {
                    var candidate = best
                    candidate[i...k].reverse()
                    let c = cost(candidate, from: start, time: time)
                    if c < bestCost {
                        best = candidate
                        bestCost = c
                        improved = true
                    }
                }
            }
        }
        return best
    }

    /// §27 item 3: `path` cut into `days` consecutive days of at least one stop (fewer days when there are fewer
    /// stops), the longest day as short as possible. A day counts the drive into its first stop (day 1 from `start`,
    /// day k from day k−1's last stop), the drives inside it, and `visitSeconds` per stop.
    public static func cut(_ path: [Int], from start: Int, days: Int, time: (Int, Int) -> Int) -> [[Int]] {
        let m = path.count
        let d = max(1, min(days, m))
        guard m > 0 else { return [[]] }
        guard d > 1 else { return [path] }
        func dayCost(_ a: Int, _ b: Int) -> Int {
            var total = time(a == 0 ? start : path[a - 1], path[a]) + visitSeconds
            for i in stride(from: a + 1, through: b, by: 1) { total += time(path[i - 1], path[i]) + visitSeconds }
            return total
        }
        // best[k][j]: the smallest longest day covering path[0..<j] in k days; from[k][j]: where day k starts.
        let inf = Int.max
        var best = Array(repeating: Array(repeating: inf, count: m + 1), count: d + 1)
        var from = Array(repeating: Array(repeating: 0, count: m + 1), count: d + 1)
        best[0][0] = 0
        for k in 1...d {
            for j in k...m {
                for i in (k - 1)..<j where best[k - 1][i] != inf {
                    let c = max(best[k - 1][i], dayCost(i, j - 1))
                    if c < best[k][j] {
                        best[k][j] = c
                        from[k][j] = i
                    }
                }
            }
        }
        var out: [[Int]] = []
        var j = m
        for k in stride(from: d, through: 1, by: -1) {
            let i = from[k][j]
            out.insert(Array(path[i..<j]), at: 0)
            j = i
        }
        return out
    }
}
