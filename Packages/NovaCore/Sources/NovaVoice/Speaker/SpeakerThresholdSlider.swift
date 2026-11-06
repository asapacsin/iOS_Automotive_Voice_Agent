import Foundation
import NovaPorts

/// F-04b §16 item 4 (T-013j): the saved calibration scores behind the 设置 slider's counts. Numbers only: no audio,
/// no embedding. Belongs to one voiceprint, like the §13 draft.
public struct SpeakerCalibrationResult: Codable, Sendable, Hashable {
    public var driver: [Double]
    public var others: [Double]
    public var enrolledAt: Date
    public var modelName: String
    public var dimension: Int

    public init(driver: [Double], others: [Double], enrolledAt: Date, modelName: String, dimension: Int) {
        self.driver = driver
        self.others = others
        self.enrolledAt = enrolledAt
        self.modelName = modelName
        self.dimension = dimension
    }

    public init(driver: [Double], others: [Double], for profile: SpeakerProfile) {
        self.init(driver: driver, others: others, enrolledAt: profile.enrolledAt, modelName: profile.modelName,
                  dimension: profile.dimension)
    }

    /// §16 item 4: used only when `enrolledAt`, `modelName` and `dimension` match the loaded profile.
    public func matches(_ profile: SpeakerProfile) -> Bool {
        enrolledAt == profile.enrolledAt && modelName == profile.modelName && dimension == profile.dimension
    }

    public var calibration: SpeakerCalibration { SpeakerCalibration(driver: driver, others: others) }
}

/// §16 item 11: a small store like `SpeakerCalibrationDraftStore`.
public protocol SpeakerCalibrationResultStore: Sendable {
    func load() -> SpeakerCalibrationResult?
    func save(_ result: SpeakerCalibrationResult) throws
    func delete() throws
}

/// §16 item 4: `Application Support/SpeakerLock/calibration-result.json`, the same protection, excluded from backup.
public struct FileSpeakerCalibrationResultStore: SpeakerCalibrationResultStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard() -> FileSpeakerCalibrationResultStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return FileSpeakerCalibrationResultStore(url: base.appendingPathComponent("SpeakerLock/calibration-result.json"))
    }

    public func load() -> SpeakerCalibrationResult? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpeakerCalibrationResult.self, from: data)
    }

    public func save(_ result: SpeakerCalibrationResult) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(result)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

/// §16 item 4: the Documents fallback for a calibration finished before the result file existed. Reads both scores
/// file formats (§5 item 4 `driver <score>`; §14 item 3 `clipMs=` then `driver <clip> whole=<whole>`). Pure.
public enum SpeakerScoresFileReader {
    public static let prefix = "speaker-calibration-"
    public static let suffix = ".txt"

    /// Driver and other scores; nil when the text holds none. In the §14 format the clip score is used.
    public static func parse(_ text: String) -> (driver: [Double], others: [Double])? {
        var driver: [Double] = [], others: [Double] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ")
            guard parts.count >= 2, let score = Double(parts[1]) else { continue }
            switch parts[0] {
            case "driver": driver.append(score)
            case "other": others.append(score)
            default: continue
            }
        }
        return driver.isEmpty && others.isEmpty ? nil : (driver, others)
    }

    /// The stamp of `speaker-calibration-<stamp>.txt`, written by `SpeakerLockService.writeScores` as ISO 8601 with
    /// `:` replaced by `-`.
    public static func stamp(_ fileName: String) -> Date? {
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let body = String(fileName.dropFirst(prefix.count).dropLast(suffix.count))
        guard let t = body.firstIndex(of: "T") else { return nil }
        let time = body[body.index(after: t)...].replacingOccurrences(of: "-", with: ":")
        return ISO8601DateFormatter().date(from: String(body[...t]) + time)
    }

    /// The newest scores file whose stamp is later than `enrolledAt`, read; nil with none usable.
    public static func newest(fileNames: [String], after enrolledAt: Date, read: (String) -> String?)
        -> (driver: [Double], others: [Double])? {
        let candidates = fileNames.compactMap { name in stamp(name).map { (name, $0) } }
            .filter { $0.1 > enrolledAt }
            .sorted { $0.1 > $1.1 }
        guard let name = candidates.first?.0, let text = read(name) else { return nil }
        return parse(text)
    }
}

/// §16 item 4: where the slider's scores come from. Pure apart from the store passed in.
public enum SpeakerCalibrationScores {
    /// The result file for this profile. A file that does not match, or cannot be read, is removed. With none, the
    /// Documents fallback is read once and written as the result file. nil = no usable scores.
    public static func load(_ store: any SpeakerCalibrationResultStore, profile: SpeakerProfile?,
                            documents: [String] = [], read: (String) -> String? = { _ in nil }) -> SpeakerCalibration? {
        guard let profile else { return nil }
        if let result = store.load(), result.matches(profile) { return result.calibration }
        try? store.delete()
        guard let found = SpeakerScoresFileReader.newest(fileNames: documents, after: profile.enrolledAt, read: read)
        else { return nil }
        let result = SpeakerCalibrationResult(driver: found.driver, others: found.others, for: profile)
        try? store.save(result)
        return result.calibration
    }

    /// §16 item 4: 「使用这个阈值」 also writes the scores to the result file.
    public static func save(_ calibration: SpeakerCalibration, profile: SpeakerProfile,
                            store: any SpeakerCalibrationResultStore) throws {
        try store.save(SpeakerCalibrationResult(driver: calibration.driver, others: calibration.others, for: profile))
    }
}

/// §16 item 8: `speaker-threshold old=<n> new=<n> source=slider|suggested`. Numbers only (I-8).
public struct SpeakerThresholdLine: Sendable, Hashable {
    public enum Source: String, Sendable, Hashable { case slider, suggested }

    public var old: Double
    public var new: Double
    public var source: Source

    public init(old: Double, new: Double, source: Source) {
        self.old = old
        self.new = new
        self.source = source
    }

    public var fields: String {
        "old=\(SpeakerCheckLine.number(old)) new=\(SpeakerCheckLine.number(new)) source=\(source.rawValue)"
    }

    public var logLine: String { "speaker-threshold \(fields)" }
}

/// §16 items 1–3, 6: the 设置 threshold slider's rules and texts. Pure apart from the store passed in.
public enum SpeakerThresholdSlider {
    public static let low = 0.30
    public static let high = 0.70
    /// §16 item 2.
    public static let hint = "调低：你更少被拒，别人更容易通过。调高：别人更难通过，你更容易被拒。"
    /// §16 item 4.
    public static let noScores = "没有校准分数，无法显示误拒和误通过"
    /// §16 item 3.
    public static let restoreButton = "恢复建议值"
    /// §16 item 6.
    public static let saveFailed = "阈值保存失败"

    /// §16 item 1: only for 「已录入」 (`ready`) with a saved threshold; hidden for `recalibrate` and every status
    /// without one.
    public static func visible(status: SpeakerLockStatus, profile: SpeakerProfile?) -> Bool {
        status == .ready && profile?.threshold != nil
    }

    /// §16 item 1: 0.30–0.70, widened to include the saved value.
    public static func range(saved: Double) -> ClosedRange<Double> {
        min(low, SpeakerCalibration.grid(saved))...max(high, SpeakerCalibration.grid(saved))
    }

    public static func title(_ value: Double) -> String { "声纹阈值 \(String(format: "%.2f", value))" }

    /// §16 item 3: the counts at the value under the finger, from the saved calibration scores.
    public static func countLine(_ calibration: SpeakerCalibration?, at value: Double) -> String {
        guard let calibration, !calibration.driver.isEmpty || !calibration.others.isEmpty else { return noScores }
        let row = calibration.row(at: snap(value))
        return "校准时：你的 \(calibration.driver.count) 句里被拒 \(row.falseRejects) 句，"
            + "别人的 \(calibration.others.count) 句里通过 \(row.falseAccepts) 句"
    }

    /// §16 item 3: 「校准建议 0.46」; nil (and no 恢复建议值) without usable scores.
    public static func suggestedText(_ calibration: SpeakerCalibration?) -> String? {
        calibration?.suggested.map { "校准建议 \(String(format: "%.2f", $0))" }
    }

    /// §16 item 6: snapped to the 0.01 grid.
    public static func snap(_ value: Double) -> Double { SpeakerCalibration.grid(value) }

    public struct Saved: Sendable, Hashable {
        /// Where the slider goes: the new value, or back to the saved one on a failed save.
        public let value: Double
        public let line: SpeakerThresholdLine?
        /// 「阈值保存失败」 on a failed save.
        public let error: String?
    }

    /// §16 item 6: the profile's threshold only, written atomically through the store. The slider never sets a
    /// threshold that 校准 has not set (§5 item 1): with none saved, nothing is written.
    public static func save(_ value: Double, source: SpeakerThresholdLine.Source,
                            store: any SpeakerProfileStore) -> Saved {
        guard var profile = store.load(), let old = profile.threshold else {
            return Saved(value: value, line: nil, error: saveFailed)
        }
        let new = snap(value)
        profile.threshold = new
        do {
            try store.save(profile)
            return Saved(value: new, line: SpeakerThresholdLine(old: old, new: new, source: source), error: nil)
        } catch {
            return Saved(value: old, line: nil, error: saveFailed)
        }
    }
}

/// §16 item 5: the last 20 `kind=speech` scores of this app run, in memory only, never saved. Numbers only (I-8).
public struct SpeakerRecentScores: Sendable, Hashable {
    public static let capacity = 20
    public static let header = "最近 20 次（任何说话的人）："
    public static let empty = "还没有分数"

    public struct Entry: Sendable, Hashable {
        public let score: Double
        public let accepted: Bool
    }

    /// Oldest first.
    public private(set) var entries: [Entry] = []

    public init() {}

    /// Speech checks with a score only; wake and stop checks are not kept.
    public mutating func add(_ line: SpeakerCheckLine) {
        guard line.kind == .speech, let score = line.score else { return }
        entries.append(Entry(score: score, accepted: line.result == .accepted))
        if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
    }

    /// Newest first, rejected ones marked: 「0.45✗ 0.52 0.40✗」; 「还没有分数」 with none.
    public var text: String {
        guard !entries.isEmpty else { return Self.empty }
        return entries.reversed().map { String(format: "%.2f", $0.score) + ($0.accepted ? "" : "✗") }
            .joined(separator: " ")
    }
}
