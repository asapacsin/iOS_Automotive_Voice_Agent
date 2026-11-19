import NovaKit
import NovaPorts

/// F-09b §13 item 3 (T-031l): stage 1, not-found and failed lookups as `ToolReply` facts and rules, no sentence.
public enum LookupReply {
    /// Where a search was centred: the phone's fix, the demo start point, or a city (no fix, a named city).
    public enum Around: String, Sendable, Hashable {
        case phone, demo, city
    }

    /// The nearest place outside the searched radius, when the search has one.
    public struct Nearest: Sendable, Hashable {
        public let name: String
        public let distanceKm: Double
        public init(name: String, distanceKm: Double) {
            self.name = name
            self.distanceKm = distanceKm
        }
    }

    /// `navigate_to` `NO_CANDIDATES`: `{what, around, radius_km, found: 0}` plus `nearest_outside` when there is one;
    /// `may` offer_nearest (only then), search_wider, similar_place; `must_not` ask_rephrase, invent.
    public static func noCandidates(what: String, around: Around, radiusKm: Double?, city: String? = nil,
                                    nearestOutside: Nearest? = nil) -> ToolResult {
        var facts: [String: JSONValue] = ["what": .string(what), "around": .string(around.rawValue), "found": 0]
        if let radiusKm { facts["radius_km"] = .double(km(radiusKm)) }
        if let city { facts["city"] = .string(city) }
        if let nearestOutside {
            facts["nearest_outside"] = .object(["name": .string(nearestOutside.name),
                                                "distance_km": .double(km(nearestOutside.distanceKm))])
        }
        let may: [ReplyMay] = (nearestOutside == nil ? [] : [.offerNearest]) + [.searchWider, .similarPlace]
        return ToolReply.failure(.noCandidates, facts: facts, may: may, mustNot: [.askRephrase, .invent]).result
    }

    /// Nothing found for a lookup that is not a destination search (a detail, an address, a list of names).
    public static func notFound(_ code: ToolErrorCode, what: String, facts extra: [String: JSONValue] = [:],
                                may: [ReplyMay] = [], mustNot: [ReplyMustNot] = []) -> ToolResult {
        var facts = extra
        facts["what"] = .string(what)
        facts["found"] = 0
        return ToolReply.failure(code, facts: facts, may: may, mustNot: mustNot + [.askRephrase, .invent]).result
    }

    /// Why a lookup failed: the real cause she may name (F-18 §8).
    public enum Cause: String, Sendable, Hashable {
        case keyMissing = "key_missing"
        case quota
        case network
        case noLocation = "no_location"
        case permissionDenied = "permission_denied"
        case noRouteShape = "no_route_shape"
        case routeFailed = "route_failed"
    }

    /// A lookup that failed: `facts` `{what, cause}` plus the caller's (e.g. `changed: false`).
    public static func failed(_ code: ToolErrorCode, what: String, cause: Cause, facts extra: [String: JSONValue] = [:],
                              may: [ReplyMay]? = nil, mustNot: [ReplyMustNot] = []) -> ToolResult {
        var facts = extra
        facts["what"] = .string(what)
        facts["cause"] = .string(cause.rawValue)
        let moves: [ReplyMay] = may ?? switch cause {
        case .keyMissing, .permissionDenied: [.nameSetting]
        case .quota, .network, .noRouteShape, .routeFailed: [.tryLater]
        case .noLocation: [.askPlace, .tryLater]
        }
        var rules = mustNot + [.invent]
        if cause == .noLocation || cause == .permissionDenied { rules.append(.guessLocation) }
        return ToolReply.failure(code, facts: facts, may: moves, mustNot: rules).result
    }

    /// 高德's error as the cause (F-18 §8): key, quota, otherwise network.
    public static func cause(of error: any Error) -> Cause {
        switch error as? AmapWebError {
        case .keyMissing, .keyRejected: .keyMissing
        case .quota: .quota
        default: .network
        }
    }

    public static func code(for cause: Cause) -> ToolErrorCode {
        switch cause {
        case .keyMissing: .amapWebKeyMissing
        case .quota: .liveInfoQuota
        default: .liveInfoUnavailable
        }
    }

    private static func km(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}
