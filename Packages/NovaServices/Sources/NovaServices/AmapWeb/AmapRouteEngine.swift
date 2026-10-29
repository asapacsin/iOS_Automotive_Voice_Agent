import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts
import NovaNav
import Synchronization

/// One planned route with its geometry, for the map. GCJ-02.
public struct PlannedRoute: Sendable, Hashable {
    public struct Step: Sendable, Hashable {
        public let instruction: String
        public let road: String?
        /// Index into `points` where this step begins.
        public let startIndex: Int
    }

    public let summary: RouteSummary
    public let points: [GeoCoordinate]
    public let steps: [Step]
}

/// What the map draws: the routes on offer, the chosen one, and the simulated car position.
public struct RouteGeometry: Sendable, Hashable {
    public var routes: [PlannedRoute] = []
    public var selected: RouteID?
    public var car: GeoCoordinate?
    public init() {}
}

/// `NaviEngine` on Amap Web driving directions (`/v3/direction/driving`, strategy 10: up to 3 routes), used
/// instead of the Amap Navi SDK. `.emulator`: simulated movement along the chosen route, labelled so on screen
/// (demo-recording.md REC-006). `.gps` (F-15a 真实导航): the phone's fixes matched to the route by
/// `RouteProgress`, with off-route recalculation; `RouteGeometry.car` stays nil.
public final class AmapRouteEngine: NaviEngine, @unchecked Sendable {
    public let events: AsyncStream<NaviEngineEnvelope>
    private let continuation: AsyncStream<NaviEngineEnvelope>.Continuation
    private let key: @Sendable () -> String?
    private let origin: @Sendable () async -> GeoCoordinate?
    private let transport: any HTTPTransport
    private let onGeometry: @Sendable (RouteGeometry) -> Void
    /// Simulated speed and how many simulated seconds pass per real second.
    private let speedKmh: Double
    /// F-15a `.gps`: the phone's fixes for the trip, the clock of the signal timers, and the progress rules.
    private let location: (any LocationUpdates)?
    private let clock: any NovaClock
    private let progressTuning: RouteProgressTuning
    private let state = Mutex(State())

    private struct State {
        var routes: [PlannedRoute] = []
        var geometry = RouteGeometry()
        var drive: Task<Void, Never>?
        var nextGuidance = GuidanceID.initial
        /// Bumped by every calculation and stop; a fetch whose token is no longer current is dropped
        /// (算了 or a new destination while it was in flight), F-15 §10.
        var request = 0
        /// Newest generation of any calculation, start or stop; a stop of an older one is ignored.
        var latest = Generation.initial
        /// The destination of the last calculation, for an off-route recalculation.
        var destination: GeoCoordinate?
    }

    public init(key: @escaping @Sendable () -> String?, origin: @escaping @Sendable () async -> GeoCoordinate?,
                transport: any HTTPTransport = URLSessionTransport(), speedKmh: Double = 60,
                location: (any LocationUpdates)? = nil, clock: any NovaClock = SystemClock(),
                progressTuning: RouteProgressTuning = RouteProgressTuning(),
                onGeometry: @escaping @Sendable (RouteGeometry) -> Void = { _ in }) {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
        self.key = key
        self.origin = origin
        self.transport = transport
        self.speedKmh = speedKmh
        self.location = location
        self.clock = clock
        self.progressTuning = progressTuning
        self.onGeometry = onGeometry
    }

    public func calculateRoutes(_ request: RouteRequest, generation: Generation) async {
        stopDriving()
        let token = state.withLock { s -> Int in
            s.latest = max(s.latest, generation)
            s.request += 1
            s.destination = request.destination
            return s.request
        }
        let event: NaviEngineEvent
        do {
            guard let key = key(), !key.isEmpty else { throw AmapWebError.keyMissing }
            guard let from = await origin() else { throw AmapWebError.failed }
            let routes = try await fetch(from: from, to: request.destination, key: key)
            let geometry = state.withLock { s -> RouteGeometry? in
                guard s.request == token else { return nil }
                s.routes = routes
                s.geometry = RouteGeometry()
                s.geometry.routes = routes
                s.geometry.selected = routes.first?.summary.id
                s.geometry.car = from
                return s.geometry
            }
            guard let geometry else { return }
            onGeometry(geometry)
            event = routes.isEmpty ? .routeCalculationFailed(code: 0) : .routesReady(routes.map(\.summary))
        } catch {
            guard state.withLock({ $0.request == token }) else { return }
            event = .routeCalculationFailed(code: (error as? AmapWebError) == .keyMissing ? 1 : 2)
        }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: event))
    }

    public func selectRoute(_ id: RouteID, generation: Generation) async {
        let geometry = state.withLock { s -> RouteGeometry in
            s.geometry.selected = id
            return s.geometry
        }
        onGeometry(geometry)
    }

    public func start(_ mode: NaviMode, generation: Generation) async {
        let route = state.withLock { s in s.routes.first { $0.summary.id == s.geometry.selected } }
        guard let route, route.points.count >= 2 else { return }
        let location = location
        if mode == .gps, location == nil { return }
        state.withLock { s in
            s.latest = max(s.latest, generation)
            s.geometry.routes = [route]
            s.drive?.cancel()
            switch mode {
            case .emulator:
                s.drive = Task { [weak self] in await self?.drive(route, generation: generation) }
            case .gps:
                s.geometry.car = nil
                s.drive = Task { [weak self] in
                    if let location { await self?.guide(route, generation: generation, location: location) }
                }
            }
        }
        onGeometry(state.withLock { $0.geometry })
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStarted))
    }

    public func stop(generation: Generation) async {
        // A late stop of an older request must not cancel a newer calculation or guidance.
        let current = state.withLock { s -> Bool in
            guard generation >= s.latest else { return false }
            s.latest = generation
            return true
        }
        guard current else { return }
        stopDriving()
        let geometry = state.withLock { s -> RouteGeometry in
            s.request += 1
            s.routes = []
            s.geometry = RouteGeometry()
            return s.geometry
        }
        onGeometry(geometry)
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviStopped))
    }

    private func stopDriving() {
        state.withLock { s in
            s.drive?.cancel()
            s.drive = nil
        }
    }

    // MARK: Simulated movement

    private func drive(_ route: PlannedRoute, generation: Generation) async {
        let points = route.points
        var cumulative = [0.0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + Self.meters(points[i - 1], points[i])) }
        let total = max(cumulative.last ?? 0, 1)
        let metersPerTick = speedKmh / 3.6
        let secondsPerMeter = Double(route.summary.durationSeconds) / total
        var travelled = 0.0
        var spokenStep = -1
        while !Task.isCancelled {
            let index = cumulative.lastIndex { $0 <= travelled } ?? 0
            let car = Self.interpolate(points, cumulative, index: index, at: travelled)
            let stepIndex = route.steps.lastIndex { $0.startIndex <= index } ?? 0
            if stepIndex != spokenStep, stepIndex + 1 < route.steps.count || spokenStep == -1 {
                spokenStep = stepIndex
                let next = route.steps[min(stepIndex + 1, route.steps.count - 1)]
                let id = state.withLock { s -> GuidanceID in
                    s.nextGuidance = s.nextGuidance.next()
                    return s.nextGuidance
                }
                continuation.yield(NaviEngineEnvelope(generation: generation, event: .guidanceText(next.instruction, id)))
            }
            let nextStepStart = stepIndex + 1 < route.steps.count ? cumulative[route.steps[stepIndex + 1].startIndex] : total
            let remaining = max(0, total - travelled)
            let info = NaviInfo(iconType: 0, stepDistanceMeters: Int(max(0, nextStepStart - travelled)),
                                nextRoadName: route.steps[min(stepIndex + 1, route.steps.count - 1)].road,
                                remainingMeters: Int(remaining), remainingSeconds: Int(remaining * secondsPerMeter),
                                currentSpeedKmh: Int(speedKmh))
            // F-15a §9 (T-040g): a stopped or replaced drive never reaches the map, even mid-tick.
            guard let geometry = state.withLock({ s -> RouteGeometry? in
                guard !Task.isCancelled, s.latest == generation, s.drive != nil else { return nil }
                s.geometry.car = car
                return s.geometry
            }) else { return }
            continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviInfo(info)))
            onGeometry(geometry)
            if remaining <= 0 {
                continuation.yield(NaviEngineEnvelope(generation: generation, event: .arrived))
                return
            }
            try? await Task.sleep(for: .seconds(1))
            travelled += metersPerTick
        }
    }

    // MARK: 真实导航 (F-15a §2.2)

    private enum GuideInput: Sendable {
        case fix(LocationFix)
        case tick(NovaInstant)
        case rerouted([PlannedRoute]?)
    }

    private func guide(_ initial: PlannedRoute, generation: Generation, location: any LocationUpdates) async {
        let (inputs, feed) = AsyncStream.makeStream(of: GuideInput.self)  // unbounded: a reroute result is never dropped
        let clock = clock
        let fixes = Task {
            for await fix in location.updates() { feed.yield(.fix(fix)) }
        }
        let ticks = Task {
            while !Task.isCancelled {
                try? await clock.sleep(until: clock.now + .seconds(1))
                feed.yield(.tick(clock.now))
            }
        }
        defer {
            fixes.cancel()
            ticks.cancel()
            feed.finish()
        }
        var route = initial
        var progress = makeProgress(route)
        var spokenStep = -1
        var lastReroute: NovaInstant?
        var lastFixTime: NovaInstant?
        var rerouting: Task<Void, Never>?
        defer { rerouting?.cancel() }
        for await input in inputs {
            // A fix of an older trip is dropped: a stop or a newer start owns the engine now.
            guard !Task.isCancelled, state.withLock({ $0.latest == generation }) else { return }
            switch input {
            case .fix(let raw):
                let fix = LocationFix(coordinate: CoordinateConverter.gcj02(raw.coordinate),
                                      horizontalAccuracyMeters: raw.horizontalAccuracyMeters, timestamp: raw.timestamp,
                                      speedMetersPerSecond: raw.speedMetersPerSecond, courseDegrees: raw.courseDegrees)
                lastFixTime = fix.timestamp
                guard let snap = progress.update(fix) else { continue }
                let stepIndex = snap.stepIndex
                // As the simulation: entering a step announces the next manoeuvre.
                if stepIndex != spokenStep, stepIndex + 1 < route.steps.count || spokenStep == -1, !route.steps.isEmpty {
                    spokenStep = stepIndex
                    say(route.steps[min(stepIndex + 1, route.steps.count - 1)].instruction, generation: generation)
                }
                let next = route.steps.isEmpty ? nil : route.steps[min(stepIndex + 1, route.steps.count - 1)].road
                let info = NaviInfo(iconType: 0, stepDistanceMeters: Int(snap.distanceToNextStepMeters),
                                    nextRoadName: next, remainingMeters: Int(snap.remainingMeters),
                                    remainingSeconds: snap.remainingSeconds,
                                    currentSpeedKmh: fix.speedMetersPerSecond.map { Int(($0 * 3.6).rounded()) })
                continuation.yield(NaviEngineEnvelope(generation: generation, event: .naviInfo(info)))
                if snap.arrived {
                    continuation.yield(NaviEngineEnvelope(generation: generation, event: .arrived))
                    return
                }
                let limiterOpen = lastReroute.map { fix.timestamp - $0 >= progressTuning.rerouteMinInterval } ?? true
                if snap.offRouteConfirmed, rerouting == nil, limiterOpen {
                    lastReroute = fix.timestamp
                    say("已偏离路线，正在重新规划。", generation: generation)
                    continuation.yield(NaviEngineEnvelope(generation: generation, event: .rerouting))
                    let from = fix.coordinate
                    rerouting = Task { [weak self] in
                        let routes = await self?.recalculate(from: from)
                        feed.yield(.rerouted(routes))
                    }
                }
            case .tick(let now):
                if case .lost(announce: true) = progress.tick(at: now) {
                    say("定位信号弱，导航暂停更新。", generation: generation)
                }
            case .rerouted(let routes):
                rerouting = nil
                guard let fresh = routes?.first, fresh.points.count >= 2 else {
                    // Keep the old route; the next try comes 15 s after this failure (§8).
                    if let lastFixTime { lastReroute = lastFixTime }
                    say("重新规划失败，继续按原路线。", generation: generation)
                    continuation.yield(NaviEngineEnvelope(generation: generation, event: .rerouted(nil)))
                    continue
                }
                route = fresh
                progress = makeProgress(fresh)
                spokenStep = -1
                let geometry = state.withLock { s -> RouteGeometry in
                    s.routes = [fresh]
                    s.geometry.routes = [fresh]
                    s.geometry.selected = fresh.summary.id
                    return s.geometry
                }
                onGeometry(geometry)
                continuation.yield(NaviEngineEnvelope(generation: generation, event: .rerouted(fresh.summary)))
            }
        }
    }

    private func makeProgress(_ route: PlannedRoute) -> RouteProgress {
        RouteProgress(points: route.points, stepStarts: route.steps.map(\.startIndex),
                      durationSeconds: route.summary.durationSeconds, start: clock.now, tuning: progressTuning)
    }

    private func say(_ text: String, generation: Generation) {
        let id = state.withLock { s -> GuidanceID in
            s.nextGuidance = s.nextGuidance.next()
            return s.nextGuidance
        }
        continuation.yield(NaviEngineEnvelope(generation: generation, event: .guidanceText(text, id)))
    }

    /// One recalculation to the same destination; nil when it fails (no key, network, no route).
    private func recalculate(from: GeoCoordinate) async -> [PlannedRoute]? {
        guard let key = key(), !key.isEmpty, let destination = state.withLock({ $0.destination }) else { return nil }
        guard let routes = try? await fetch(from: from, to: destination, key: key), !routes.isEmpty else { return nil }
        return routes
    }

    static func interpolate(_ points: [GeoCoordinate], _ cumulative: [Double], index: Int, at d: Double) -> GeoCoordinate {
        guard index + 1 < points.count else { return points[points.count - 1] }
        let span = cumulative[index + 1] - cumulative[index]
        let t = span > 0 ? min(1, (d - cumulative[index]) / span) : 0
        let a = points[index], b = points[index + 1]
        return GeoCoordinate(latitude: a.latitude + (b.latitude - a.latitude) * t,
                             longitude: a.longitude + (b.longitude - a.longitude) * t, datum: .gcj02)
    }

    static func meters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let r = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLng = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    // MARK: Request

    private func fetch(from: GeoCoordinate, to: GeoCoordinate, key: String) async throws -> [PlannedRoute] {
        var components = URLComponents(string: AmapWebClient.host + "/v3/direction/driving")!
        components.queryItems = [
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "origin", value: AmapWebClient.lngLat(from)),
            URLQueryItem(name: "destination", value: AmapWebClient.lngLat(to)),
            URLQueryItem(name: "strategy", value: "10"),
            URLQueryItem(name: "extensions", value: "base"),
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 8
        let response = try await transport.send(request)
        guard response.status == 200,
              let body = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw AmapWebError.failed
        }
        guard body["status"] as? String == "1" else { throw AmapWebClient.error(infocode: body["infocode"] as? String) }
        return Self.routes(body)
    }

    static func routes(_ body: [String: Any]) -> [PlannedRoute] {
        let paths = ((body["route"] as? [String: Any])?["paths"] as? [[String: Any]]) ?? []
        return paths.prefix(3).enumerated().map { index, path in
            var points: [GeoCoordinate] = []
            var steps: [PlannedRoute.Step] = []
            for step in (path["steps"] as? [[String: Any]]) ?? [] {
                steps.append(PlannedRoute.Step(instruction: step["instruction"] as? String ?? "",
                                               road: step["road"] as? String, startIndex: points.count))
                for pair in (step["polyline"] as? String ?? "").split(separator: ";") {
                    let v = pair.split(separator: ",").compactMap { Double($0) }
                    if v.count == 2 { points.append(GeoCoordinate(latitude: v[1], longitude: v[0], datum: .gcj02)) }
                }
            }
            let int: (String) -> Int = { Int(Double(path[$0] as? String ?? "") ?? 0) }
            let summary = RouteSummary(id: RouteID(index + 1), lengthMeters: int("distance"),
                                       durationSeconds: int("duration"), tollYuan: int("tolls"),
                                       trafficLights: int("traffic_lights"), label: path["strategy"] as? String,
                                       polyline: points)
            return PlannedRoute(summary: summary, points: points, steps: steps)
        }
    }
}
