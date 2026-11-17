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
        public func time(_ a: Int, _ b: Int) -> Int { a == b ? 0 : seconds[a][b] }
    }

    private let service: any DrivingTimes
    private let clock: any NovaClock
    private let keep: NovaDuration
    private let parallel: Int
    private let retryDelay: NovaDuration
    private var known: [String: (DrivingTime, NovaInstant)] = [:]

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
                    for attempt in 0..<2 {
                        do { return (ask.dest, try await service.drivingTimes(origins: origins, destination: dest)) }
                        catch AmapWebError.quota where attempt == 0 {
                            try? await Task.sleep(for: .milliseconds(retry.milliseconds))
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
}
