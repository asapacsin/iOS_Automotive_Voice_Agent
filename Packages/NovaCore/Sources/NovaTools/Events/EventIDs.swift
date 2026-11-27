import Foundation
import NovaKit

/// F-15b §74 item 1 (T-040zza): the ids `find_events` gives its items, kept for the conversation (across a reconnect).
/// `e<n>` per entry in result order; an entry with several venues gets `e<n>a`, `e<n>b`, … in its venue order. An entry
/// listed again keeps its ids. A new conversation starts at `e1` (`reset`).
public actor EventIDs {
    /// One id's entry and venue (nil: the entry has no confirmed venue).
    public struct Chosen: Sendable, Hashable {
        public let entry: EventEntry
        public let venue: String?
    }

    private var byID: [String: Chosen] = [:]
    private var idsOf: [String: [String]] = [:]
    private var next = 1

    public init() {}

    public func reset() {
        byID = [:]
        idsOf = [:]
        next = 1
    }

    /// The entry's key: an entry is the same one when its name and city are.
    static func key(_ e: EventEntry) -> String { e.city + "|" + e.name }

    /// The entry's venues in its venue order (live-info §44 item 1a); empty without a confirmed venue.
    public static func venues(_ e: EventEntry) -> [String] {
        e.confirmedVenue.map(EventSourceCheck.venueParts) ?? []
    }

    /// The entry's ids (assigned on first sight), one per venue when it has several.
    @discardableResult
    public func ids(for e: EventEntry) -> [String] {
        if let known = idsOf[Self.key(e)] { return known }
        let venues = Self.venues(e)
        let base = "e\(next)"
        next += 1
        var out: [String] = []
        if venues.count > 1 {
            for (i, v) in venues.enumerated() {
                let id = base + String(UnicodeScalar(UInt8(97 + min(i, 25))))
                byID[id] = Chosen(entry: e, venue: v)
                out.append(id)
            }
        } else {
            byID[base] = Chosen(entry: e, venue: venues.first)
            out.append(base)
        }
        idsOf[Self.key(e)] = out
        return out
    }

    /// nil: an id this conversation never gave.
    public func chosen(_ id: String) -> Chosen? { byID[id.trimmingCharacters(in: .whitespaces)] }

    /// Item 1: the result's items: one per venue for a multi-venue entry, each with its id and 「场馆：<that venue>」.
    public func items(_ events: [EventEntry]) -> [JSONValue] {
        var out: [JSONValue] = []
        for e in events {
            let ids = ids(for: e)
            let venues = Self.venues(e)
            guard case .object(var base) = e.json else { continue }
            if ids.count > 1 {
                for (id, v) in zip(ids, venues) {
                    var o = base
                    o["id"] = .string(id)
                    o["facts"] = .string(e.factsText(venue: v))
                    out.append(.object(o))
                }
            } else {
                base["id"] = .string(ids[0])
                out.append(.object(base))
            }
        }
        return out
    }
}
