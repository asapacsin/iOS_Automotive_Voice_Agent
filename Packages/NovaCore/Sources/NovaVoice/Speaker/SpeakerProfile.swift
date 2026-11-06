import Foundation
import NovaKit
import NovaPorts

/// F-04b §4 item 4 (T-013e): the one enrolled voice. Stored on the phone only (§4 item 7).
public struct SpeakerProfile: Codable, Sendable, Hashable {
    /// Unit-length average of the enrollment sentences' embeddings.
    public var embedding: [Float]
    public var modelName: String
    public var dimension: Int
    /// From §5 calibration; kept in the file but not used since §16 item 6 (T-013j): the cohort sets the threshold.
    public var threshold: Double?
    public var enrolledAt: Date
    public var calibratedAt: Date?
    /// §14 item 4 (T-013h): calibration fields. Optional so old files still load; not used since §16 item 6.
    public var calibrationClipMs: Int?
    public var calibrationDriverLines: Int?
    public var calibrationOtherLines: Int?

    public init(embedding: [Float], modelName: String, dimension: Int, threshold: Double? = nil, enrolledAt: Date,
                calibratedAt: Date? = nil, calibrationClipMs: Int? = nil, calibrationDriverLines: Int? = nil,
                calibrationOtherLines: Int? = nil) {
        self.embedding = embedding
        self.modelName = modelName
        self.dimension = dimension
        self.threshold = threshold
        self.enrolledAt = enrolledAt
        self.calibratedAt = calibratedAt
        self.calibrationClipMs = calibrationClipMs
        self.calibrationDriverLines = calibrationDriverLines
        self.calibrationOtherLines = calibrationOtherLines
    }

    /// §4 item 6: a profile of another model (name or dimension) is invalid.
    public func valid(modelName: String, dimension: Int) -> Bool {
        self.modelName == modelName && self.dimension == dimension && embedding.count == dimension
    }

    public func score(_ embedding: [Float]) -> Double? { SpeakerScore.cosine(self.embedding, embedding) }
}

public protocol SpeakerProfileStore: Sendable {
    func load() -> SpeakerProfile?
    func save(_ profile: SpeakerProfile) throws
    func delete() throws
}

/// One JSON file under Application Support, `completeUntilFirstUserAuthentication`, excluded from backup (§4 item 4).
public struct FileSpeakerProfileStore: SpeakerProfileStore {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `Application Support/SpeakerLock/profile.json`.
    public static func standard() -> FileSpeakerProfileStore? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return FileSpeakerProfileStore(url: base.appendingPathComponent("SpeakerLock/profile.json"))
    }

    public func load() -> SpeakerProfile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SpeakerProfile.self, from: data)
    }

    public func save(_ profile: SpeakerProfile) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(profile)
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

/// §3 item 2, §16 items 6–7: what 设置 shows.
public enum SpeakerLockStatus: Sendable, Hashable {
    case notEnrolled
    /// §16 item 6: model ready, enrolled with it, and a cohort of `cohort` voices made with the same model.
    case ready(cohort: Int)
    /// §4 item 6: enrolled with another model; re-enroll.
    case invalidModel
    /// §3 item 4: the model cannot load.
    case modelUnavailable
    /// §16 item 7 (T-013j): the cohort file is missing or for another model; the switch cannot turn on.
    case cohortMissing

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var text: String {
        switch self {
        case .notEnrolled: "未录入"
        case .ready(let n): "已录入 · 和 \(n) 个公开声音比较，自动区分"
        case .invalidModel: "声纹模型已更换，请重新录入"
        case .modelUnavailable: "声纹模型不可用"
        case .cohortMissing: "声纹对比数据缺失"
        }
    }
}

/// §3 items 1, 4; §4 items 5–6; §16 items 3, 6–7: when the lock may be on. Pure.
/// §16 item 6 (T-013j): no calibration; a profile's `threshold`, `calibratedAt` and calibration fields are not used.
public enum SpeakerLockPolicy {
    /// What turning the switch on leads to.
    public enum OnRequest: Sendable, Hashable {
        /// The cohort file's threshold (§16 item 3).
        case on(threshold: Double)
        case openEnrollment
        case modelUnavailable
        case cohortMissing
    }

    public static let switchText = "开：只有录入的声音能唤醒和使用小诺。说话重叠时可能听不准。"
    /// §6 item 11.
    public static let unavailableChip = "声纹不可用，可在设置关闭"
    /// §16 item 7, §12 item 4: a switch that is on with no usable cohort stays locked and fails closed. No score is
    /// ever at or above this, and the scorer reports a failure.
    public static let failClosedThreshold = Double.infinity

    /// §4 item 6: a switch that is on is turned off for this (the voiceprint and file stay).
    public static func turnsSwitchOff(_ status: SpeakerLockStatus) -> Bool { status == .invalidModel }

    /// §16 item 6: the cohort's `modelSha256` matches the loaded model (and its vectors fit the profile).
    public static func cohortMatches(_ cohort: SpeakerCohortMeta?, profile: SpeakerProfile,
                                     modelSha256: String) -> Bool {
        guard let cohort else { return false }
        return cohort.matches(modelSha256: modelSha256) && cohort.dimension == profile.dimension
    }

    /// `model`: the loaded model's name and dimension; nil when it cannot load. `cohort`: the loaded cohort file's
    /// metadata; nil when missing. `modelSha256`: the loaded model's (the pinned value, §12 item 3).
    public static func status(profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                              cohort: SpeakerCohortMeta?,
                              modelSha256: String = SpeakerModelPin.sha256) -> SpeakerLockStatus {
        guard let model else { return .modelUnavailable }
        guard let profile else { return .notEnrolled }
        guard profile.valid(modelName: model.name, dimension: model.dimension) else { return .invalidModel }
        guard cohortMatches(cohort, profile: profile, modelSha256: modelSha256), let cohort else {
            return .cohortMissing
        }
        return .ready(cohort: cohort.speakers)
    }

    public static func requestOn(profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                                 cohort: SpeakerCohortMeta?,
                                 modelSha256: String = SpeakerModelPin.sha256) -> OnRequest {
        switch status(profile: profile, model: model, cohort: cohort, modelSha256: modelSha256) {
        case .modelUnavailable: return .modelUnavailable
        case .notEnrolled, .invalidModel: return .openEnrollment
        case .cohortMissing: return .cohortMissing
        case .ready: return .on(threshold: cohort!.threshold)
        }
    }

    /// The threshold the live pipeline uses: the switch on and a ready lock; else nil (lock off).
    /// §12 item 4: a model that is not usable right now (downloading, failed) keeps an enrolled lock on, so scoring
    /// fails closed (§6 item 11) instead of the lock quietly turning off. §16 item 7: so does a missing cohort.
    public static func threshold(switchOn: Bool, profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                                 cohort: SpeakerCohortMeta?,
                                 modelSha256: String = SpeakerModelPin.sha256) -> Double? {
        guard switchOn, let profile else { return nil }
        let matched = cohortMatches(cohort, profile: profile, modelSha256: modelSha256) ? cohort?.threshold : nil
        if model == nil { return matched ?? failClosedThreshold }
        switch status(profile: profile, model: model, cohort: cohort, modelSha256: modelSha256) {
        case .ready: return matched
        case .cohortMissing: return failClosedThreshold
        case .notEnrolled, .invalidModel, .modelUnavailable: return nil
        }
    }
}

/// §16 item 6 (T-013j): 设置 has no 校准. The buttons under 「声纹」 for each status. Pure.
public enum SpeakerLockSettings {
    public static func buttons(_ status: SpeakerLockStatus) -> [String] {
        switch status {
        case .notEnrolled: ["录入声纹"]
        case .invalidModel: ["录入声纹", "删除声纹"]
        case .ready, .cohortMissing: ["重新录入", "删除声纹"]
        case .modelUnavailable: []
        }
    }
}

/// §16 item 6: the calibration draft of §13 (`Application Support/SpeakerLock/calibration.json`) is deleted on first
/// launch; no calibration file is written any more.
public enum SpeakerLegacyCalibration {
    public static func standardDraftURL() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SpeakerLock/calibration.json")
    }

    /// True when a file was removed.
    @discardableResult
    public static func removeDraft(at url: URL?) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

/// §4 item 3: one enrollment sentence, measured on the live capture path. Raw audio is not kept here.
public struct EnrollmentTake: Sendable, Hashable {
    /// Confirmed speech (F-04a) in the take.
    public var speech: NovaDuration
    /// Samples at full scale (|x| ≥ 32 700).
    public var clippedSamples: Int
    /// The noise bed between words, dB (the gate's scale).
    public var noiseDb: Int
    public var embedding: [Float]

    public init(speech: NovaDuration, clippedSamples: Int, noiseDb: Int, embedding: [Float]) {
        self.speech = speech
        self.clippedSamples = clippedSamples
        self.noiseDb = noiseDb
        self.embedding = embedding
    }

    /// Measures a take's samples (clipping only; speech and noise come from the gate).
    public static func clipped(_ frames: [PCMFrame16k]) -> Int {
        frames.reduce(0) { $0 + $1.samples.filter { abs(Int($0)) >= 32_700 }.count }
    }
}

public enum EnrollmentProblem: String, Sendable, Hashable, Error {
    case wrongCount, tooShort, clipped, noisy, disagree, noEmbedding

    /// §4 item 3: names the problem and asks for a retry.
    public var text: String {
        switch self {
        case .wrongCount: "需要读完 3 句，请重试。"
        case .tooShort: "说话时间不够 8 秒，请慢一点、完整地读，再试一次。"
        case .clipped: "声音太大，有破音。请离手机远一点再试。"
        case .noisy: "周围太吵。请在安静的车里（停车、关窗、关音乐）再试。"
        case .disagree: "3 句听起来不像同一个人，可能有别人说话或有一句没录好。请重试。"
        case .noEmbedding: "没能提取声纹，请重试。"
        }
    }
}

/// §4 items 3, 5: checks before saving. Constants are iOS choices, re-tuned from device runs.
public enum SpeakerEnrollment {
    /// About 15 s read aloud in total (§4 item 1).
    public static let sentences = [
        "今天天气不错，阳光很好，我们吃完午饭以后一起开车出去走走吧。",
        "帮我导航到最近的加油站，顺便看看附近有没有可以停车的地方。",
        "把空调温度调到二十四度，风量小一点，再放一首轻松的音乐。",
    ]
    public static let minSpeech = NovaDuration.seconds(8)
    public static let maxClippedSamples = 16
    public static let maxNoiseDb = 55
    /// Pairwise agreement of the 3 sentences' embeddings (cosine).
    public static let minAgreement = 0.5

    public static func check(_ takes: [EnrollmentTake], modelName: String, dimension: Int, at date: Date)
        -> Result<SpeakerProfile, EnrollmentProblem> {
        guard takes.count == sentences.count else { return .failure(.wrongCount) }
        guard takes.reduce(NovaDuration.zero, { $0 + $1.speech }) >= minSpeech else { return .failure(.tooShort) }
        guard takes.allSatisfy({ $0.clippedSamples <= maxClippedSamples }) else { return .failure(.clipped) }
        guard takes.allSatisfy({ $0.noiseDb <= maxNoiseDb }) else { return .failure(.noisy) }
        guard takes.allSatisfy({ $0.embedding.count == dimension && dimension > 0 }) else { return .failure(.noEmbedding) }
        for i in takes.indices {
            for j in takes.indices where j > i {
                guard let c = SpeakerScore.cosine(takes[i].embedding, takes[j].embedding), c >= minAgreement else {
                    return .failure(.disagree)
                }
            }
        }
        guard let mean = SpeakerScore.average(takes.map(\.embedding)) else { return .failure(.noEmbedding) }
        return .success(SpeakerProfile(embedding: mean, modelName: modelName, dimension: dimension, enrolledAt: date))
    }

    /// §4 item 5: a re-enrollment replaces the file only after the new one passes; the old one is kept otherwise.
    @discardableResult
    public static func enroll(_ takes: [EnrollmentTake], modelName: String, dimension: Int, at date: Date,
                              store: any SpeakerProfileStore) -> Result<SpeakerProfile, EnrollmentProblem> {
        let result = check(takes, modelName: modelName, dimension: dimension, at: date)
        if case .success(let profile) = result {
            do { try store.save(profile) } catch { return .failure(.noEmbedding) }
        }
        return result
    }

    /// §4 item 5, §3 item 5: delete (also from the wipe-all); the caller turns the switch off.
    public static func delete(store: any SpeakerProfileStore) throws {
        try store.delete()
    }
}
