import Foundation
import NovaKit
import NovaPorts

/// F-16 §14 (T-042c) numbers. Each one is PROPOSED; the owner sets them from the §14 row 1 replay.
public struct DestinationMatchTuning: Sendable, Hashable {
    /// Item 1.1: the around search radius.
    public var aroundRadiusMeters = 50_000
    /// Item 2: the distance prior's full weight, within `priorFullKm`, falling linearly to 0 at `priorZeroKm`.
    public var distanceWeight = 0.15
    public var priorFullKm = 3.0
    public var priorZeroKm = 50.0
    /// Item 3: sure needs `s1 ≥ sureMin` and `s1 − s2 ≥ sureGap`; unsure needs `s1 ≥ askMin`.
    public var sureMin = 0.8
    public var sureGap = 0.2
    public var askMin = 0.5
    /// Items 4 and 8: a candidate or route over this is far.
    public var farKm = 300.0
    public init() {}
}

/// Item 9: which search found the candidates.
public enum DestinationSearchStep: String, Sendable, Hashable {
    case around, city, type, country
}

/// Item 9: what the call decided.
public enum DestinationCheck: String, Sendable, Hashable {
    case sure, ask
    case farOnly = "far_only"
    case none, rejected
}

/// One candidate with its distance from the car and its score.
public struct ScoredPlace: Sendable, Hashable {
    public let place: Place
    /// From the car; nil without a usable fix and no Amap distance.
    public let km: Double?
    public let similarity: Double
    public let score: Double
}

/// Item 9: one line per `navigate_to` search, for the local record; the log line carries no names (I-8).
public struct DestinationSearchLine: Sendable, Hashable {
    public let destination: String
    public let step: DestinationSearchStep
    public let count: Int
    public let top: String?
    public let score: Double
    public let km: Double
    public let check: DestinationCheck

    public init(destination: String, step: DestinationSearchStep, count: Int, top: String?, score: Double, km: Double,
                check: DestinationCheck) {
        self.destination = destination
        self.step = step
        self.count = count
        self.top = top
        self.score = score
        self.km = km
        self.check = check
    }

    /// The record's fields after `dest-search`.
    public var fields: String {
        "destination=\(destination) step=\(step.rawValue) n=\(count) top=\(top ?? "") "
            + "score=\(String(format: "%.2f", score)) km=\(DestinationMatch.kmText(km)) check=\(check.rawValue)"
    }

    /// The whole record line content: `dest-search destination=… check=…`.
    public var recordLine: String { "dest-search " + fields }

    /// `RuntimeLog`: step and check only (I-8).
    public var logLine: String { "destSearch step=\(step.rawValue) check=\(check.rawValue)" }
}

/// F-16 §14 items 1–4, 8: the near-first search plan, sound-alike scoring and the confirm tier. Pure.
public struct DestinationMatch: Sendable {
    public let tuning: DestinationMatchTuning
    private let pinyin: any PinyinConverter

    public init(pinyin: any PinyinConverter, tuning: DestinationMatchTuning = DestinationMatchTuning()) {
        self.pinyin = pinyin
        self.tuning = tuning
    }

    /// Item 1.3: a destination ending in one of these also gets an around search for the word.
    public static let placeTypeWords = ["小镇", "口岸", "广场", "机场", "医院", "酒店", "学校", "公园", "大厦", "中心",
                                        "站", "庙", "坊", "镇"]

    /// Item 1: province-level names and major cities. A destination naming one the car is not in searches
    /// nationwide. PROPOSED table.
    public static let regionNames = [
        "北京", "天津", "上海", "重庆", "河北", "山西", "辽宁", "吉林", "黑龙江", "江苏", "浙江", "安徽", "福建", "江西",
        "山东", "河南", "湖北", "湖南", "广东", "海南", "四川", "贵州", "云南", "陕西", "甘肃", "青海", "台湾", "内蒙古",
        "广西", "西藏", "宁夏", "新疆", "香港", "澳门",
        "石家庄", "太原", "沈阳", "大连", "长春", "哈尔滨", "南京", "苏州", "无锡", "杭州", "宁波", "温州", "合肥", "福州",
        "厦门", "泉州", "南昌", "济南", "青岛", "郑州", "武汉", "长沙", "广州", "深圳", "珠海", "佛山", "东莞", "中山",
        "江门", "惠州", "汕头", "湛江", "肇庆", "海口", "三亚", "成都", "贵阳", "昆明", "西安", "兰州", "西宁", "南宁",
        "桂林", "拉萨", "银川", "乌鲁木齐", "呼和浩特",
    ]

    /// Item 1.3: the place-type word `destination` ends in, if any (longest first: 小镇 before 镇).
    public static func typeWord(_ destination: String) -> String? {
        placeTypeWords.first { destination.hasSuffix($0) && destination.count > $0.count }
    }

    /// Item 1: true when `destination` names a province or city that the car's address does not.
    public static func namesOtherRegion(_ destination: String, carAddress: String?) -> Bool {
        regionNames.contains { name in
            destination.contains(name) && !(carAddress?.contains(name) ?? false)
        }
    }

    /// Item 1: the near searches in order (nationwide comes after them, see `NavigationController`).
    public static func nearSteps(_ destination: String, hasCity: Bool) -> [DestinationSearchStep] {
        var steps: [DestinationSearchStep] = [.around]
        if hasCity { steps.append(.city) }
        if typeWord(destination) != nil { steps.append(.type) }
        return steps
    }

    /// Score comparisons allow for float rounding (0.65 − 0.45 is 0.2).
    static let epsilon = 1e-9

    /// Item 2: the share of matching toneless syllables (longest common subsequence over the longer name).
    public func similarity(_ destination: String, _ name: String) -> Double {
        let a = pinyin.syllables(Self.core(destination))
        let b = pinyin.syllables(Self.core(name))
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(Self.lcs(a, b)) / Double(max(a.count, b.count))
    }

    /// Item 2: `distanceWeight` within `priorFullKm`, linear to 0 at `priorZeroKm`.
    public func prior(km: Double?) -> Double {
        guard let km else { return 0 }
        if km <= tuning.priorFullKm { return tuning.distanceWeight }
        if km >= tuning.priorZeroKm { return 0 }
        return tuning.distanceWeight * (tuning.priorZeroKm - km) / (tuning.priorZeroKm - tuning.priorFullKm)
    }

    /// Item 2: every place scored and ordered by score (ties keep Amap's order).
    public func rank(_ places: [Place], destination: String, from center: GeoCoordinate?) -> [ScoredPlace] {
        var scored: [(offset: Int, item: ScoredPlace)] = []
        for (offset, place) in places.enumerated() {
            var meters: Int? = place.distanceMeters
            if meters == nil, let center { meters = Self.meters(center, place.coordinate) }
            let km: Double? = meters.map { Double($0) / 1000 }
            let sim = similarity(destination, place.name)
            scored.append((offset, ScoredPlace(place: place, km: km, similarity: sim, score: sim + prior(km: km))))
        }
        scored.sort { a, b in a.item.score != b.item.score ? a.item.score > b.item.score : a.offset < b.offset }
        return scored.map(\.item)
    }

    /// Items 3–4: the tier of a ranked list.
    public func check(_ ranked: [ScoredPlace]) -> DestinationCheck {
        guard let first = ranked.first, first.score >= tuning.askMin - Self.epsilon else { return .none }
        if ranked.allSatisfy(isFar) { return .farOnly }
        let second = ranked.dropFirst().first?.score ?? 0
        if first.score >= tuning.sureMin - Self.epsilon, first.score - second >= tuning.sureGap - Self.epsilon, !isFar(first) { return .sure }
        return .ask
    }

    /// Item 4: over `farKm` from the car (an unknown distance is not far).
    public func isFar(_ candidate: ScoredPlace) -> Bool { (candidate.km ?? 0) > tuning.farKm }

    /// Item 8: 「去X，约N公里，1小时35分钟」, 「约6分钟」 under an hour; over `farKm` adds the long-trip question.
    public func startSentence(name: String, meters: Int, seconds: Int) -> (text: String, longTrip: Bool) {
        let km = Double(meters) / 1000
        let minutes = max(1, Int((Double(seconds) / 60).rounded()))
        let duration = minutes >= 60
            ? "\(minutes / 60)小时" + (minutes % 60 == 0 ? "" : "\(minutes % 60)分钟")
            : "约\(minutes)分钟"
        let longTrip = km > tuning.farKm
        return ("去\(name)，约\(Self.kmText(km))公里，\(duration)" + (longTrip ? "。这是长途，确定吗？" : "。"), longTrip)
    }

    /// Spoken and recorded km: one decimal under 10 km, whole km from there.
    public static func kmText(_ km: Double) -> String {
        km < 10 ? String(format: "%.1f", km) : String(Int(km.rounded()))
    }

    /// The name without a bracketed branch (「横琴口岸(旅检区)」 → 横琴口岸) and without spaces.
    static func core(_ name: String) -> String {
        var out = ""
        var depth = 0
        for c in name {
            if c == "(" || c == "（" { depth += 1; continue }
            if c == ")" || c == "）" { depth = max(0, depth - 1); continue }
            if depth == 0, !c.isWhitespace { out.append(c) }
        }
        return out
    }

    static func lcs(_ a: [String], _ b: [String]) -> Int {
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Great-circle metres between two GCJ-02 points (close enough for a distance prior).
    static func meters(_ a: GeoCoordinate, _ b: GeoCoordinate) -> Int {
        let r = 6_371_000.0
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return Int(2 * r * asin(min(1, sqrt(h))))
    }
}
