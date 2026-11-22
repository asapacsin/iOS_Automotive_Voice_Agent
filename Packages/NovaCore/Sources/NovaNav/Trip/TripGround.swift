import Foundation
import NovaKit
import NovaPorts
import NovaTools

/// F-15b §50 (T-040v): the pure parts of grounding a trip abroad. No I/O.
public enum TripGround {
    /// §50 item 5: the one line she says while `set_trip_plan` runs in the background.
    public static var workingLine: String { ToolCatalog.tripWorkingLine }

    /// §50 item 1: the grounded places, with every importance-3 name of the model kept: a must-see the answer left out
    /// (matched on `name` or `english`) is added back as the model wrote it. Returns the list and how many were added.
    public static func keepMustSee(model: [TripGroundPlace], answer: [TripGroundPlace]) -> (places: [TripGroundPlace], added: Int) {
        var out = answer
        var added = 0
        for m in model where m.importance == 3 {
            let found = answer.contains { a in
                matches(a.name, m.name) || a.english.map { matches($0, m.name) } == true
                    || (m.english != nil && a.english.map { matches($0, m.english!) } == true)
            }
            if !found {
                out.append(m)
                added += 1
            }
        }
        return (out, added)
    }

    /// `TripList.matches` on two names: either contains the other, after normalising.
    static func matches(_ a: String, _ b: String) -> Bool {
        let x = TranscriptText.normalize(a), y = TranscriptText.normalize(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return x.contains(y) || y.contains(x)
    }

    /// §36 item 2b's 「中文名 (English name)」 form, so Photon searches the English part.
    public static func written(_ p: TripGroundPlace) -> String {
        guard let english = p.english?.trimmingCharacters(in: .whitespaces), !english.isEmpty, english != p.name else { return p.name }
        return "\(p.name) (\(english))"
    }

    /// §50 item 3: kept only in the trip's country and within `km` of its centre. Returns the kept and the dropped count.
    public static func inArea(_ places: [Place], area: TripArea, km: Double) -> (kept: [Place], dropped: Int) {
        let kept = places.filter { p in
            let country = area.countryCode == nil || p.countryCode?.uppercased() == area.countryCode
            return country && SelfPosition.distanceMeters(area.center, p.coordinate) <= km * 1000
        }
        return (kept, places.count - kept.count)
    }

    /// §50 item 4 `far`: the places (by id) whose straight-line estimate to every other place of the plan is over
    /// `limitSeconds`. Used only when the times are the estimate (no OSRM time); never decides that a place is close.
    public static func far(_ places: [Place], limitSeconds: Int) -> Set<String> {
        var unique: [Place] = []
        for p in places where !unique.contains(where: { $0.id == p.id }) { unique.append(p) }
        guard unique.count > 2 else { return [] }
        let table = TripTimes.estimate(start: nil, stops: unique.map { TripTimes.Node(key: $0.id, coordinate: $0.coordinate) })
        var out: Set<String> = []
        for (i, p) in unique.enumerated() {
            let nearest = unique.indices.filter { $0 != i }.map { table.time(i, $0) }.min() ?? 0
            if nearest > limitSeconds { out.insert(p.id) }
        }
        return out
    }

    /// The city part of "Tokyo, Japan" for spoken lines.
    public static func cityName(_ city: String?) -> String {
        let c = city?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return c.isEmpty ? "城市" : c
    }
}
