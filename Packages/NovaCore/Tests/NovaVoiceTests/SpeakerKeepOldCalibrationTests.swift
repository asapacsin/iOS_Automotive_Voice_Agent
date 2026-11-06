import Foundation
import Testing
@testable import NovaVoice

@Suite("T-013i F-04b §15 keep the threshold calibrated before §14")
struct SpeakerKeepOldCalibrationTests {
    static let model = (name: "campplus", dimension: 3)
    static let macau = TimeZone(identifier: "Asia/Macau")!

    static func old() -> SpeakerProfile {
        var p = SpeakerProfile(embedding: [1, 0, 0], modelName: "campplus", dimension: 3,
                               enrolledAt: Date(timeIntervalSince1970: 1_700_000_000))
        p.threshold = 0.46
        p.calibratedAt = ISO8601DateFormatter().date(from: "2026-11-06T01:02:37Z")
        return p
    }

    @Test("T-013i F-04b row 47: an old threshold with no calibrationClipMs is ready, used, stays on, file unchanged; 整句校准 text")
    func oldThresholdUsed() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("keep-\(UUID().uuidString)/profile.json")
        let file = FileSpeakerProfileStore(url: url)
        try file.save(Self.old())
        let before = try Data(contentsOf: url)
        let loaded = try #require(file.load())
        #expect(loaded.calibrationClipMs == nil)
        let status = SpeakerLockPolicy.status(profile: loaded, model: Self.model)
        #expect(status == .ready)
        #expect(SpeakerLockPolicy.requestOn(profile: loaded, model: Self.model) == .on(threshold: 0.46))
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: loaded, model: Self.model) == 0.46)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: loaded, model: nil) == 0.46)
        #expect(!SpeakerLockPolicy.turnsSwitchOff(status))
        #expect(try Data(contentsOf: url) == before)
        #expect(SpeakerCalibrationSummary.text(profile: loaded, status: status, timeZone: Self.macau)
            == "已校准：11月6日，阈值 0.46（整句校准）")
    }

    @Test("F-04b row 48: calibrationClipMs 1000 is ready with the §14 item 6 text; 500 is recalibrate")
    func recordedClip() {
        var current = Self.old()
        current.calibrationClipMs = 1000
        current.calibrationDriverLines = 21
        current.calibrationOtherLines = 20
        #expect(SpeakerLockPolicy.status(profile: current, model: Self.model) == .ready)
        #expect(SpeakerCalibrationSummary.text(profile: current, status: .ready, timeZone: Self.macau)
            == "已校准：11月6日，阈值 0.46（录入的人 21 句，其他人 20 句）")
        var half = Self.old()
        half.calibrationClipMs = 500
        #expect(SpeakerLockPolicy.status(profile: half, model: Self.model) == .recalibrate)
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: half, model: Self.model) == nil)
    }
}
