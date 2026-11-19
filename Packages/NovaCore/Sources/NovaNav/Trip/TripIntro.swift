import Foundation
import NovaKit
import NovaPorts

/// F-15b §21 (T-040m): the spot introduction on the card details, from the existing web search (Qwen, F-18 §16).
/// Only the query is new; the search system text is unchanged (owner rule 2026-11-05). One answer per place id is
/// kept for the app's life; a failure is not kept. The log gets codes only (I-8): `trip intro ok=<yes|no|cached> ms=`.
public actor TripIntro {
    public enum Answer: Sendable, Hashable {
        /// A saved 家/公司 stop: no search, no 「介绍」 section.
        case none
        case text(String)
        /// Failure, timeout, no key or an empty answer: 「没有查到介绍」.
        case failed
    }

    private let search: any WebSearchService
    private let clock: any NovaClock
    private let onLine: @Sendable (String) -> Void
    private var kept: [String: String] = [:]

    public init(search: any WebSearchService, clock: any NovaClock, onLine: @escaping @Sendable (String) -> Void = { _ in }) {
        self.search = search
        self.clock = clock
        self.onLine = onLine
    }

    /// 「介绍一下<城市><名字>」; the city is left out when unknown or already at the start of the name.
    public static func query(name: String, city: String?) -> String {
        var c = (city ?? "").trimmingCharacters(in: .whitespaces)
        if c.hasSuffix("市") { c.removeLast() }
        let prefix = c.isEmpty || name.hasPrefix(c) ? "" : c
        return "介绍一下\(prefix)\(name)"
    }

    public func answer(for card: TripCard) async -> Answer {
        if card.placeID.hasPrefix("saved_") { return .none }
        if let text = kept[card.placeID] {
            onLine("trip intro ok=cached ms=0")
            return .text(text)
        }
        let started = clock.now
        let reply = try? await search.search(Self.query(name: card.name, city: card.city), attempt: 1)
        let ms = max(0, Int((clock.now - started).milliseconds))
        let text = reply?.answer.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            onLine("trip intro ok=no ms=\(ms)")
            return .failed
        }
        kept[card.placeID] = text
        onLine("trip intro ok=yes ms=\(ms)")
        return .text(text)
    }
}
