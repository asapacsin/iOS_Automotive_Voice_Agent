import Foundation
import Testing
@testable import NovaVoice

private final class ProfileBox: SpeakerProfileStore, @unchecked Sendable {
    var profile: SpeakerProfile?
    var failSave = false
    init(_ p: SpeakerProfile?) { profile = p }
    func load() -> SpeakerProfile? { profile }
    func save(_ p: SpeakerProfile) throws {
        if failSave { throw CocoaError(.fileWriteUnknown) }
        profile = p
    }
    func delete() throws { profile = nil }
}

private final class FailingDraftStore: SpeakerCalibrationDraftStore, @unchecked Sendable {
    func load() -> SpeakerCalibrationDraft? { nil }
    func save(_ draft: SpeakerCalibrationDraft) throws { throw CocoaError(.fileWriteUnknown) }
    func delete() throws {}
}

@Suite("T-013g F-04b §13 calibration progress is kept")
struct SpeakerCalibrationDraftTests {
    static let at = Date(timeIntervalSince1970: 1_800_000_000)
    static let profile = SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3, enrolledAt: at)

    func tempStore() -> FileSpeakerCalibrationDraftStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        return FileSpeakerCalibrationDraftStore(url: dir.appendingPathComponent("SpeakerLock/calibration.json"))
    }

    func draft(_ d: Int, _ o: Int, profile: SpeakerProfile = profile) -> SpeakerCalibrationDraft {
        SpeakerCalibrationDraft(SpeakerCalibration(driver: (0..<d).map { 0.7 + Double($0) / 1000 },
                                                   others: (0..<o).map { 0.2 + Double($0) / 1000 }), for: profile)
    }

    @Test("T-013g F-04b row 27: save and reload keep scores and fields; the last write wins")
    func saveReload() throws {
        let store = tempStore()
        let first = draft(2, 1)
        try store.save(first)
        #expect(FileSpeakerCalibrationDraftStore(url: store.url).load() == first)
        let second = draft(5, 4)
        try store.save(second)
        #expect(store.load() == second)
        #expect(store.load()?.enrolledAt == Self.at && store.load()?.modelName == "campplus" && store.load()?.dimension == 3)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!text.contains("embedding"))
    }

    @Test("F-04b row 28: a draft of another enrolledAt, modelName or dimension, or an unreadable file, is empty and removed")
    func mismatch() throws {
        let others = [
            SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3, enrolledAt: Self.at.addingTimeInterval(1)),
            SpeakerProfile(embedding: [1, 0, 0], modelName: "eres2net", dimension: 3, enrolledAt: Self.at),
            SpeakerProfile(embedding: [1, 0, 0, 0], modelName: "campplus", dimension: 4, enrolledAt: Self.at),
        ]
        for other in others {
            let store = tempStore()
            try store.save(draft(3, 3, profile: other))
            let loaded = SpeakerCalibrationProgress.load(store, profile: Self.profile)
            #expect(loaded.driver.isEmpty && loaded.others.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: store.url.path))
        }
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        #expect(SpeakerCalibrationProgress.load(store, profile: Self.profile).driver.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
    }

    @Test("F-04b row 29: 12 and 3 lines reload; picker on 录入的人; next lines are lines[12] and lines[3]; 20 → 其他人")
    func reload() throws {
        let store = tempStore()
        try store.save(draft(12, 3))
        let c = SpeakerCalibrationProgress.load(store, profile: Self.profile)
        #expect(c.driver.count == 12 && c.others.count == 3)
        #expect(SpeakerCalibrationProgress.startsOnDriver(c))
        #expect(SpeakerCalibrationProgress.line(c, driver: true) == SpeakerCalibration.lines[12])
        #expect(SpeakerCalibrationProgress.line(c, driver: false) == SpeakerCalibration.lines[3])
        #expect(!SpeakerCalibrationProgress.startsOnDriver(draft(20, 0).calibration))
        #expect(SpeakerCalibrationProgress.settingsRow(store, profile: Self.profile) == "校准进度：录入的人 12 / 20，其他人 3 / 20")
        try store.save(draft(0, 0))
        #expect(SpeakerCalibrationProgress.settingsRow(store, profile: Self.profile) == nil)
    }

    @Test("F-04b §13 items 1, 7: each accepted line is saved; a failed write keeps the score and reports it")
    func addLine() {
        let store = tempStore()
        var c = SpeakerCalibration()
        #expect(SpeakerCalibrationProgress.add(0.8, driver: true, to: &c, profile: Self.profile, store: store))
        #expect(SpeakerCalibrationProgress.add(0.3, driver: false, to: &c, profile: Self.profile, store: store))
        #expect(store.load()?.driver == [0.8] && store.load()?.others == [0.3])
        #expect(!SpeakerCalibrationProgress.add(0.9, driver: true, to: &c, profile: Self.profile, store: FailingDraftStore()))
        #expect(c.driver == [0.8, 0.9])
        #expect(SpeakerCalibrationProgress.saveFailedText == "进度保存失败，关闭后这句会丢失")
    }

    @Test("F-04b row 30: finishing saves the threshold and removes the draft; a failed profile save keeps the draft")
    func finish() throws {
        let store = tempStore()
        let d = draft(20, 20)
        try store.save(d)
        let profiles = ProfileBox(Self.profile)
        var written = 0
        let saved = try SpeakerCalibrationProgress.finish(0.55, calibration: d.calibration, profile: Self.profile, at: Self.at,
                                                          profileStore: profiles, draftStore: store) { _ in written += 1 }
        #expect(saved.threshold == 0.55 && profiles.profile?.threshold == 0.55 && written == 1)
        #expect(store.load() == nil)

        try store.save(d)
        let failing = ProfileBox(Self.profile)
        failing.failSave = true
        #expect(throws: (any Error).self) {
            _ = try SpeakerCalibrationProgress.finish(0.55, calibration: d.calibration, profile: Self.profile, at: Self.at,
                                                      profileStore: failing, draftStore: store) { _ in written += 1 }
        }
        #expect(store.load() == d && written == 1 && failing.profile?.threshold == nil)
    }

    @Test("F-04b row 31: a failed enrollment keeps profile, threshold and draft; a successful one has no threshold and no draft")
    func reenroll() throws {
        let store = tempStore()
        var old = Self.profile
        old.threshold = 0.5
        let profiles = ProfileBox(old)
        try store.save(draft(4, 4))
        let short = EnrollmentTake(speech: .milliseconds(100), clippedSamples: 0, noiseDb: 40, embedding: [1, 0, 0])
        _ = SpeakerEnrollment.enroll([short], modelName: "campplus", dimension: 3, at: Self.at, store: profiles, draftStore: store)
        #expect(profiles.profile == old && store.load() == draft(4, 4))
        let good = [[1, 0.1, 0], [0.9, 0.2, 0], [1, 0, 0.1]].map {
            EnrollmentTake(speech: .milliseconds(3_000), clippedSamples: 0, noiseDb: 40, embedding: $0 as [Float])
        }
        let new = try SpeakerEnrollment.enroll(good, modelName: "campplus", dimension: 3, at: Self.at.addingTimeInterval(60),
                                               store: profiles, draftStore: store).get()
        #expect(new.threshold == nil && profiles.profile == new && store.load() == nil)
        #expect(SpeakerCalibrationProgress.reenrollWarning == "重新录入后要重新校准（两人各 20 句）。继续吗？")
        #expect(SpeakerCalibrationProgress.warnBeforeReenroll(profile: old, calibration: SpeakerCalibration()))
        #expect(SpeakerCalibrationProgress.warnBeforeReenroll(profile: Self.profile, calibration: draft(1, 0).calibration))
        #expect(!SpeakerCalibrationProgress.warnBeforeReenroll(profile: Self.profile, calibration: SpeakerCalibration()))
    }

    @Test("F-04b row 32: 删除声纹 and wipe-all remove the draft; 重新校准 empties it and keeps the threshold")
    func remove() throws {
        let store = tempStore()
        var calibrated = Self.profile
        calibrated.threshold = 0.6
        let profiles = ProfileBox(calibrated)
        try store.save(draft(3, 3))
        try SpeakerEnrollment.delete(store: profiles, draftStore: store)  // 删除声纹 and the wipe-all both call this
        #expect(store.load() == nil && profiles.profile == nil)

        let kept = ProfileBox(calibrated)
        try store.save(draft(3, 3))
        try SpeakerCalibrationProgress.startOver(store)
        #expect(SpeakerCalibrationProgress.load(store, profile: calibrated).driver.isEmpty)
        #expect(kept.profile?.threshold == 0.6)
        #expect(SpeakerCalibrationProgress.startOverButton == "重新校准")
        #expect(SpeakerCalibrationProgress.startOverQuestion == "清除已说的句子并重新开始？")
    }
}
