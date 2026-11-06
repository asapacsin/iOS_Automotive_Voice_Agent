import Foundation
import NovaAgent
import NovaAsrSherpa
import NovaAudio
import NovaKit
import NovaPorts
import NovaVoice
import SwiftUI

/// F-04b (T-013e) 声纹锁定: the profile, the model and the one background scoring queue. Lock off: the model is never
/// created or loaded and nothing is scored (§6 item 12). Nothing here leaves the phone (§4 item 7).
final class SpeakerLockService: @unchecked Sendable {
    static let shared = SpeakerLockService()

    /// §12 (T-013f): the bundled model (Debug) or the downloaded asset pack; nil while neither is usable.
    static var directory: URL? { SpeakerModelLocator.shared.directory }

    private let lock = NSLock()
    /// §6 item 3: scoring runs on one background serial queue; the capture callback only copies frames.
    private let queue = DispatchQueue(label: "com.asapacsin.novadrive.speaker", qos: .userInitiated)
    private var verifier: SherpaSpeakerVerifier?
    let store: any SpeakerProfileStore = FileSpeakerProfileStore.standard()
        ?? FileSpeakerProfileStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("profile.json"))

    /// F-04b §16 items 1, 10 (T-013j): the cohort files in the bundle (`Resources/SpeakerCohort/`). They may be missing
    /// (「声纹对比数据缺失」, the lock fails closed); nothing is downloaded.
    static var cohortDirectory: URL? {
        (Bundle.main.url(forResource: "speaker_cohort", withExtension: "json", subdirectory: "SpeakerCohort")
            ?? Bundle.main.url(forResource: "speaker_cohort", withExtension: "json"))?.deletingLastPathComponent()
    }

    /// Read once, on first use; the bundle does not change while the app runs.
    private var cohortLoaded = false
    private var cohortValue: SpeakerCohort?
    var cohort: SpeakerCohort? {
        lock.withLock {
            if !cohortLoaded {
                cohortValue = SpeakerCohort.load(from: DirectorySpeakerCohortFiles(directory: Self.cohortDirectory))
                cohortLoaded = true
            }
            return cohortValue
        }
    }
    /// §16 item 2: the enrollment side is computed once per profile load and reused for every check.
    private var scorerCache: (profile: SpeakerProfile, scorer: SpeakerCohortScorer)?

    private func scorer(for profile: SpeakerProfile) -> SpeakerCohortScorer? {
        let cohort = self.cohort
        return lock.withLock {
            if let scorerCache, scorerCache.profile == profile { return scorerCache.scorer }
            guard let cohort, SpeakerLockPolicy.cohortMatches(cohort.meta, profile: profile,
                                                              modelSha256: SpeakerModelPin.sha256),
                  let scorer = SpeakerCohortScorer(embedding: profile.embedding, cohort: cohort) else {
                scorerCache = nil
                return nil
            }
            scorerCache = (profile, scorer)
            return scorer
        }
    }

    var modelPresent: Bool { SherpaSpeakerVerifier.modelPresent(in: Self.directory) }

    /// Created on first use only (enrollment, calibration or the lock on). §12 item 5: never cached while the model
    /// is missing, so a pack that finishes downloading later is used without a restart.
    private func model() -> SherpaSpeakerVerifier {
        lock.withLock {
            if let verifier { return verifier }
            let dir = Self.directory
            let v = SherpaSpeakerVerifier(directory: dir)
            if dir != nil { verifier = v }
            return v
        }
    }

    /// The model's name and dimension for the policy, without loading it: the profile's dimension stands in until
    /// the model has loaded; a loaded model's real dimension replaces it. nil when the bundle has no model.
    func modelInfo(profile: SpeakerProfile?) -> (name: String, dimension: Int)? {
        guard modelPresent else { return nil }
        let loaded = lock.withLock { verifier }
        let name = loaded?.modelName ?? Self.directory.flatMap { try? SherpaSpeakerManifest.load(from: $0).name } ?? ""
        let dim = loaded.map(\.dimension).flatMap { $0 > 0 ? $0 : nil } ?? profile?.dimension ?? 0
        return (name, dim)
    }

    /// §3 item 2, §16 items 6–7.
    func status() -> SpeakerLockStatus {
        let profile = store.load()
        return SpeakerLockPolicy.status(profile: profile, model: modelInfo(profile: profile), cohort: cohort?.meta)
    }

    /// The live threshold (§16 item 3: the cohort's): the switch on and a ready lock; nil = the lock is off.
    func liveThreshold() -> Double? {
        // §6 item 12: lock off reads neither the profile nor the cohort file.
        guard DriveSettings.speakerLockOn() else { return nil }
        let profile = store.load()
        return SpeakerLockPolicy.threshold(switchOn: true, profile: profile,
                                           model: modelInfo(profile: profile), cohort: cohort?.meta)
    }

    /// Embeds on the background queue; the time it took for `scoreMs`.
    func embed(_ frames: [PCMFrame16k], done: @escaping @Sendable (Result<[Float], any Error>, Int) -> Void) {
        let model = model()
        queue.async {
            let start = Date()
            let result = Result { try model.embedding(of: frames) }
            done(result, Int(Date().timeIntervalSince(start) * 1000))
        }
    }

    /// §6 items 3–4, §16 items 2–5: one request (speech, wake word or stop phrase) scored against the profile and
    /// the cohort. No cohort for this model: a scoring failure, so the lock fails closed (§16 item 7).
    func score(_ request: SpeakerScoreRequest, done: @escaping @Sendable (SpeakerScoreOutcome) -> Void) {
        guard let profile = store.load(), let scorer = scorer(for: profile) else { done(.failed(scoreMs: 0)); return }
        embed(request.frames) { result, ms in
            switch result {
            case .success(let e): done(scorer.outcome(e, scoreMs: ms))
            case .failure: done(.failed(scoreMs: ms))
            }
        }
    }

    /// §4 item 5, §3 item 5: delete the profile and turn the lock off.
    func deleteProfile() {
        try? SpeakerEnrollment.delete(store: store)
        UserDefaults.standard.set(false, forKey: DriveSettings.speakerLock)
    }

    /// §4 item 6: a profile of another model turns the lock off; the voiceprint and the file stay.
    func dropInvalidLock() {
        if SpeakerLockPolicy.turnsSwitchOff(status()), DriveSettings.speakerLockOn() {
            UserDefaults.standard.set(false, forKey: DriveSettings.speakerLock)
        }
    }

    /// §16 item 6: the §13 calibration draft is deleted on first launch; no calibration file is written any more.
    static func removeCalibrationDraft() {
        SpeakerLegacyCalibration.removeDraft(at: SpeakerLegacyCalibration.standardDraftURL())
    }
}

extension DriveSettings {
    /// F-04b §3 item 1 「声纹锁定」: off by default; read without restarting.
    static let speakerLock = "speaker_lock"

    static func speakerLockOn(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: speakerLock) as? Bool ?? false
    }
}

/// §4 items 1–3: records one sentence or line on the same voice-processing capture a session uses, with the same
/// gate and speech classifier. Only the confirmed-speech frames are kept, in memory, until `finish`.
@MainActor
final class SpeakerTakeRecorder {
    private var audio: LiveAudio?
    private var classifier: SoundAnalysisSpeechClassifier?
    private let box = TakeBox()

    /// Set by `finish`; a start still waiting for the microphone then gives it back instead of capturing.
    private var finished = false

    func start() async throws {
        finished = false
        guard await RuntimeHolder.shared.runtime.beginExclusiveCapture() else { throw SpeakerTakeError.sessionRunning }
        guard !finished else {
            await RuntimeHolder.shared.runtime.endExclusiveCapture()
            throw SpeakerTakeError.sessionRunning
        }
        box.reset()
        let classifier = SoundAnalysisSpeechClassifier()
        try? classifier.start { [box] result in box.classified(result) }
        self.classifier = classifier
        let audio = LiveAudio()
        do {
            try audio.start { [box] frame in
                classifier.feed(frame)
                box.frame(frame)
            }
        } catch {
            classifier.stop()
            await RuntimeHolder.shared.runtime.endExclusiveCapture()
            throw error
        }
        self.audio = audio
    }

    /// The gate learns the noise bed for 1.5 s and cannot open then: the screen says 请稍等 until it can.
    static let warmUp = Duration.milliseconds(1_600)

    /// Stops the capture and returns the take; the raw audio is dropped by the caller after embedding.
    func finish() async -> (frames: [PCMFrame16k], speech: NovaDuration, clipped: Int, noiseDb: Int) {
        finished = true
        audio?.stop()
        audio = nil
        classifier?.stop()
        classifier = nil
        await RuntimeHolder.shared.runtime.endExclusiveCapture()
        return box.take()
    }
}

enum SpeakerTakeError: Error { case sessionRunning }

private final class TakeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var gate = SpeechUplinkGate()
    private var speech: [PCMFrame16k] = []
    private var open = false
    /// Frames of the open segment: its pre-roll (sent with the start) and hangover are not speech.
    private var segment: [PCMFrame16k] = []
    private var preRoll = 0

    func reset() { lock.withLock { gate = SpeechUplinkGate(); speech = []; open = false } }
    func classified(_ r: SpeechClassification) { lock.withLock { gate.classified(r) } }
    func frame(_ f: PCMFrame16k) {
        lock.withLock {
            let outputs = gate.process(f)
            for o in outputs {
                switch o {
                case .speechStarted(let sent):
                    open = sent
                    segment = []
                    preRoll = Int(UplinkGateTuning().preRoll.milliseconds / 10)
                case .audio(let a) where open: segment.append(a)
                case .speechStopped:
                    if open {
                        // §4 item 3: speech only, without the pre-roll and the 1.2 s hangover.
                        let hangover = Int(UplinkGateTuning().hangover.milliseconds / 10)
                        let end = max(preRoll, segment.count - hangover)
                        if end > preRoll { speech += segment[preRoll..<end] }
                    }
                    open = false
                    segment = []
                default: break
                }
            }
        }
    }
    func take() -> (frames: [PCMFrame16k], speech: NovaDuration, clipped: Int, noiseDb: Int) {
        lock.withLock {
            let db = Int((20 * log10(max(gate.noiseRMS, 1) / 32_768) + 96).rounded())
            // A segment still open at 读完了 (inside its hangover): all of it after the pre-roll is speech.
            if open, segment.count > preRoll { speech += segment[preRoll...] }
            open = false
            segment = []
            return (speech, .milliseconds(Int64(speech.count) * 10), EnrollmentTake.clipped(speech), db)
        }
    }
}

/// §3, §16 items 6–7: the rows under 设置 → 声音. No 校准 and no progress row (§16 item 6).
struct SpeakerLockSection: View {
    @AppStorage(DriveSettings.speakerLock) private var lockOn = false
    @State private var status = SpeakerLockStatus.notEnrolled
    @State private var showEnroll = false
    @State private var confirmDelete = false
    @State private var note: String?

    var body: some View {
        Toggle("声纹锁定", isOn: Binding(get: { lockOn }, set: { requested($0) }))
        Text(SpeakerLockPolicy.switchText).font(.footnote).foregroundStyle(.secondary)
        Text("这只是基本的声纹确认，可能认错，录音也可能通过，不是安全功能。")
            .font(.footnote).foregroundStyle(.secondary)
        // The sheet and refresh hang on this always-shown row: an EmptyView in a Form is never rendered, so
        // modifiers on it never fire (录入声纹 did nothing on device, build 7910dc7).
        LabeledContent("声纹", value: status.text)
            .sheet(isPresented: $showEnroll, onDismiss: refresh) { SpeakerEnrollmentView() }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: SpeakerModelLocator.changed)) { _ in refresh() }
        if let note { Text(note).font(.footnote).foregroundStyle(.red) }
        // §16 item 6: the buttons from `SpeakerLockSettings` (no 校准).
        ForEach(SpeakerLockSettings.buttons(status), id: \.self) { title in
            if title == "删除声纹" {
                Button(title, role: .destructive) { confirmDelete = true }
                    .confirmationDialog("删除声纹？", isPresented: $confirmDelete, titleVisibility: .visible) {
                        Button("删除", role: .destructive) { SpeakerLockService.shared.deleteProfile(); refresh() }
                    }
            } else {
                Button(title) { showEnroll = true }  // 录入声纹 / 重新录入
            }
        }
        if status == .modelUnavailable, SpeakerModelLocator.shared.availability.canRetry {
            Button("重试") { SpeakerModelLocator.shared.refresh() }
        }
    }

    /// §3 item 4: the switch stays off until the lock would work; on opens enrollment instead.
    private func requested(_ on: Bool) {
        guard on else { lockOn = false; return }
        let service = SpeakerLockService.shared
        let profile = service.store.load()
        switch SpeakerLockPolicy.requestOn(profile: profile, model: service.modelInfo(profile: profile),
                                           cohort: service.cohort?.meta) {
        case .on: lockOn = true; note = nil
        case .openEnrollment: showEnroll = true
        case .modelUnavailable: note = Self.unavailableNote
        case .cohortMissing: note = SpeakerLockStatus.cohortMissing.text
        }
    }

    private func refresh() {
        SpeakerLockService.shared.dropInvalidLock()
        status = SpeakerLockService.shared.status()
        // §12 item 4, §16 item 7: a model still downloading or failed, or a missing cohort, keeps the stored switch
        // (fails closed live).
        if !status.isReady && status != .modelUnavailable && status != .cohortMissing { lockOn = false }
        note = status == .modelUnavailable ? Self.unavailableNote : nil
    }

    /// §12 item 4: why the model is not usable (download state), else the §3 text.
    private static var unavailableNote: String {
        SpeakerModelLocator.shared.availability.note ?? "声纹模型不可用"
    }
}

/// §4: 3 sentences in a quiet parked car; nothing is saved unless every check passes.
struct SpeakerEnrollmentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var recording = false
    @State private var preparing = false
    @State private var takes: [EnrollmentTake] = []
    @State private var message: String?
    @State private var recorder = SpeakerTakeRecorder()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("请停车，关窗、关音乐，只有你一个人说话。用平常的声音读下面的句子。")
                        .font(.footnote)
                }
                if index < SpeakerEnrollment.sentences.count {
                    Section("第 \(index + 1) / \(SpeakerEnrollment.sentences.count) 句") {
                        Text(SpeakerEnrollment.sentences[index]).font(.title3)
                        Button(preparing ? "请稍等…" : recording ? "读完了" : "开始读") { Task { await toggle() } }
                            .disabled(preparing)
                    }
                }
                if let message { Section { Text(message) } }
            }
            .navigationTitle("录入声纹")
            // Swiping away mid-take would keep the microphone; 取消 ends the take first.
            .interactiveDismissDisabled()
            .toolbar { Button("取消") { Task { if recording { _ = await recorder.finish() }; dismiss() } } }
        }
    }

    private func toggle() async {
        if !recording {
            // Set first, so 取消/关闭 during the start or the warm-up still ends the take.
            recording = true
            preparing = true
            defer { preparing = false }
            do {
                try await recorder.start()
                message = nil
                try? await Task.sleep(for: SpeakerTakeRecorder.warmUp)
            } catch {
                recording = false
                message = "对话进行中或麦克风不可用，结束对话后再录入。"
            }
            return
        }
        recording = false
        let take = await recorder.finish()
        let embedding: [Float]? = await withCheckedContinuation { done in
            SpeakerLockService.shared.embed(take.frames) { result, _ in done.resume(returning: try? result.get()) }
        }
        // Raw audio is dropped here (§4 item 4): only the measurements and the embedding stay.
        takes.append(EnrollmentTake(speech: take.speech, clippedSamples: take.clipped, noiseDb: take.noiseDb,
                                    embedding: embedding ?? []))
        index += 1
        guard index == SpeakerEnrollment.sentences.count else { return }
        let service = SpeakerLockService.shared
        let dim = takes.first?.embedding.count ?? 0
        let name = service.modelInfo(profile: nil)?.name ?? ""
        switch SpeakerEnrollment.enroll(takes, modelName: name, dimension: dim, at: Date(), store: service.store) {
        case .success:
            // §16 item 6: no calibration; the lock can turn on once the cohort is there.
            message = "已录入。现在可以打开声纹锁定。"
        case .failure(let problem):
            message = problem.text
            takes = []
            index = 0
        }
    }
}
