import Foundation
import NovaKit
import NovaPorts

/// F-04b §4 item 4 (T-013e): the one enrolled voice. Stored on the phone only (§4 item 7).
public struct SpeakerProfile: Codable, Sendable, Hashable {
    /// Unit-length average of the enrollment sentences' embeddings.
    public var embedding: [Float]
    public var modelName: String
    public var dimension: Int
    /// nil until 校准 sets it: there is no built-in threshold (§5 item 1).
    public var threshold: Double?
    public var enrolledAt: Date
    public var calibratedAt: Date?
    /// §14 item 4 (T-013h): the clip length (ms) the threshold was measured on, and the lines behind it. Optional so
    /// old files still load; a threshold without the current clip length is not used (§14 item 5).
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

/// §3 item 2: what 设置 shows.
public enum SpeakerLockStatus: Sendable, Hashable {
    case notEnrolled, enrolledUncalibrated, ready
    /// §4 item 6: enrolled with another model; re-enroll.
    case invalidModel
    /// §3 item 4: the model cannot load.
    case modelUnavailable
    /// §14 item 5 (T-013h): a threshold measured on another clip length (or the old whole-line way): not used.
    case recalibrate

    public var text: String {
        switch self {
        case .notEnrolled: "未录入"
        case .enrolledUncalibrated: "已录入，未校准"
        case .ready: "已录入"
        case .invalidModel: "声纹模型已更换，请重新录入"
        case .modelUnavailable: "声纹模型不可用"
        case .recalibrate: "已录入，需要重新校准"
        }
    }
}

/// §3 items 1, 4; §4 items 5–6; §5 item 1: when the lock may be on. Pure.
public enum SpeakerLockPolicy {
    /// What turning the switch on leads to.
    public enum OnRequest: Sendable, Hashable {
        case on(threshold: Double)
        case openEnrollment
        case openCalibration
        case modelUnavailable
    }

    public static let switchText = "开：只有录入的声音能唤醒和使用小诺。说话重叠时可能听不准。"
    /// §6 item 11.
    public static let unavailableChip = "声纹不可用，可在设置关闭"
    /// §14 item 5: shown under the `recalibrate` status text.
    public static let recalibrateNote = "校准方法已更新：请重新校准一次（两人各 20 句），声纹不用重新录入。"

    /// §4 item 6, §14 item 5: a switch that is on is turned off for these (the voiceprint and file stay).
    public static func turnsSwitchOff(_ status: SpeakerLockStatus) -> Bool {
        status == .invalidModel || status == .recalibrate
    }

    /// §14 item 5: the threshold was measured on the clip the live check scores now.
    public static func currentClip(_ profile: SpeakerProfile, clipMs: Int) -> Bool {
        profile.calibrationClipMs == clipMs
    }

    /// `model`: the loaded model's name and dimension; nil when it cannot load.
    /// `clipMs`: the live check's clip length now (`SpeakerVerifyClip.clipMs`).
    public static func status(profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                              clipMs: Int = SpeakerVerifyClip.clipMs()) -> SpeakerLockStatus {
        guard let model else { return .modelUnavailable }
        guard let profile else { return .notEnrolled }
        guard profile.valid(modelName: model.name, dimension: model.dimension) else { return .invalidModel }
        guard profile.threshold != nil else { return .enrolledUncalibrated }
        return currentClip(profile, clipMs: clipMs) ? .ready : .recalibrate
    }

    public static func requestOn(profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                                 clipMs: Int = SpeakerVerifyClip.clipMs()) -> OnRequest {
        switch status(profile: profile, model: model, clipMs: clipMs) {
        case .modelUnavailable: return .modelUnavailable
        case .notEnrolled, .invalidModel: return .openEnrollment
        case .enrolledUncalibrated, .recalibrate: return .openCalibration
        case .ready: return .on(threshold: profile!.threshold!)
        }
    }

    /// The threshold the live pipeline uses: the switch on and a calibrated, valid profile; else nil (lock off).
    /// §12 item 4 (T-013f): a model that is not usable right now (downloading, failed) keeps a calibrated lock on,
    /// so scoring fails closed (§6 item 11) instead of the lock quietly turning off.
    /// §14 item 5: a threshold of another clip length is never used, with or without the model.
    public static func threshold(switchOn: Bool, profile: SpeakerProfile?, model: (name: String, dimension: Int)?,
                                 clipMs: Int = SpeakerVerifyClip.clipMs()) -> Double? {
        guard switchOn else { return nil }
        if model == nil {
            guard let profile, currentClip(profile, clipMs: clipMs) else { return nil }
            return profile.threshold
        }
        guard case .on(let t) = requestOn(profile: profile, model: model, clipMs: clipMs) else { return nil }
        return t
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
    /// The new profile has no threshold: it must be calibrated again.
    /// §13 item 9: a failed enrollment keeps the old profile, threshold and draft; a successful one removes the draft.
    @discardableResult
    public static func enroll(_ takes: [EnrollmentTake], modelName: String, dimension: Int, at date: Date,
                              store: any SpeakerProfileStore, draftStore: (any SpeakerCalibrationDraftStore)? = nil)
        -> Result<SpeakerProfile, EnrollmentProblem> {
        let result = check(takes, modelName: modelName, dimension: dimension, at: date)
        if case .success(let profile) = result {
            do { try store.save(profile) } catch { return .failure(.noEmbedding) }
            try? draftStore?.delete()
        }
        return result
    }

    /// §4 item 5, §3 item 5: delete (also from the wipe-all); the caller turns the switch off. §13 item 10: the
    /// draft goes too.
    public static func delete(store: any SpeakerProfileStore, draftStore: (any SpeakerCalibrationDraftStore)? = nil) throws {
        try? draftStore?.delete()
        try store.delete()
    }
}

/// §5 items 2–4: 校准 from scores only (no audio kept). Pure.
public struct SpeakerCalibration: Sendable, Hashable {
    public static let minimumLines = 20
    /// §5 item 2: everyday lines, not the enrollment sentences. Each person reads them all (20).
    public static let lines = [
        "打开空调", "第一个", "导航回家", "放首歌", "今天天气怎么样", "关掉音乐", "附近有没有停车场", "温度调低一点",
        "打电话给妈妈", "还有多远", "换一首", "开一下车窗", "前面堵不堵", "我有点困", "找个加油站", "声音大一点",
        "取消导航", "现在几点了", "去公司", "谢谢你",
    ]
    /// Candidate thresholds are on this grid.
    public static let step = 0.01

    public struct Row: Sendable, Hashable {
        public let threshold: Double
        public let falseRejects: Int
        public let falseAccepts: Int
    }

    /// §14 item 2: clip scores (`SpeakerVerifyClip`); these drive the counts, the table and the suggestion.
    public var driver: [Double]
    public var others: [Double]
    /// §14 item 2: whole-take scores, for the scores file only (aligned with `driver` / `others`; nil = not scored).
    public var driverWhole: [Double?]
    public var othersWhole: [Double?]
    /// §14 item 3: the clip length the lines were scored on.
    public var clipMs: Int

    public init(driver: [Double] = [], others: [Double] = [], driverWhole: [Double?] = [], othersWhole: [Double?] = [],
                clipMs: Int = SpeakerVerifyClip.clipMs()) {
        self.driver = driver
        self.others = others
        self.driverWhole = driverWhole
        self.othersWhole = othersWhole
        self.clipMs = clipMs
    }

    public var enough: Bool { driver.count >= Self.minimumLines && others.count >= Self.minimumLines }

    /// Accepted when score ≥ threshold.
    public func row(at t: Double) -> Row {
        Row(threshold: t, falseRejects: driver.filter { $0 < t }.count, falseAccepts: others.filter { $0 >= t }.count)
    }

    static func grid(_ v: Double) -> Double { (v / step).rounded() * step }

    /// Thresholds from the lowest score to just above the highest, on the grid.
    public var rows: [Row] {
        let all = driver + others
        guard let lo = all.min(), let hi = all.max() else { return [] }
        var out: [Row] = []
        var t = Self.grid((lo / Self.step).rounded(.down) * Self.step)
        while t <= hi + Self.step + 1e-9 {
            out.append(row(at: t))
            t = Self.grid(t + Self.step)
        }
        return out
    }

    /// The lowest threshold with no false accepts; nil before enough lines.
    public var suggested: Double? {
        guard enough, let maxOther = others.max() else { return nil }
        // The grid point strictly above every other person's score.
        var t = Self.grid((maxOther / Self.step).rounded(.down) * Self.step)
        while t <= maxOther { t = Self.grid(t + Self.step) }
        return t
    }

    /// 95% upper bound of the true rate when `count` of `n` happened (exact for 0: 1 − 0.05^(1/n)).
    public static func upperBound(zeroOf n: Int) -> Double { n > 0 ? 1 - pow(0.05, 1 / Double(n)) : 1 }

    /// §5 item 3: what the screen says about the evidence.
    public var caveat: String {
        let n = others.count
        let pct = Int((Self.upperBound(zeroOf: n) * 100).rounded())
        return "别人说的 \(n) 句里 0 句通过，这只是很弱的证据：真实的误通过率仍可能高达约 \(pct)%。"
    }

    /// §5 item 4, §14 item 3: the local scores file (Documents). First `clipMs=1000`, then
    /// `driver <clip> whole=<whole>` / `other <clip> whole=<whole>` per line. Numbers only.
    public var scoresFile: String {
        func lines(_ name: String, _ clip: [Double], _ whole: [Double?]) -> [String] {
            clip.indices.map { i in
                let w = i < whole.count ? whole[i] : nil
                return "\(name) \(SpeakerCheckLine.number(clip[i])) whole=\(w.map(SpeakerCheckLine.number) ?? "none")"
            }
        }
        return (["clipMs=\(clipMs)"] + lines("driver", driver, driverWhole) + lines("other", others, othersWhole))
            .joined(separator: "\n") + "\n"
    }
}
