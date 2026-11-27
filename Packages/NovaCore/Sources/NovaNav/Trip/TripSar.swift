import Foundation
import NovaPorts

/// F-15b §71 (T-040zx): Macau and Hong Kong lookups, the name check and the router of legs that touch them.
public enum TripSar {
    // MARK: Item 1: which lookups are SAR lookups

    /// §71 item 1: the city texts that make a lookup a Macau or Hong Kong one (case-insensitive, contained).
    public static let aliases: [(region: SpecialRegion, words: [String])] = [
        (.macau, ["澳门", "澳門", "macau", "macao", "氹仔", "凼仔", "路环", "路環", "路氹"]),
        (.hongKong, ["香港", "hong kong", "九龙", "九龍", "尖沙咀", "新界", "香港岛"]),
    ]

    /// A SAR lookup: the SARs its city text names, and the mainland cities it names beside them (「珠海,澳门」 → 珠海).
    public struct Lookup: Sendable, Hashable {
        public let regions: [SpecialRegion]
        public let mainland: [String]
    }

    /// §71 item 1: nil when the city text names no SAR (a mainland or empty city).
    public static func lookup(city: String?) -> Lookup? {
        guard var text = city?.lowercased(), !text.isEmpty else { return nil }
        var regions: [SpecialRegion] = []
        // Longest words first, so 香港岛 goes before 香港.
        for (region, words) in aliases {
            for w in words.sorted(by: { $0.count > $1.count }) where text.contains(w) {
                if !regions.contains(region) { regions.append(region) }
                text = text.replacingOccurrences(of: w, with: ",")
            }
        }
        guard !regions.isEmpty else { return nil }
        for w in ["特别行政区", "特別行政區"] { text = text.replacingOccurrences(of: w, with: ",") }
        let separators = CharacterSet(charactersIn: ",，、/;；|和与及 ").union(.whitespacesAndNewlines)
        let mainland = text.components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .map { $0.hasSuffix("市") && $0.count > 1 ? String($0.dropLast()) : $0 }
            .filter { !$0.isEmpty }
        return Lookup(regions: regions, mainland: mainland)
    }

    /// §71 item 2a: a result kept by a SAR lookup: in one of its SARs (§70's adcode/province rule), or in a mainland
    /// city its text names.
    public static func keeps(_ place: Place, _ lookup: Lookup) -> Bool {
        if let region = SpecialRegion.keptBy(place)?.region { return lookup.regions.contains(region) }
        return inCity(place, lookup.mainland)
    }

    /// The place is in one of `cities` (高德's `cityname` 「珠海市」 against 「珠海」, or its province).
    public static func inCity(_ place: Place, _ cities: [String]) -> Bool {
        let names = [place.city, place.province].compactMap { $0 }.filter { !$0.isEmpty }
        return cities.contains { c in
            let city = c.hasSuffix("市") && c.count > 1 ? String(c.dropLast()) : c
            return !city.isEmpty && names.contains { $0.contains(city) }
        }
    }

    /// §71 item 3: the result is in one of the trip's cities (a SAR city text keeps that SAR, a mainland one its city).
    public static func inTrip(_ place: Place, cities: [String]) -> Bool {
        cities.contains { c in
            if let sar = lookup(city: c) { return keeps(place, sar) }
            return inCity(place, [c])
        }
    }

    /// §71 item 2b: the name asked again with the SAR's name in front; nil when it already starts with it.
    public static func prefixed(_ name: String, _ region: SpecialRegion) -> String? {
        let starts = region == .macau ? ["澳门", "澳門"] : ["香港"]
        if starts.contains(where: name.hasPrefix) { return nil }
        return region.shortName + name
    }

    // MARK: Item 2: the name check

    static let prefixes = ["澳门", "澳門", "香港"]
    static let tails = ["度假村", "酒店", "景区", "广场", "公园"]
    /// A result that names the asked place only as a landmark near it (「Public Toilet near Ruins of St. Paul's」).
    static let nearWords = [" near ", "附近", "旁边", "对面", "周边"]

    /// §71 item 2: the asked name with the SAR prefix and one generic tail removed, in simplified form.
    public static func core(_ asked: String) -> String {
        var s = simplified(asked).trimmingCharacters(in: .whitespaces)
        for p in prefixes.map(simplified) where s.hasPrefix(p) && s.count > p.count {
            s = String(s.dropFirst(p.count))
            break
        }
        for t in tails where s.hasSuffix(t) && s.count > t.count {
            s = String(s.dropLast(t.count))
            break
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// §71 item 2: the result's name contains the asked name's core (simplified, case-insensitive), and does not name
    /// it only as something nearby.
    public static func nameMatches(asked: String, found: String) -> Bool {
        let c = core(asked)
        guard !c.isEmpty else { return true }
        let name = simplified(found)
        guard name.contains(c) else { return false }
        let askedText = simplified(asked)
        return !nearWords.contains { name.contains($0) && !askedText.contains($0) }
    }

    /// §71 item 2: compared in simplified form (Foundation's Hant-Hans transform; works on Linux too); Latin letters
    /// lower case.
    static func simplified(_ text: String) -> String {
        (text.applyingTransform(StringTransform("Hant-Hans"), reverse: false) ?? text).lowercased()
    }

    // MARK: Items 5-6: which router, border legs

    /// §71 item 5: a found place is a SAR place when 高德 gives it adcode 82/81 or `pname`/`cityname` 澳门/香港特别行政区.
    public static func isSarPlace(_ place: Place) -> Bool { SpecialRegion.keptBy(place) != nil }

    /// §71 item 6: a leg between a SAR place and a mainland place.
    public static func isBorder(_ a: TripStop, _ b: TripStop) -> Bool {
        a.placed && b.placed && isSarPlace(a.place) != isSarPlace(b.place)
    }

    /// §71 item 6: the card's line and the plan result's sentence (once per plan).
    public static let borderCardText = "过关时间未计入"
    public static let permitNext = "跨境自驾需粤车南下等通行证，过关排队时间没算进去。"
}
