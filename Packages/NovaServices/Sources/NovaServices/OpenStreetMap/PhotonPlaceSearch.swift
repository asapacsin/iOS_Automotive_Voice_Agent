import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NovaKit
import NovaPorts

/// F-15b §36 item 2b (2026-11-18): place search for trips abroad through Photon, the OpenStreetMap search
/// (`https://photon.komoot.io/api/`, no key). Apple's search on a China-region iPhone returns only places in China
/// (device records 20261118-102820 and -105448: 107 results, all in China, and no centre for "Tokyo, Japan").
///
/// Names come as 「中文名 (English name)」: the English part is searched (OpenStreetMap has few Chinese names) and the
/// Chinese part is the name shown. A few Chinese category words (「酒店」, 「租车」…) become OpenStreetMap tags.
/// Errors come back as `AmapWebError` so the trip planner treats every vendor alike. OpenStreetMap coordinates are
/// WGS-84, equal to GCJ-02 outside China.
public final class PhotonPlaceSearch: AreaPlaceSearch, @unchecked Sendable {
    public static let host = "https://photon.komoot.io/api/"
    public static let timeoutSeconds: Double = 3  // §52 item 11: one try
    /// Categories searched by tag (OpenStreetMap keys), so 「酒店」 finds hotels in any language.
    static let tags: [String: (q: String, tag: String)] = [
        "酒店": ("hotel", "tourism:hotel"), "宾馆": ("hotel", "tourism:hotel"),
        "租车": ("car rental", "amenity:car_rental"), "租车公司": ("car rental", "amenity:car_rental"),
        "加油站": ("fuel", "amenity:fuel"), "停车场": ("parking", "amenity:parking"),
    ]
    /// §52 item 11 (T-040zd): each try opens a new connection (a fresh transport from `connect`).
    private let connect: @Sendable () -> any HTTPTransport
    private let timing: PhotonTiming
    private let log: @Sendable (String) -> Void
    private let gate: PhotonGate
    private let warmUpLimiter: PhotonWarmUpLimiter
    /// §52 item 11: the connection the last warm-up opened; the next lookup's first try uses it (later tries open
    /// new connections).
    private let warm = PhotonWarmConnection()

    /// One transport for every try (tests, existing callers).
    public convenience init(transport: any HTTPTransport, timing: PhotonTiming = PhotonTiming(),
                            log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.init(connect: { transport }, timing: timing, log: log)
    }

    /// §52 item 11: `connect` gives a new connection per try; the default is a fresh ephemeral URLSession each time.
    public init(connect: @escaping @Sendable () -> any HTTPTransport = { PhotonSessionTransport() },
                timing: PhotonTiming = PhotonTiming(), now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.connect = connect
        self.timing = timing
        self.log = log
        gate = PhotonGate(permits: timing.parallel)
        warmUpLimiter = PhotonWarmUpLimiter(every: timing.warmUpEverySeconds, now: now)
    }

    /// §52 item 11: one small Photon request that opens the connection first, at most one per 30 s. Returns whether a
    /// request was sent. Errors are ignored (the lookups that follow retry on their own).
    @discardableResult
    public func warmUp() async -> Bool {
        guard await warmUpLimiter.take() else { return false }
        _ = try? await search("Tokyo", near: nil, limit: 1, warming: true)
        return true
    }

    /// §52 item 10 (T-040zd): true when `s` has a Chinese, Japanese or Korean character.
    static func hasCJK(_ s: String) -> Bool {
        s.unicodeScalars.contains { u in
            switch u.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xAC00...0xD7AF, 0x20000...0x2FFFF: true
            default: false
            }
        }
    }

    /// 「浅草寺 (Senso-ji)」 → shown 浅草寺, searched Senso-ji; a name without brackets is searched as it is.
    /// §52 item 10: the bracket part is searched only when it has no CJK character; otherwise the outer part
    /// (「New Chitose Airport (新千岁机场)」 → shown 新千岁机场, searched New Chitose Airport).
    static func split(_ name: String) -> (shown: String?, query: String) {
        let s = name.replacingOccurrences(of: "（", with: "(").replacingOccurrences(of: "）", with: ")")
            .trimmingCharacters(in: .whitespaces)
        guard s.hasSuffix(")"), let open = s.lastIndex(of: "(") else { return (nil, s) }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)].trimmingCharacters(in: .whitespaces)
        let outer = s[..<open].trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return (nil, outer) }
        if Self.hasCJK(inner), !outer.isEmpty { return (inner, outer) }
        return (outer.isEmpty ? nil : outer, inner)
    }

    public func text(_ keywords: String, city: String?) async throws -> [Place] {
        try await search(keywords, near: nil, limit: 1)
    }

    public func around(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await search(keywords, near: center, limit: Self.tags[keywords] != nil ? 5 : 1)
    }

    /// Only places within the radius, nearest first (Photon's location is a bias, not a limit).
    public func aroundOnly(_ keywords: String, center: GeoCoordinate, radiusMeters: Int, sort: PlaceSort) async throws -> [Place] {
        try await search(keywords, near: center, limit: 10).compactMap { place in
            let d = Self.meters(center, place.coordinate)
            guard d <= Double(radiusMeters) else { return nil }
            return Place(id: place.id, name: place.name, address: place.address, coordinate: place.coordinate,
                         distanceMeters: Int(d.rounded()), city: place.city, district: place.district,
                         countryCode: place.countryCode, kind: place.kind)
        }.sorted { ($0.distanceMeters ?? 0) < ($1.distanceMeters ?? 0) }
    }

    public func polygon(_ keywords: String, vertices: [GeoCoordinate]) async throws -> [Place] { [] }
    public func detail(id: String) async throws -> Place? { nil }

    /// The centre of a city abroad ("Tokyo, Japan"); nil when not found or in China (CN, HK, MO, TW).
    public func center(_ city: String) async -> GeoCoordinate? {
        guard let found = try? await search(city, near: nil, limit: 3) else { return nil }
        return found.first { !TripRegion.isChina($0.countryCode) }?.coordinate
    }

    /// F-15b §50 item 3 (T-040v): the centre of a city abroad with its `countrycode`; nil when not found or in China.
    public func area(_ city: String) async -> TripArea? {
        guard let found = try? await search(city, near: nil, limit: 3),
              let place = found.first(where: { !TripRegion.isChina($0.countryCode) }) else { return nil }
        return TripArea(center: place.coordinate, countryCode: place.countryCode)
    }

    /// §50 item 3: a trip lookup restricted to `box` (Photon's `bbox`), `limit` results. The name shown is the found
    /// place's (`TripGround.shownName` rule: the asked Chinese name in brackets only when they share no character).
    public func inArea(_ keywords: String, box: GeoBox, limit: Int) async throws -> [Place] {
        let (shown, query) = Self.split(keywords)
        let found = try await search(keywords, near: nil, limit: limit, box: box, keepFoundName: true)
        guard Self.tags[query] == nil else { return found }
        return found.map { p in
            Place(id: p.id, name: Self.shownName(asked: shown, found: p.name), address: p.address ?? p.name,
                  coordinate: p.coordinate, distanceMeters: nil, city: p.city, district: p.district,
                  countryCode: p.countryCode, kind: p.kind)
        }
    }

    /// §50 item 3: the found name, with the asked one in brackets only when the two share no character.
    static func shownName(asked: String?, found: String) -> String {
        guard let asked = asked?.trimmingCharacters(in: .whitespaces), !asked.isEmpty, asked != found else { return found }
        return Set(asked).isDisjoint(with: Set(found)) ? "\(found) (\(asked))" : found
    }

    func search(_ keywords: String, near: GeoCoordinate?, limit: Int, box: GeoBox? = nil,
                keepFoundName: Bool = false, warming: Bool = false) async throws -> [Place] {
        let (shown, query) = Self.split(keywords)
        var items = [URLQueryItem(name: "limit", value: String(limit))]
        if let tag = Self.tags[query] {
            items.append(URLQueryItem(name: "q", value: tag.q))
            items.append(URLQueryItem(name: "osm_tag", value: tag.tag))
        } else {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let near {
            items.append(URLQueryItem(name: "lat", value: String(format: "%.5f", near.latitude)))
            items.append(URLQueryItem(name: "lon", value: String(format: "%.5f", near.longitude)))
        }
        if let box {
            // Photon: `bbox=minLon,minLat,maxLon,maxLat`.
            let v = [box.minLongitude, box.minLatitude, box.maxLongitude, box.maxLatitude].map { String(format: "%.5f", $0) }
            items.append(URLQueryItem(name: "bbox", value: v.joined(separator: ",")))
        }
        var components = URLComponents(string: Self.host)!
        components.queryItems = items
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = timing.tryTimeoutSeconds
        request.setValue("NovaDrive/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        let response = try await send(request, warming: warming)
        if response.status == 429 { throw AmapWebError.quota }
        guard response.status == 200 else { throw AmapWebError.failed }
        let places = try Self.parse(response.body)
        // The Chinese name asked is the name shown, for one named place (not for a category search).
        guard !keepFoundName, let shown, Self.tags[query] == nil else { return places }
        return places.map { p in
            Place(id: p.id, name: shown, address: p.address ?? p.name, coordinate: p.coordinate, distanceMeters: nil,
                  city: p.city, district: p.district, countryCode: p.countryCode, kind: p.kind)
        }
    }

    private enum Try: Sendable { case reply(Int, Data), timeout, failed }

    /// §52 item 11: up to `tries` tries, each on a new connection and waiting at most `tryTimeoutSeconds`, within this
    /// name's own `perNameSeconds` (counted once it may run); at most `parallel` lookups at once. The first try uses
    /// the connection a warm-up left open, if any. A failed try waits `failedRetrySeconds` before the next.
    /// Out of tries or time → `AmapWebError.slow`. Each connection is closed after its try (`close`).
    private func send(_ request: URLRequest, warming: Bool = false) async throws -> (status: Int, body: Data) {
        await gate.acquire()
        defer { Task { await gate.release() } }
        let start = Date()
        for n in 1...max(1, timing.tries) {
            let left = timing.perNameSeconds - Date().timeIntervalSince(start)
            guard left > 0 else { break }
            let wait = min(timing.tryTimeoutSeconds, left)
            let reused = n == 1 && !warming ? warm.take() : nil
            let transport = reused ?? connect()
            let began = Date()
            let outcome: Try = await withTaskGroup(of: Try?.self) { group in
                group.addTask {
                    do {
                        let r = try await transport.send(request)
                        return .reply(r.status, r.body)
                    } catch let error as URLError where error.code == .timedOut {
                        return .timeout
                    } catch {
                        return Task.isCancelled ? nil : .failed
                    }
                }
                group.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                    return Task.isCancelled ? nil : .timeout
                }
                var first: Try = .timeout
                for await r in group { if let r { first = r; break } }
                group.cancelAll()
                return first
            }
            let ms = Int(Date().timeIntervalSince(began) * 1000)
            let via = reused != nil ? " conn=warm" : ""
            switch outcome {
            case .reply(let status, let body):
                log("photon try=\(n) reason=reply ms=\(ms)\(via)")
                // A warm-up keeps its open connection for the next lookup's first try; any other is closed.
                if warming, status == 200 { warm.put(transport) } else { (transport as? any ClosableTransport)?.close() }
                return (status, body)
            case .timeout:
                (transport as? any ClosableTransport)?.close()
                log("photon try=\(n) reason=timeout ms=\(ms)\(via)")
            case .failed:
                (transport as? any ClosableTransport)?.close()
                log("photon try=\(n) reason=failed ms=\(ms)\(via)")
                if n < timing.tries, timing.failedRetrySeconds > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(timing.failedRetrySeconds * 1_000_000_000))
                }
            }
            try Task.checkCancellation()
        }
        throw AmapWebError.slow
    }

    static func parse(_ body: Data) throws -> [Place] {
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw AmapWebError.failed }
        return features.compactMap { f in
            guard let props = f["properties"] as? [String: Any],
                  let geometry = f["geometry"] as? [String: Any],
                  let xy = geometry["coordinates"] as? [Double], xy.count == 2 else { return nil }
            let name = (props["name"] as? String) ?? (props["street"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            let type = (props["osm_type"] as? String) ?? "X"
            let osmID = (props["osm_id"] as? NSNumber)?.int64Value ?? 0
            let address = [props["city"], props["district"], props["street"], props["housenumber"]]
                .compactMap { $0 as? String }.joined(separator: " ")
            return Place(id: "osm_\(type)\(osmID)", name: name, address: address.isEmpty ? nil : address,
                         coordinate: GeoCoordinate(latitude: xy[1], longitude: xy[0], datum: .gcj02), distanceMeters: nil,
                         city: props["city"] as? String, district: props["district"] as? String,
                         countryCode: (props["countrycode"] as? String)?.uppercased(),
                         // §46 item 6 (T-040r): the kind from the OpenStreetMap tag.
                         kind: PlaceKindMap.osm(key: props["osm_key"] as? String, value: props["osm_value"] as? String))
        }
    }

    static func meters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Double {
        let r = 6_371_000.0, p = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * p, dLng = (b.longitude - a.longitude) * p
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * p) * cos(b.latitude * p) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}

/// §52 item 11 (T-040zd): Photon connection timing; injectable so tests run with short times.
public struct PhotonTiming: Sendable {
    public var tryTimeoutSeconds: Double
    public var tries: Int
    public var perNameSeconds: Double
    public var parallel: Int
    public var warmUpEverySeconds: Double
    /// A short wait before retrying a try that failed at once (no network, refused), so the tries are not spent in
    /// the same instant.
    public var failedRetrySeconds: Double

    public init(tryTimeoutSeconds: Double = 3, tries: Int = 4, perNameSeconds: Double = 12, parallel: Int = 4,
                warmUpEverySeconds: Double = 30, failedRetrySeconds: Double = 0.3) {
        self.failedRetrySeconds = failedRetrySeconds
        self.tryTimeoutSeconds = tryTimeoutSeconds
        self.tries = tries
        self.perNameSeconds = perNameSeconds
        self.parallel = parallel
        self.warmUpEverySeconds = warmUpEverySeconds
    }
}

/// At most `permits` lookups at once; the rest wait in order.
actor PhotonGate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(permits: Int) { free = max(1, permits) }
    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func release() {
        if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() }
    }
}

/// §52 item 11: at most one warm-up per `every` seconds.
actor PhotonWarmUpLimiter {
    private let every: Double
    private let now: @Sendable () -> Date
    private var last: Date?
    init(every: Double, now: @escaping @Sendable () -> Date) { self.every = every; self.now = now }
    func take() -> Bool {
        let t = now()
        if let last, t.timeIntervalSince(last) < every { return false }
        last = t
        return true
    }
}

/// A connection that can be closed after use (a per-try URLSession is invalidated, §52 item 11).
public protocol ClosableTransport: HTTPTransport {
    func close()
}

/// §52 item 11: one Photon connection: its own ephemeral URLSession, invalidated by `close` once its try is over.
public final class PhotonSessionTransport: ClosableTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeoutSeconds: Double = PhotonPlaceSearch.timeoutSeconds) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeoutSeconds
        session = URLSession(configuration: config)
    }

    public func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func close() { session.finishTasksAndInvalidate() }
}

/// The connection a warm-up opened, kept for one later first try; a newer warm-up replaces (and closes) it.
final class PhotonWarmConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: (any HTTPTransport)?
    func put(_ t: any HTTPTransport) {
        let old = lock.withLock { () -> (any HTTPTransport)? in defer { kept = t }; return kept }
        if let old, old as AnyObject !== t as AnyObject { (old as? any ClosableTransport)?.close() }
    }
    func take() -> (any HTTPTransport)? { lock.withLock { defer { kept = nil }; return kept } }
}
