import Foundation
import NovaKit
import NovaPorts

/// F-15b §26 (T-040n): the driving-time table for a start and the stops of a plan, from `DrivingTimes`. One request
/// per stop as destination with the start and every other stop as origins; at most `parallel` at once; a quota
/// refusal is tried once more; a pair is kept `keep` (30 min). Any pair missing after that: no table.
public actor TripTimes {
    public struct Node: Sendable, Hashable {
        /// A place id, or `here@lat,lng` rounded to ~100 m (§26 item 2).
        public let key: String
        public let coordinate: GeoCoordinate
        public init(key: String, coordinate: GeoCoordinate) {
            self.key = key
            self.coordinate = coordinate
        }

        public static func here(_ c: GeoCoordinate) -> Node {
            Node(key: String(format: "here@%.3f,%.3f", c.latitude, c.longitude), coordinate: c)
        }
    }

    public struct Table: Sendable {
        /// seconds[a][b]: from node a to node b (indexes into the nodes asked).
        public let seconds: [[Int]]
        public let requests: Int
        public let cached: Int
        /// §36 item 2c: true when the times are the straight-line estimate (OSRM failed abroad).
        public var estimated = false
        /// The ordered pairs the table holds (`trip times pairs=`).
        public var pairs: Int { seconds.count * max(seconds.count - 1, 0) }
        public init(seconds: [[Int]], requests: Int, cached: Int, estimated: Bool = false) {
            self.seconds = seconds
            self.requests = requests
            self.cached = cached
            self.estimated = estimated
        }
        public func time(_ a: Int, _ b: Int) -> Int { a == b ? 0 : seconds[a][b] }
    }

    private let service: any DrivingTimes
    private let clock: any NovaClock
    private let keep: NovaDuration
    private let parallel: Int
    private let retryDelay: NovaDuration
    private var known: [String: (DrivingTime, NovaInstant)] = [:]
    /// §36 item 2c: the one whole-table request in flight; a second waits for it (never more than one at once).
    private var inFlight: Task<Void, Never>?

    public init(service: any DrivingTimes, clock: any NovaClock, keep: NovaDuration = .minutes(30), parallel: Int = 4,
                retryDelay: NovaDuration = .milliseconds(600)) {
        self.service = service
        self.clock = clock
        self.keep = keep
        self.parallel = parallel
        self.retryDelay = retryDelay
    }

    private func pairKey(_ a: Node, _ b: Node) -> String { a.key + ">" + b.key }

    private func cached(_ a: Node, _ b: Node) -> DrivingTime? {
        guard let (t, at) = known[pairKey(a, b)], clock.now - at < keep else { return nil }
        return t
    }

    /// `start` is node 0 when given (the time back to it is not needed); `stops` follow. nil when a pair is missing.
    public func table(start: Node?, stops: [Node]) async -> Table? {
        let nodes = (start.map { [$0] } ?? []) + stops
        if service.answersWholeTable { return await wholeTable(nodes) }
        let first = start == nil ? 0 : 1
        var seconds = Array(repeating: Array(repeating: 0, count: nodes.count), count: nodes.count)
        var asks: [(dest: Int, origins: [Int])] = []
        var cachedCount = 0
        for d in first..<nodes.count {
            let origins = nodes.indices.filter { $0 != d }
            if origins.allSatisfy({ cached(nodes[$0], nodes[d]) != nil }) {
                for o in origins { seconds[o][d] = cached(nodes[o], nodes[d])!.seconds }
                cachedCount += 1
            } else if !origins.isEmpty {
                asks.append((d, origins))
            }
        }
        let service = service, retry = retryDelay, limit = parallel
        let answers: [Int: [DrivingTime?]] = await withTaskGroup(of: (Int, [DrivingTime?]?).self) { group in
            var out: [Int: [DrivingTime?]] = [:]
            var next = 0
            func add() {
                guard next < asks.count else { return }
                let ask = asks[next]
                next += 1
                let origins = ask.origins.map { nodes[$0].coordinate }, dest = nodes[ask.dest].coordinate
                group.addTask {
                    // §26 item 3 as §4 item 7: busy, timed out or failed is tried up to twice more (600 ms, 1.2 s).
                    for attempt in 0..<3 {
                        do { return (ask.dest, try await service.drivingTimes(origins: origins, destination: dest)) }
                        catch let e as AmapWebError where attempt < 2 && [.quota, .timeout, .failed].contains(e) {
                            try? await Task.sleep(for: .milliseconds(retry.milliseconds * Int64(attempt + 1)))
                        } catch { return (ask.dest, nil) }
                    }
                    return (ask.dest, nil)
                }
            }
            for _ in 0..<limit { add() }
            for await (dest, times) in group {
                if let times { out[dest] = times }
                add()
            }
            return out
        }
        for ask in asks {
            guard let times = answers[ask.dest], times.count == ask.origins.count else { return nil }
            for (o, t) in zip(ask.origins, times) {
                guard let t else { return nil }
                seconds[o][ask.dest] = t.seconds
                known[pairKey(nodes[o], nodes[ask.dest])] = (t, clock.now)
            }
        }
        return Table(seconds: seconds, requests: asks.count, cached: cachedCount)
    }

    /// §36 item 2c (T-040p): every pair from one request (OSRM), no retry; all pairs cached → no request. Any pair
    /// missing or the request failing: nil (the caller estimates).
    private func wholeTable(_ nodes: [Node]) async -> Table? {
        func fromCache() -> [[Int]]? {
            var seconds = Array(repeating: Array(repeating: 0, count: nodes.count), count: nodes.count)
            for a in nodes.indices { for b in nodes.indices where a != b {
                guard let t = cached(nodes[a], nodes[b]) else { return nil }
                seconds[a][b] = t.seconds
            } }
            return seconds
        }
        if let seconds = fromCache() { return Table(seconds: seconds, requests: 0, cached: nodes.count) }
        while let running = inFlight {
            await running.value
            if inFlight == running { inFlight = nil }
        }
        if let seconds = fromCache() { return Table(seconds: seconds, requests: 0, cached: nodes.count) }
        let service = service, points = nodes.map(\.coordinate)
        let ask = Task<[[DrivingTime?]]?, Never> { try? await service.table(points) }
        let mine = Task<Void, Never> { _ = await ask.value }
        inFlight = mine
        let answer = await ask.value
        if inFlight == mine { inFlight = nil }
        guard let answer, answer.count == nodes.count else { return nil }
        var seconds = Array(repeating: Array(repeating: 0, count: nodes.count), count: nodes.count)
        for a in nodes.indices {
            guard answer[a].count == nodes.count else { return nil }
            for b in nodes.indices where a != b {
                guard let t = answer[a][b] else { return nil }
                seconds[a][b] = t.seconds
            }
        }
        for a in nodes.indices { for b in nodes.indices where a != b {
            known[pairKey(nodes[a], nodes[b])] = (answer[a][b]!, clock.now)
        } }
        return Table(seconds: seconds, requests: 1, cached: 0)
    }

    /// §36 item 2c: the straight-line fallback abroad: haversine × 1.3 at 50 km/h, marked estimated.
    public static func estimate(start: Node?, stops: [Node]) -> Table {
        let nodes = (start.map { [$0] } ?? []) + stops
        let seconds = nodes.map { a in
            nodes.map { b in Int((SelfPosition.distanceMeters(a.coordinate, b.coordinate) * 1.3 / (50_000.0 / 3600)).rounded()) }
        }
        return Table(seconds: seconds, requests: 0, cached: 0, estimated: true)
    }
}
