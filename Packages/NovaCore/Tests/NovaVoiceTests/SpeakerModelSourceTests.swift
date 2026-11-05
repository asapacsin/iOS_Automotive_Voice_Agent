import Foundation
import NovaVoice
import Testing

@Suite("T-013f F-04b speaker model source: bundle or install-time asset pack")
struct SpeakerModelSourceTests {
    @Test("F-04b row 19: a bundled model is used whatever the pack state")
    func bundleFirst() {
        for pack: SpeakerPackState in [.downloading, .failed, .unsupportedSystem, .downloaded(sha256: nil)] {
            #expect(SpeakerModelAvailability.resolve(bundlePresent: true, pack: pack) == .bundle)
        }
        #expect(SpeakerModelAvailability.bundle.usable)
        #expect(SpeakerModelAvailability.bundle.note == nil)
    }

    @Test("F-04b row 20: no bundled model, downloaded pack with the pinned checksum is used")
    func packUsed() {
        let a = SpeakerModelAvailability.resolve(bundlePresent: false,
                                                 pack: .downloaded(sha256: SpeakerModelPin.sha256.uppercased()))
        #expect(a == .pack)
        #expect(a.usable)
        #expect(a.note == nil)
    }

    @Test("F-04b row 21: wrong checksum, missing file, downloading, failed and old iOS are not usable")
    func notUsable() {
        let cases: [(SpeakerPackState, SpeakerModelAvailability, String)] = [
            (.downloaded(sha256: String(repeating: "0", count: 64)), .failed, "声纹模型下载失败"),
            (.downloaded(sha256: nil), .failed, "声纹模型下载失败"),
            (.downloading, .downloading, "声纹模型下载中"),
            (.failed, .failed, "声纹模型下载失败"),
            (.unsupportedSystem, .unsupportedSystem, "声纹锁定需要 iOS 26 或更新版本"),
        ]
        for (pack, expected, note) in cases {
            let a = SpeakerModelAvailability.resolve(bundlePresent: false, pack: pack)
            #expect(a == expected)
            #expect(!a.usable)
            #expect(a.note == note)
            #expect(a.canRetry == (expected == .failed))
        }
    }

    @Test("F-04b row 21: lock on with the model downloading or failed stays locked (fails closed); never turns on new")
    func failsClosed() {
        let calibrated = SpeakerProfile(embedding: [1, 0], modelName: "m", dimension: 2, threshold: 0.5,
                                        enrolledAt: Date(timeIntervalSince1970: 0))
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: calibrated, model: nil) == 0.5)
        #expect(SpeakerLockPolicy.threshold(switchOn: false, profile: calibrated, model: nil) == nil)
        #expect(SpeakerLockPolicy.requestOn(profile: calibrated, model: nil) == .modelUnavailable)
        var uncalibrated = calibrated
        uncalibrated.threshold = nil
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: uncalibrated, model: nil) == nil)
    }

    @Test("F-04b row 21: pin matches scripts/sherpa/models.sha256")
    func pinMatchesScript() throws {
        let path = #filePath.replacingOccurrences(of: "Packages/NovaCore/Tests/NovaVoiceTests/SpeakerModelSourceTests.swift",
                                                  with: "scripts/sherpa/models.sha256")
        let text = try String(contentsOfFile: path, encoding: .utf8)
        #expect(text.contains("\(SpeakerModelPin.sha256)  speaker/\(SpeakerModelPin.modelFile)"))
    }
}
