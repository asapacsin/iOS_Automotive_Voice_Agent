import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it, so order and gaps show.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func numbers(_ frames: [PCMFrame16k]?) -> [Int]? { frames?.map { Int($0.samples[0]) } }
private func record(_ id: Int) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: .silence, sentToModel: true, muteReason: .none, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
/// A scripted sent utterance: start, `frames` of audio, stop, record, stream end.
private func utterance(_ id: Int, frames: Int) -> [[UplinkGateOutput]] {
    var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true), .audio(f(1))]]
    for n in 2..<(frames + 1) { steps.append([.audio(f(n))]) }
    steps.append([.speechStopped(.normal), .utterance(record(id)), .streamEnd])
    return steps
}

private final class ProfileBox: SpeakerProfileStore, @unchecked Sendable {
    var profile: SpeakerProfile?
    init(_ p: SpeakerProfile?) { profile = p }
    func load() -> SpeakerProfile? { profile }
    func save(_ p: SpeakerProfile) throws { profile = p }
    func delete() throws { profile = nil }
}

@Suite("T-013h F-04b §14 calibrate on the live clip, show what the lock did")
struct SpeakerCalibrationLiveClipTests {
    static let at = Date(timeIntervalSince1970: 1_800_000_000)
    static let profile = SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3, enrolledAt: at)
    static let model = (name: "campplus", dimension: 3)

    func tempStore() -> FileSpeakerCalibrationDraftStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)")
        return FileSpeakerCalibrationDraftStore(url: dir.appendingPathComponent("SpeakerLock/calibration.json"))
    }

    /// The frames `SpeakerHold` sends the scorer for one sent utterance.
    func heldRequest(frames: Int) -> [PCMFrame16k]? {
        var hold = SpeakerHold()
        _ = hold.setLock(threshold: 0.5)
        var request: SpeakerScoreRequest?
        for step in utterance(1, frames: frames) { if let r = hold.frame(step).request { request = r } }
        return request?.frames
    }

    @Test("T-013h F-04b row 37: SpeakerVerifyClip gives 1.0 s of 2.5 s, all of 0.8 s, nil for 0.4 s; SpeakerHold scores the same frames")
    func clipRule() {
        let long = (1...250).map(f), mid = (1...80).map(f), short = (1...40).map(f)
        #expect(numbers(SpeakerVerifyClip.frames(long, tuning: SpeakerTuning())) == Array(1...100))
        #expect(numbers(SpeakerVerifyClip.frames(mid, tuning: SpeakerTuning())) == Array(1...80))
        #expect(SpeakerVerifyClip.frames(short, tuning: SpeakerTuning()) == nil)
        #expect(SpeakerVerifyClip.frames(long) == heldRequest(frames: 250))
        #expect(SpeakerVerifyClip.frames(mid) == heldRequest(frames: 80))
        #expect(heldRequest(frames: 40) == nil)
        #expect(SpeakerVerifyClip.clipMs() == 1000)
        // One tuning drives both: a shorter minVerifySpeech changes the clip too.
        let t = SpeakerTuning(minVerifySpeech: .milliseconds(600))
        #expect(numbers(SpeakerVerifyClip.frames(long, tuning: t)) == Array(1...60))
    }

    @Test("F-04b row 38: a 2.5 s take: the clip score goes into the draft and counts; the scores file has both numbers after clipMs=1000")
    func calibrationScoresClip() throws {
        let store = tempStore()
        let take = (1...250).map(f)
        let clips = try #require(SpeakerCalibrationProgress.clips(take))
        #expect(clips.clip.count == 100 && clips.whole.count == 250)
        #expect(SpeakerCalibrationProgress.clips((1...40).map(f)) == nil)  // 「没听到说话」, nothing saved
        // A fake scorer: score depends on the clip length, so the right clip shows.
        let score = { (frames: [PCMFrame16k]) in Double(frames.count) / 1000 }
        var c = SpeakerCalibration()
        #expect(SpeakerCalibrationProgress.add(score(clips.clip), whole: score(clips.whole), driver: true, to: &c,
                                               profile: Self.profile, store: store))
        #expect(c.driver == [0.1] && c.driverWhole == [0.25])
        let loaded = SpeakerCalibrationProgress.load(store, profile: Self.profile)
        #expect(loaded.driver == [0.1] && loaded.driver.count == 1 && loaded.driverWhole == [0.25])
        #expect(store.load()?.clipMs == 1000)
        SpeakerCalibrationProgress.add(0.3, whole: 0.35, driver: false, to: &c, profile: Self.profile, store: store)
        #expect(c.scoresFile == "clipMs=1000\ndriver 0.1 whole=0.25\nother 0.3 whole=0.35\n")
        #expect(c.row(at: 0.2).falseRejects == 1)  // the table uses the clip score, not the whole one
    }

    @Test("F-04b row 39: 使用这个阈值 with 21 and 20 lines records the threshold, its clip and its lines; draft removed")
    func finishRecordsClip() throws {
        let store = tempStore()
        let profiles = ProfileBox(Self.profile)
        let c = SpeakerCalibration(driver: Array(repeating: 0.7, count: 21), others: Array(repeating: 0.2, count: 20))
        try store.save(SpeakerCalibrationDraft(c, for: Self.profile))
        let saved = try SpeakerCalibrationProgress.finish(0.46, calibration: c, profile: Self.profile, at: Self.at,
                                                          profileStore: profiles, draftStore: store) { _ in }
        #expect(saved.threshold == 0.46 && saved.calibratedAt == Self.at)
        #expect(saved.calibrationClipMs == 1000 && saved.calibrationDriverLines == 21 && saved.calibrationOtherLines == 20)
        #expect(profiles.profile == saved && store.load() == nil)
        #expect(SpeakerLockPolicy.status(profile: saved, model: Self.model) == .ready)
    }

    @Test("F-04b row 40: an old threshold (no or another clipMs) is recalibrate, not used, switch off, file unchanged; 1000 is ready")
    func oldThresholdNotUsed() throws {
        var old = Self.profile
        old.threshold = 0.46
        old.calibratedAt = Self.at
        let profileURL = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString)/profile.json")
        let file = FileSpeakerProfileStore(url: profileURL)
        try file.save(old)
        let before = try Data(contentsOf: profileURL)
        let loaded = try #require(file.load())  // today's file (no calibrationClipMs) still loads
        #expect(loaded.calibrationClipMs == nil)
        let status = SpeakerLockPolicy.status(profile: loaded, model: Self.model)
        #expect(status == .recalibrate)
        #expect(status.text == "已录入，需要重新校准")
        #expect(SpeakerLockPolicy.recalibrateNote == "校准方法已更新：请重新校准一次（两人各 20 句），声纹不用重新录入。")
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: loaded, model: Self.model) == nil)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: loaded, model: nil) == nil)
        #expect(SpeakerLockPolicy.requestOn(profile: loaded, model: Self.model) == .openCalibration)
        #expect(SpeakerLockPolicy.turnsSwitchOff(status))
        #expect(try Data(contentsOf: profileURL) == before)  // voiceprint, enrolledAt and old threshold stay
        var half = old
        half.calibrationClipMs = 500
        #expect(SpeakerLockPolicy.status(profile: half, model: Self.model) == .recalibrate)
        var current = old
        current.calibrationClipMs = 1000
        #expect(SpeakerLockPolicy.status(profile: current, model: Self.model) == .ready)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: current, model: Self.model) == 0.46)
        #expect(!SpeakerLockPolicy.turnsSwitchOff(.ready))
        // A draft without clipMs (from before) does not match and is removed.
        let store = tempStore()
        try store.save(SpeakerCalibrationDraft(driver: [0.5], others: [], enrolledAt: Self.at, modelName: "campplus",
                                               dimension: 3, clipMs: nil))
        #expect(SpeakerCalibrationProgress.load(store, profile: current).driver.isEmpty)
        #expect(store.load() == nil)
        try store.save(SpeakerCalibrationDraft(driver: [0.5], others: [], enrolledAt: Self.at, modelName: "campplus",
                                               dimension: 3, clipMs: 500))
        #expect(SpeakerCalibrationProgress.load(store, profile: current).driver.isEmpty && store.load() == nil)
    }

    @Test("F-04b row 41: the calibrated row and the old-method row from the profile, zone Asia/Macau")
    func summaryTexts() throws {
        let macau = try #require(TimeZone(identifier: "Asia/Macau"))
        let at = try #require(ISO8601DateFormatter().date(from: "2026-11-06T01:02:37Z"))
        var p = Self.profile
        p.threshold = 0.46
        p.calibratedAt = at
        p.calibrationClipMs = 1000
        p.calibrationDriverLines = 21
        p.calibrationOtherLines = 20
        #expect(SpeakerCalibrationSummary.text(profile: p, status: .ready, timeZone: macau)
            == "已校准：11月6日，阈值 0.46（录入的人 21 句，其他人 20 句）")
        #expect(SpeakerCalibrationSummary.text(profile: p, status: .recalibrate, timeZone: macau)
            == "上次校准：11月6日，阈值 0.46（旧方法，已停用）")
        #expect(SpeakerCalibrationSummary.text(profile: Self.profile, status: .enrolledUncalibrated, timeZone: macau) == nil)
    }

    @Test("F-04b row 42: a notice for rejected and unknown speech and a rejected wake word; none for accepted, stop phrases, lock off")
    func rejectionNotice() {
        func speechLine(frames: Int, score: Double?, locked: Bool = true) -> [SpeakerCheckLine] {
            var hold = SpeakerHold()
            if locked { _ = hold.setLock(threshold: 0.5) }
            var request: SpeakerScoreRequest?
            for step in utterance(1, frames: frames) {
                if let r = hold.frame(step).request { request = r }
                if let r = request, let score { _ = hold.result(.score(score, scoreMs: 5), utterance: r.utterance,
                                                                generation: r.generation); request = nil }
            }
            return hold.takeChecks()
        }
        func phrase(_ kind: SpeakerCheckKind, score: Double, locked: Bool = true) -> SpeakerCheckLine? {
            var check = SpeakerPhraseCheck(kind: kind)
            if locked { check.setLock(threshold: 0.5) }
            guard case .verify(let r) = check.hit(recent: (1...200).map(f)) else { return nil }
            return check.result(.score(score, scoreMs: 5), check: r.utterance, generation: r.generation, waitMs: 5)?.line
        }
        let rejected = speechLine(frames: 150, score: 0.2)
        #expect(rejected.map(\.result) == [.rejected])
        #expect(rejected.compactMap(SpeakerRejectionNotice.text) == ["没听出是录入的声音，这句没有发送"])
        let unknown = speechLine(frames: 30, score: nil)
        #expect(unknown.map(\.result) == [.unknown])
        #expect(unknown.compactMap(SpeakerRejectionNotice.text) == [SpeakerRejectionNotice.speech])
        #expect(speechLine(frames: 150, score: 0.9).compactMap(SpeakerRejectionNotice.text).isEmpty)
        #expect(phrase(.wake, score: 0.2).flatMap(SpeakerRejectionNotice.text) == "没听出是录入的声音，没有唤醒")
        #expect(phrase(.wake, score: 0.9).flatMap(SpeakerRejectionNotice.text) == nil)
        #expect(phrase(.stop, score: 0.2).map(\.result) == .rejected)
        #expect(phrase(.stop, score: 0.2).flatMap(SpeakerRejectionNotice.text) == nil)
        #expect(speechLine(frames: 150, score: 0.2, locked: false).isEmpty)  // lock off: no lines, no notice
        #expect(phrase(.wake, score: 0.2, locked: false) == nil)

        // 3 s, a new one restarts it (never stacks), the §6 item 11 chip wins.
        var board = SpeakerNoticeBoard()
        board.show(SpeakerRejectionNotice.speech, now: .zero)
        #expect(board.visible(now: .milliseconds(2_999), chipShowing: false) == SpeakerRejectionNotice.speech)
        #expect(board.visible(now: .seconds(3), chipShowing: false) == nil)
        board.show(SpeakerRejectionNotice.speech, now: .seconds(2))
        #expect(board.visible(now: .milliseconds(4_500), chipShowing: false) == SpeakerRejectionNotice.speech)
        #expect(board.visible(now: .milliseconds(4_500), chipShowing: true) == nil)
        #expect(board.visible(now: .seconds(5), chipShowing: false) == nil)
    }
}
