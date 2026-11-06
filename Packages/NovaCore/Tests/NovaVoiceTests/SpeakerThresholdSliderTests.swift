import Foundation
import Testing
@testable import NovaVoice

private struct MemoryProfileStore: SpeakerProfileStore, @unchecked Sendable {
    final class Box: @unchecked Sendable { var profile: SpeakerProfile?; var fail = false }
    let box = Box()
    func load() -> SpeakerProfile? { box.profile }
    func save(_ profile: SpeakerProfile) throws {
        if box.fail { throw CocoaError(.fileWriteUnknown) }
        box.profile = profile
    }
    func delete() throws { box.profile = nil }
}

@Suite("T-013j F-04b §16 threshold slider in 设置")
struct SpeakerThresholdSliderTests {
    static let enrolled = Date(timeIntervalSince1970: 1_762_300_000)  // 2025-11-05
    static func profile(threshold: Double? = 0.46) -> SpeakerProfile {
        SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3, threshold: threshold,
                       enrolledAt: enrolled, calibratedAt: threshold == nil ? nil : enrolled.addingTimeInterval(3600))
    }

    /// Shaped like the 2026-11-06 calibration (21 driver lines 0.366-0.707, 20 other lines up to 0.454). The real
    /// file is on the phone; these values reproduce its counts at 0.46 and 0.40.
    static let driver: [Double] = [0.366, 0.38] + (0..<19).map { 0.47 + Double($0) * 0.013 }
    static let others: [Double] = (0..<17).map { 0.19 + Double($0) * 0.012 } + [0.41, 0.43, 0.454]

    static func tempURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("slider-\(UUID().uuidString)/\(name)")
    }

    @Test("T-013j F-04b row 51: slider shown only for 已录入 with a saved threshold")
    func visibility() {
        let p = Self.profile()
        #expect(SpeakerThresholdSlider.visible(status: .ready, profile: p))
        #expect(!SpeakerThresholdSlider.visible(status: .enrolledUncalibrated, profile: Self.profile(threshold: nil)))
        #expect(!SpeakerThresholdSlider.visible(status: .notEnrolled, profile: nil))
        #expect(!SpeakerThresholdSlider.visible(status: .modelUnavailable, profile: p))
        #expect(!SpeakerThresholdSlider.visible(status: .recalibrate, profile: p))
        #expect(SpeakerLockStatus.ready.text == "已录入")
        #expect(SpeakerThresholdSlider.title(0.46) == "声纹阈值 0.46")
        #expect(SpeakerThresholdSlider.hint == "调低：你更少被拒，别人更容易通过。调高：别人更难通过，你更容易被拒。")
    }

    @Test("F-04b row 52: range 0.30-0.70 widened to include the saved value")
    func range() {
        #expect(SpeakerThresholdSlider.range(saved: 0.46) == 0.30...0.70)
        #expect(SpeakerThresholdSlider.range(saved: 0.75) == 0.30...0.75)
        #expect(SpeakerThresholdSlider.range(saved: 0.25) == 0.25...0.70)
    }

    @Test("F-04b row 53: counts at 0.46 and 0.40 from the calibration scores; suggestion 0.46")
    func counts() {
        let c = SpeakerCalibration(driver: Self.driver, others: Self.others)
        #expect(c.driver.count == 21 && c.others.count == 20)
        #expect(SpeakerThresholdSlider.countLine(c, at: 0.46) == "校准时：你的 21 句里被拒 2 句，别人的 20 句里通过 0 句")
        #expect(SpeakerThresholdSlider.countLine(c, at: 0.40) == "校准时：你的 21 句里被拒 2 句，别人的 20 句里通过 3 句")
        #expect(SpeakerThresholdSlider.suggestedText(c) == "校准建议 0.46")
        #expect(SpeakerThresholdSlider.restoreButton == "恢复建议值")
    }

    @Test("F-04b row 54: result file save and reload; a different voiceprint or unreadable file is removed")
    func resultFile() throws {
        let url = Self.tempURL("calibration-result.json")
        let store = FileSpeakerCalibrationResultStore(url: url)
        let p = Self.profile()
        try SpeakerCalibrationScores.save(SpeakerCalibration(driver: Self.driver, others: Self.others), profile: p,
                                          store: store)
        let loaded = try #require(SpeakerCalibrationScores.load(store, profile: p))
        #expect(loaded.driver == Self.driver && loaded.others == Self.others)

        var others = [p, p, p]
        others[0].enrolledAt = p.enrolledAt.addingTimeInterval(1)
        others[1].modelName = "other"
        others[2].dimension = 4
        for other in others {
            try SpeakerCalibrationScores.save(SpeakerCalibration(driver: Self.driver, others: Self.others), profile: p,
                                              store: store)
            #expect(SpeakerCalibrationScores.load(store, profile: other) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
        try Data("not json".utf8).write(to: url)
        #expect(SpeakerCalibrationScores.load(store, profile: p) == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("F-04b row 54: 使用这个阈值 writes the result file; enrollment and 删除声纹 remove it")
    func resultFileLifecycle() throws {
        let store = FileSpeakerCalibrationResultStore(url: Self.tempURL("calibration-result.json"))
        let drafts = FileSpeakerCalibrationDraftStore(url: Self.tempURL("calibration.json"))
        let profiles = MemoryProfileStore()
        let p = Self.profile(threshold: nil)
        profiles.box.profile = p
        let updated = try SpeakerCalibrationProgress.finish(
            0.46, calibration: SpeakerCalibration(driver: Self.driver, others: Self.others), profile: p,
            at: Self.enrolled, profileStore: profiles, draftStore: drafts, resultStore: store, writeScores: { _ in })
        #expect(SpeakerCalibrationScores.load(store, profile: updated)?.driver == Self.driver)
        try SpeakerEnrollment.delete(store: profiles, draftStore: drafts, resultStore: store)
        #expect(store.load() == nil)
    }

    @Test("F-04b row 55: Documents fallback reads the newest file after enrolledAt, in either format, once")
    func documentsFallback() throws {
        let p = Self.profile()
        let older = "speaker-calibration-2025-11-04T10-00-00Z.txt"
        let newer = "speaker-calibration-2026-11-06T01-02-37Z.txt"
        let clipFormat = "clipMs=1000\n" + Self.driver.map { "driver \($0) whole=0.5" }.joined(separator: "\n") + "\n"
            + Self.others.map { "other \($0) whole=none" }.joined(separator: "\n") + "\n"
        let oldFormat = Self.driver.map { "driver \($0)" }.joined(separator: "\n") + "\n"
            + Self.others.map { "other \($0)" }.joined(separator: "\n") + "\n"
        for newText in [clipFormat, oldFormat] {
            let url = Self.tempURL("calibration-result.json")
            let store = FileSpeakerCalibrationResultStore(url: url)
            let files = [older: "driver 0.9\nother 0.1\n", newer: newText]
            var reads = 0
            let c = try #require(SpeakerCalibrationScores.load(store, profile: p, documents: Array(files.keys)) {
                reads += 1
                return files[$0]
            })
            #expect(c.driver == Self.driver && c.others == Self.others)
            #expect(store.load()?.matches(p) == true)
            // Read once: the result file is used from then on.
            _ = SpeakerCalibrationScores.load(store, profile: p, documents: Array(files.keys)) { reads += 1; return files[$0] }
            #expect(reads == 1)
        }
        // Neither: no scores, the 没有校准分数 line and no 恢复建议值.
        let empty = FileSpeakerCalibrationResultStore(url: Self.tempURL("calibration-result.json"))
        let none = SpeakerCalibrationScores.load(empty, profile: p, documents: [older]) { _ in "driver 0.9\n" }
        #expect(none == nil)
        #expect(SpeakerThresholdSlider.countLine(none, at: 0.46) == "没有校准分数，无法显示误拒和误通过")
        #expect(SpeakerThresholdSlider.suggestedText(none) == nil)
    }

    @Test("F-04b row 56: finger lifts at 0.403 saves 0.4; 恢复建议值 saves 0.46; a failed save goes back")
    func saving() throws {
        let store = MemoryProfileStore()
        store.box.profile = Self.profile()
        let before = try #require(store.box.profile)
        let lifted = SpeakerThresholdSlider.save(0.403, source: .slider, store: store)
        #expect(lifted.value == 0.4 && lifted.error == nil)
        #expect(store.box.profile?.threshold == 0.4)
        #expect(lifted.line?.logLine == "speaker-threshold old=0.46 new=0.4 source=slider")
        // Only the threshold changes.
        var expected = before
        expected.threshold = 0.4
        #expect(store.box.profile == expected)

        let restored = SpeakerThresholdSlider.save(0.46, source: .suggested, store: store)
        #expect(store.box.profile?.threshold == 0.46)
        #expect(restored.line?.logLine == "speaker-threshold old=0.4 new=0.46 source=suggested")

        store.box.fail = true
        let failed = SpeakerThresholdSlider.save(0.52, source: .slider, store: store)
        #expect(failed.value == 0.46 && failed.line == nil)
        #expect(failed.error == "阈值保存失败")
        #expect(store.box.profile?.threshold == 0.46)
    }

    @Test("F-04b row 57: ring keeps the last 20 speech scores, newest first, rejected marked; no wake scores")
    func ring() {
        var ring = SpeakerRecentScores()
        #expect(ring.text == "还没有分数")
        for i in 0..<25 {
            ring.add(SpeakerCheckLine(utterance: i, kind: .speech, score: Double(30 + i) / 100, threshold: 0.46,
                                      result: 30 + i >= 46 ? .accepted : .rejected,
                                      speechMs: 1000, scoreMs: 40, waitMs: 1040))
            if i < 3 {
                ring.add(SpeakerCheckLine(utterance: 100 + i, kind: .wake, score: 0.99, threshold: 0.46,
                                          result: .accepted, speechMs: 2000, scoreMs: 40, waitMs: 40))
            }
        }
        #expect(ring.entries.count == 20)
        let parts = ring.text.split(separator: " ").map(String.init)
        #expect(parts.count == 20)
        #expect(parts.first == "0.54" && parts.last == "0.35✗")
        #expect(parts.contains("0.45✗") && parts.contains("0.46"))
        #expect(!ring.text.contains("0.99"))
        #expect(SpeakerRecentScores.header == "最近 20 次（任何说话的人）：")
    }
}
