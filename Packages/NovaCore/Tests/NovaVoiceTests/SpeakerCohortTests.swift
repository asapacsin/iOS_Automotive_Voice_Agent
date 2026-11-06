import Foundation
import NovaKit
import NovaPorts
import Testing
@testable import NovaVoice

/// A frame whose first sample numbers it, so order, gaps and duplicates show.
private func f(_ n: Int) -> PCMFrame16k { PCMFrame16k(samples: [Int16(n)] + Array(repeating: 0, count: 159))! }
private func record(_ id: Int) -> UtteranceRecord {
    UtteranceRecord(id: id, startMs: 0, endMs: 1, endReason: .silence, sentToModel: true, muteReason: .none, peakDb: 60,
                    noiseFloorDb: 30, classifierMax: 0.9)
}
/// A scripted sent utterance: start and `frames` of audio, then stop, record, stream end.
private func utterance(_ id: Int, frames: Int) -> [[UplinkGateOutput]] {
    var steps: [[UplinkGateOutput]] = [[.speechStarted(sentToModel: true), .audio(f(1))]]
    for n in 2..<(frames + 1) { steps.append([.audio(f(n))]) }
    steps.append([.speechStopped(.normal), .utterance(record(id)), .streamEnd])
    return steps
}
private func audioNumbers(_ outputs: [UplinkGateOutput]) -> [Int] {
    outputs.compactMap { if case .audio(let fr) = $0 { Int(fr.samples[0]) } else { nil } }
}

/// A small synthetic cohort (no CN-Celeb download): 5 vectors of dimension 4.
private let syntheticCohort: [[Float]] = [
    [0.9, 0.1, 0.3, 0.2], [0.2, 0.9, 0.1, 0.3], [0.1, 0.2, 0.9, 0.3], [0.5, 0.5, 0.5, 0.5], [0.3, 0.1, 0.2, 0.9],
]
private let e: [Float] = [1, 0, 0, 0]
private let t: [Float] = [0.8, 0.6, 0, 0]
/// `scripts/speaker_cohort.py` `as_norm(e, t, cohort, 3)` for the vectors above (numpy 2.5.3, run 2026-11-06):
/// `python3 -c "import sys; sys.path.insert(0,'scripts'); import numpy as np, speaker_cohort as m; print(m.as_norm(
/// np.array([1,0,0,0.]), np.array([0.8,0.6,0,0]), np.array(<cohort>), 3))"` → 1.1272553062759825.
private let pythonASNorm = 1.1272553062759825

private func meta(sha: String = SpeakerModelPin.sha256, threshold: Double = 0.5, speakers: Int = 5,
                  dimension: Int = 4) -> SpeakerCohortMeta {
    SpeakerCohortMeta(source: "CN-Celeb1 dev (OpenSLR 82)", license: "CC BY-SA 4.0",
                      model: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced", modelSha256: sha,
                      speakers: speakers, dimension: dimension, topN: 3, threshold: threshold, eer: 0.1, trials: 20)
}

private struct MemoryCohortFiles: SpeakerCohortFiles {
    var files: [String: Data]
    func read(_ name: String) -> Data? { files[name] }
}

/// float32 little-endian, speakers × dimension, as `speaker_cohort.py` writes it.
private func f32(_ rows: [[Float]]) -> Data {
    var bytes: [UInt8] = []
    for v in rows.flatMap({ $0 }) {
        let b = v.bitPattern
        bytes += [UInt8(b & 0xff), UInt8(b >> 8 & 0xff), UInt8(b >> 16 & 0xff), UInt8(b >> 24 & 0xff)]
    }
    return Data(bytes)
}

private func cohortFiles(_ m: SpeakerCohortMeta = meta(), rows: [[Float]] = syntheticCohort) -> MemoryCohortFiles {
    MemoryCohortFiles(files: [SpeakerCohort.metaFile: try! JSONEncoder().encode(m), SpeakerCohort.vectorsFile: f32(rows)])
}

@Suite("T-013j F-04b §16 compare with a crowd of public voices, no calibration")
struct SpeakerCohortTests {
    static let model = (name: "3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced", dimension: 4)
    static let profile = SpeakerProfile(embedding: e, modelName: model.name, dimension: 4,
                                        enrolledAt: Date(timeIntervalSince1970: 1_800_000_000))

    @Test("T-013j F-04b row 52: SpeakerScoreNorm with fixed e, t and a 5-vector cohort, topN 3, equals speaker_cohort.py")
    func asNormMatchesPython() throws {
        let norm = try #require(SpeakerScoreNorm(cohort: syntheticCohort, topN: 3))
        let side = try #require(norm.side(e))
        let s = try #require(norm.score(enrolled: side, test: t))
        #expect(abs(s.norm - pythonASNorm) < 1e-5)
        #expect(abs(s.raw - 0.8) < 1e-6)
        // The e side, by hand: top 3 cosines of e, mean and std divided by n (not n − 1).
        let cos = syntheticCohort.map { c in Double(c[0]) / c.reduce(0.0) { $0 + Double($1) * Double($1) }.squareRoot() }
        let top = cos.sorted(by: >).prefix(3)
        let mean = top.reduce(0, +) / 3
        let std = (top.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / 3).squareRoot()
        #expect(abs(side.mean - mean) < 1e-9 && abs(side.std - std) < 1e-9)
        // The same through the loaded files and the per-profile scorer (the e side computed once, at load).
        let cohort = try #require(SpeakerCohort.load(from: cohortFiles()))
        let scorer = try #require(SpeakerCohortScorer(embedding: e, cohort: cohort))
        #expect(scorer.enrolled == side)
        guard case .score(let n, 7, let raw, 5) = scorer.outcome(t, scoreMs: 7) else {
            Issue.record("no score"); return
        }
        #expect(abs(n - pythonASNorm) < 1e-5 && abs((raw ?? 0) - 0.8) < 1e-6)
        // Mismatched lengths, a zero vector: a scoring failure, never a made-up score.
        #expect(scorer.outcome([1, 0, 0], scoreMs: 1) == .failed(scoreMs: 1))
        #expect(scorer.outcome([0, 0, 0, 0], scoreMs: 1) == .failed(scoreMs: 1))
    }

    @Test("F-04b row 53: SpeakerHold scores a 4 s utterance once at the end on all 4 s; 0.3 s and a failure are unknown")
    func wholeUtterance() throws {
        func run(frames: Int, outcome: SpeakerScoreOutcome?) -> (out: [UplinkGateOutput], requests: [SpeakerScoreRequest],
                                                                    checks: [SpeakerCheckLine], preResult: Int) {
            var hold = SpeakerHold()
            _ = hold.setLock(threshold: 0.5)
            var out: [UplinkGateOutput] = [], requests: [SpeakerScoreRequest] = [], preResult = 0
            for step in utterance(1, frames: frames) {
                let s = hold.frame(step)
                out += s.outputs
                if let r = s.request {
                    requests.append(r)
                    preResult = out.count
                    if let outcome { out += hold.result(outcome, utterance: r.utterance, generation: r.generation).outputs }
                }
            }
            return (out, requests, hold.takeChecks(), preResult)
        }
        let cohort = try #require(SpeakerCohort.load(from: cohortFiles()))
        let scorer = try #require(SpeakerCohortScorer(embedding: e, cohort: cohort))
        // Accepted: one request, made only at the end, on all 400 frames; nothing forwarded before it.
        let ok = run(frames: 400, outcome: scorer.outcome(t, scoreMs: 12))
        #expect(ok.requests.count == 1)
        #expect(ok.requests.first?.frames.count == 400)
        #expect(ok.preResult == 0)
        #expect(audioNumbers(ok.out) == Array(1...400))
        #expect(ok.out.first == .speechStarted(sentToModel: true))
        #expect(Array(ok.out.suffix(2)) == [.utterance(record(1)), .streamEnd])
        let line = try #require(ok.checks.first)
        #expect(line.result == .accepted && line.speechMs == 4000)
        // §16 item 8: raw=, norm= and cohort= on the record line, numbers only.
        #expect(line.logLine.contains("raw=0.8 norm=1.127 cohort=5 threshold=0.5 result=accepted speechMs=4000"))
        // Rejected: dropped.
        let no = run(frames: 400, outcome: scorer.outcome([0, 0, 1, 0], scoreMs: 12))
        #expect(audioNumbers(no.out).isEmpty)
        #expect(!no.out.contains(.speechStarted(sentToModel: true)))
        #expect(no.checks.map(\.result) == [.rejected])
        // 0.3 s: too short to score, unknown, no request.
        let short = run(frames: 30, outcome: nil)
        #expect(short.requests.isEmpty && audioNumbers(short.out).isEmpty)
        #expect(short.checks.map(\.result) == [.unknown])
        // Scoring fails: unknown.
        let failed = run(frames: 400, outcome: .failed(scoreMs: 3))
        #expect(audioNumbers(failed.out).isEmpty)
        #expect(failed.checks.map(\.result) == [.unknown])
        #expect(failed.checks.first?.score == nil)
        // A held 4 s utterance with no result yet stays held (no 3 s cap any more).
        let waiting = run(frames: 400, outcome: nil)
        #expect(waiting.out.isEmpty && waiting.checks.isEmpty)
    }

    @Test("F-04b row 54: cohort matching is ready with its text; missing or another model sha256 is 声纹对比数据缺失; 0.46 ignored")
    func readiness() throws {
        let m = meta(threshold: 1.0)
        let ready = SpeakerLockPolicy.status(profile: Self.profile, model: Self.model, cohort: m)
        #expect(ready == .ready(cohort: 5))
        #expect(ready.text == "已录入 · 和 5 个公开声音比较，自动区分")
        #expect(SpeakerLockPolicy.requestOn(profile: Self.profile, model: Self.model, cohort: m) == .on(threshold: 1.0))
        for bad in [nil, meta(sha: String(repeating: "0", count: 64), threshold: 1.0)] {
            let status = SpeakerLockPolicy.status(profile: Self.profile, model: Self.model, cohort: bad)
            #expect(status == .cohortMissing)
            #expect(status.text == "声纹对比数据缺失")
            #expect(SpeakerLockPolicy.requestOn(profile: Self.profile, model: Self.model, cohort: bad) == .cohortMissing)
            // The switch cannot turn on; one that is on fails closed (locked, nothing passes) and is not turned off.
            let live = SpeakerLockPolicy.threshold(switchOn: true, profile: Self.profile, model: Self.model, cohort: bad)
            #expect(live == SpeakerLockPolicy.failClosedThreshold)
            #expect(!SpeakerLockPolicy.turnsSwitchOff(status))
            var hold = SpeakerHold()
            _ = hold.setLock(threshold: live)
            #expect(hold.locked)
        }
        // An old profile calibrated at 0.46: ready, and the cohort's threshold is used, not 0.46.
        var old = Self.profile
        old.threshold = 0.46
        old.calibratedAt = Date(timeIntervalSince1970: 1_793_000_557)
        #expect(SpeakerLockPolicy.status(profile: old, model: Self.model, cohort: m) == .ready(cohort: 5))
        #expect(SpeakerLockPolicy.threshold(switchOn: true, profile: old, model: Self.model, cohort: m) == 1.0)
        // The loader: missing files, a short vectors file, a directory with no files.
        #expect(SpeakerCohort.load(from: MemoryCohortFiles(files: [:])) == nil)
        var files = cohortFiles()
        files.files[SpeakerCohort.vectorsFile] = f32(Array(syntheticCohort.prefix(4)))
        #expect(SpeakerCohort.load(from: files) == nil)
        files = cohortFiles()
        files.files[SpeakerCohort.metaFile] = nil
        #expect(SpeakerCohort.load(from: files) == nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cohort-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(SpeakerCohort.load(from: DirectorySpeakerCohortFiles(directory: dir)) == nil)
        #expect(SpeakerCohort.load(from: DirectorySpeakerCohortFiles(directory: nil)) == nil)
        // The same files on disk, with the item 1.3 json fields (extra keys ignored).
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try f32(syntheticCohort).write(to: dir.appendingPathComponent("speaker_cohort.f32"))
        let json = """
            {"source": "CN-Celeb1 dev (OpenSLR 82)", "license": "CC BY-SA 4.0", "model": "m", "modelSha256": \
            "\(SpeakerModelPin.sha256)", "speakers": 5, "dimension": 4, "topN": 3, "threshold": 1.0, "eer": 0.1, \
            "trials": 20, "skippedTrials": 0, "rawCosineEer": 0.2, "rawCosineEerThreshold": 0.4}
            """
        try Data(json.utf8).write(to: dir.appendingPathComponent("speaker_cohort.json"))
        let loaded = try #require(SpeakerCohort.load(from: DirectorySpeakerCohortFiles(directory: dir)))
        #expect(loaded.vectors == syntheticCohort)
        #expect(loaded.meta.speakers == 5 && loaded.meta.topN == 3 && loaded.meta.threshold == 1.0)
    }

    @Test("F-04b row 55: wake word and stop phrase with the lock on use the AS-norm score and the cohort threshold")
    func phrases() throws {
        let cohort = try #require(SpeakerCohort.load(from: cohortFiles(meta(threshold: 1.0))))
        let scorer = try #require(SpeakerCohortScorer(embedding: e, cohort: cohort))
        #expect(scorer.threshold == 1.0)
        let recent = (1...200).map(f)
        for kind in [SpeakerCheckKind.wake, .stop] {
            var check = SpeakerPhraseCheck(kind: kind)
            check.setLock(threshold: scorer.threshold)
            guard case .verify(let r) = check.hit(recent: recent) else { Issue.record("no verify"); return }
            #expect(r.frames.count == 200)  // its own 2 s of audio
            let yesResult = check.result(scorer.outcome(t, scoreMs: 4), check: r.utterance, generation: r.generation,
                                         waitMs: 4)
            let yes = try #require(yesResult)
            #expect(yes.act)
            #expect(abs((yes.line.score ?? 0) - pythonASNorm) < 1e-5)
            #expect(yes.line.raw.map { abs($0 - 0.8) < 1e-6 } == true)
            #expect(yes.line.cohort == 5 && yes.line.threshold == 1.0 && yes.line.kind == kind)
            #expect(yes.line.logLine.contains("raw=0.8 norm=1.127 cohort=5 threshold=1.0 result=accepted"))
            // A test vector closer to the crowd than to the driver is rejected.
            guard case .verify(let r2) = check.hit(recent: recent) else { Issue.record("no verify"); return }
            let crowd: [Float] = [0.6, 0.5, 0.5, 0.5]
            let noResult = check.result(scorer.outcome(crowd, scoreMs: 4), check: r2.utterance,
                                        generation: r2.generation, waitMs: 4)
            let no = try #require(noResult)
            #expect(!no.act)
            #expect(no.line.result == .rejected)
            #expect((no.line.score ?? 9) < 1.0)
        }
    }

    @Test("F-04b row 56: first launch with a calibration draft file deletes it; 设置 has no 校准 row")
    func noCalibration() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("draft-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("SpeakerLock/calibration.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"driver":[0.5],"others":[0.2]}"#.utf8).write(to: url)
        #expect(SpeakerLegacyCalibration.removeDraft(at: url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!SpeakerLegacyCalibration.removeDraft(at: url))  // the next launch: nothing to do
        #expect(SpeakerLegacyCalibration.standardDraftURL()?.path.hasSuffix("SpeakerLock/calibration.json") == true)
        let all: [SpeakerLockStatus] = [.notEnrolled, .ready(cohort: 797), .invalidModel, .modelUnavailable, .cohortMissing]
        for status in all {
            #expect(!SpeakerLockSettings.buttons(status).contains { $0.contains("校准") })
            #expect(!status.text.contains("校准"))
        }
        #expect(SpeakerLockSettings.buttons(.ready(cohort: 797)) == ["重新录入", "删除声纹"])
        #expect(SpeakerLockSettings.buttons(.notEnrolled) == ["录入声纹"])
    }
}
