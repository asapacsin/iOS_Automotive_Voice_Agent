import Foundation
import NovaKit
import NovaPorts

/// F-16 query building (`A/nav/LiveDestinationCandidateSource.kt`): strip filler and navigation verbs,
/// sort nearby and category queries by distance and named places by Amap weight, and retry once with
/// the verbatim text when the stripped query finds nothing.
///
/// PROPOSED: the verb, filler and category tables below; the Android tables (`DestinationQueryTest`)
/// are an EVIDENCE_REQUEST. The spec names 导航去, 带我去 and 附近的.
public struct DestinationQuery: Sendable, Hashable {
    /// The text as the model gave it, trimmed.
    public let verbatim: String
    /// What is searched first.
    public let stripped: String
    public let sort: PlaceSort

    static let verbs = ["请帮我导航到", "请帮我导航去", "帮我导航到", "帮我导航去", "请导航到", "请导航去", "导航到", "导航去",
                        "请带我去", "带我去", "带我到", "开车去", "我要去", "我想去", "送我去", "送我到", "导航", "去"]
    static let nearby = ["附近的", "附近", "周边的", "周边", "最近的", "旁边的"]
    static let trailing: Set<Character> = ["吧", "啊", "呀", "呢", "。", "！", "？", "!", "?", ".", "，", ","]
    /// A category search ranks by distance even without 附近 (附近的加油站 and 加油站 mean the same).
    static let categories = ["加油站", "充电站", "充电桩", "停车场", "厕所", "洗手间", "卫生间", "服务区", "餐厅", "饭店",
                             "超市", "便利店", "银行", "ATM", "医院", "药店", "咖啡", "酒店", "4S店", "修车"]

    public init(_ text: String) {
        verbatim = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var core = verbatim
        if let verb = Self.verbs.first(where: { core.hasPrefix($0) }) { core.removeFirst(verb.count) }
        var near = false
        if let word = Self.nearby.first(where: { core.hasPrefix($0) }) {
            core.removeFirst(word.count)
            near = true
        }
        while let last = core.last, Self.trailing.contains(last) { core.removeLast() }
        core = core.trimmingCharacters(in: .whitespaces)
        stripped = core.isEmpty ? verbatim : core
        let category = Self.categories.contains { core.contains($0) }
        sort = near || category ? .distance : .weight
    }

    /// The queries to try in order: stripped, then verbatim when it differs.
    public var attempts: [String] { stripped == verbatim ? [verbatim] : [stripped, verbatim] }
}

/// F-16 §3: a fix is fresh for 30 s, usable (provisional) up to 10 min, and only with accuracy ≤ 2000 m.
public enum LocationQuality: Sendable, Hashable {
    case fresh, provisional

    public static func of(_ fix: LocationFix, at now: NovaInstant,
                          tuning: AmapWebTuning = AmapWebTuning()) -> LocationQuality? {
        guard fix.horizontalAccuracyMeters >= 0,
              fix.horizontalAccuracyMeters <= Double(tuning.locationMaxAccuracyMeters) else { return nil }
        let age = now - fix.timestamp
        if age <= tuning.locationFresh { return .fresh }
        if age <= tuning.locationProvisional { return .provisional }
        return nil
    }
}
