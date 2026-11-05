import Foundation

/// F-04b §13 (T-013g): calibration progress kept across closes and installs. Numbers only: no audio, no embedding.
public struct SpeakerCalibrationDraft: Codable, Sendable, Hashable {
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

    public init(_ calibration: SpeakerCalibration, for profile: SpeakerProfile) {
        self.init(driver: calibration.driver, others: calibration.others, enrolledAt: profile.enrolledAt,
                  modelName: profile.modelName, dimension: profile.dimension)
    }

    /// §13 item 2: the draft belongs to one voiceprint.
    public func matches(_ profile: SpeakerProfile) -> Bool {
        enrolledAt == profile.enrolledAt && modelName == profile.modelName && dimension == profile.dimension
    }

    public var calibration: SpeakerCalibration { SpeakerCalibration(driver: driver, others: others) }
}

/// §13 item 12: a small store like `SpeakerProfileStore`.
public protocol SpeakerCalibrationDraftStore: Sendable {
    func load() -> SpeakerCalibrationDraft?
    func save(_ draft: SpeakerCalibrationDraft) throws
    func delete() throws
}

/// §13 item 1: `Application Support/SpeakerLock/calibration.json`, the file handling copied from
/// `FileSpeakerProfileStore` (atomic, same protection, excluded from backup).
public struct FileSpeakerCalibrationDraftStore: SpeakerCalibrationDraftStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static func standard() -> FileSpeakerCalibrationDraftStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return FileSpeakerCalibrationDraftStore(url: base.appendingPathComponent("SpeakerLock/calibration.json"))
    }

    public func load() -> SpeakerCalibrationDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpeakerCalibrationDraft.self, from: data)
    }

    public func save(_ draft: SpeakerCalibrationDraft) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(draft)
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

/// §13 items 2–10: the rules around the draft. Pure apart from the stores passed in.
public enum SpeakerCalibrationProgress {
    /// §13 item 7.
    public static let saveFailedText = "进度保存失败，关闭后这句会丢失"
    /// §13 item 5.
    public static let startOverButton = "重新校准"
    public static let startOverQuestion = "清除已说的句子并重新开始？"
    /// §13 item 8.
    public static let reenrollWarning = "重新录入后要重新校准（两人各 20 句）。继续吗？"

    /// §13 item 2: the saved scores for this profile; a draft that does not match, or cannot be read, is removed.
    public static func load(_ store: any SpeakerCalibrationDraftStore, profile: SpeakerProfile?) -> SpeakerCalibration {
        if let profile, let draft = store.load(), draft.matches(profile) { return draft.calibration }
        try? store.delete()
        return SpeakerCalibration()
    }

    /// §13 item 3: 录入的人 while that person has under 20 lines, otherwise 其他人.
    public static func startsOnDriver(_ calibration: SpeakerCalibration) -> Bool {
        calibration.driver.count < SpeakerCalibration.minimumLines
    }

    /// §13 item 3: `lines[count % lines.count]` for the selected person.
    public static func line(_ calibration: SpeakerCalibration, driver: Bool) -> String {
        let lines = SpeakerCalibration.lines
        return lines[(driver ? calibration.driver.count : calibration.others.count) % lines.count]
    }

    /// §13 item 1: one accepted line, saved straight away. Returns false when the write failed (item 7); the score
    /// is kept in `calibration` either way.
    @discardableResult
    public static func add(_ score: Double, driver: Bool, to calibration: inout SpeakerCalibration,
                           profile: SpeakerProfile, store: any SpeakerCalibrationDraftStore) -> Bool {
        if driver { calibration.driver.append(score) } else { calibration.others.append(score) }
        do {
            try store.save(SpeakerCalibrationDraft(calibration, for: profile))
            return true
        } catch {
            return false
        }
    }

    /// §13 item 4: the 设置 row, only with a matching draft that has any lines.
    public static func settingsRow(_ store: any SpeakerCalibrationDraftStore, profile: SpeakerProfile?) -> String? {
        guard let profile, let draft = store.load(), draft.matches(profile),
              !draft.driver.isEmpty || !draft.others.isEmpty else { return nil }
        let n = SpeakerCalibration.minimumLines
        return "校准进度：录入的人 \(draft.driver.count) / \(n)，其他人 \(draft.others.count) / \(n)"
    }

    /// §13 item 5: empties the draft; the saved threshold is not touched.
    public static func startOver(_ store: any SpeakerCalibrationDraftStore) throws { try store.delete() }

    /// §13 item 6: saves the threshold, writes the scores file, then removes the draft. If saving the profile
    /// fails, the draft stays (and the error is thrown).
    public static func finish(_ threshold: Double, calibration: SpeakerCalibration, profile: SpeakerProfile,
                              at date: Date, profileStore: any SpeakerProfileStore,
                              draftStore: any SpeakerCalibrationDraftStore,
                              writeScores: (SpeakerCalibration) -> Void) throws -> SpeakerProfile {
        var updated = profile
        updated.threshold = threshold
        updated.calibratedAt = date
        try profileStore.save(updated)
        writeScores(calibration)
        try? draftStore.delete()
        return updated
    }

    /// §13 item 8: warn before 重新录入 with a saved threshold or any draft lines.
    public static func warnBeforeReenroll(profile: SpeakerProfile?, calibration: SpeakerCalibration) -> Bool {
        profile?.threshold != nil || !calibration.driver.isEmpty || !calibration.others.isEmpty
    }
}
