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

    /// §3 item 2.
    func status() -> SpeakerLockStatus {
        let profile = store.load()
        return SpeakerLockPolicy.status(profile: profile, model: modelInfo(profile: profile))
    }

    /// The live threshold: the switch on and a calibrated, valid profile; nil = the lock is off.
    func liveThreshold() -> Double? {
        let profile = store.load()
        return SpeakerLockPolicy.threshold(switchOn: DriveSettings.speakerLockOn(), profile: profile,
                                           model: modelInfo(profile: profile))
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

    /// §6 items 3–4: one request scored against the profile.
    func score(_ request: SpeakerScoreRequest, done: @escaping @Sendable (SpeakerScoreOutcome) -> Void) {
        guard let profile = store.load() else { done(.failed(scoreMs: 0)); return }
        embed(request.frames) { result, ms in
            switch result {
            case .success(let e):
                if let s = profile.score(e) { done(.score(s, scoreMs: ms)) } else { done(.failed(scoreMs: ms)) }
            case .failure:
                done(.failed(scoreMs: ms))
            }
        }
    }

    /// §4 item 5, §3 item 5: delete the profile and turn the lock off.
    func deleteProfile() {
        try? SpeakerEnrollment.delete(store: store)
        UserDefaults.standard.set(false, forKey: DriveSettings.speakerLock)
    }

    /// §4 item 6: a profile of another model turns the lock off.
    func dropInvalidLock() {
        if status() == .invalidModel, DriveSettings.speakerLockOn() {
            UserDefaults.standard.set(false, forKey: DriveSettings.speakerLock)
        }
    }

    /// §5 item 4: scores to Documents (pulled over USB / Files), never audio.
    func writeScores(_ calibration: SpeakerCalibration) {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? calibration.scoresFile.write(to: docs.appendingPathComponent("speaker-calibration-\(stamp).txt"),
                                          atomically: true, encoding: .utf8)
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

/// §3: the rows under 设置 → 声音.
struct SpeakerLockSection: View {
    @AppStorage(DriveSettings.speakerLock) private var lockOn = false
    @State private var status = SpeakerLockStatus.notEnrolled
    @State private var showEnroll = false
    @State private var showCalibrate = false
    @State private var confirmDelete = false
    @State private var note: String?

    var body: some View {
        Toggle("声纹锁定", isOn: Binding(get: { lockOn }, set: { requested($0) }))
        Text(SpeakerLockPolicy.switchText).font(.footnote).foregroundStyle(.secondary)
        Text("这只是基本的声纹确认，可能认错，录音也可能通过，不是安全功能。")
            .font(.footnote).foregroundStyle(.secondary)
        // The sheets and refresh hang on this always-shown row: an EmptyView in a Form is never rendered, so
        // modifiers on it never fire (录入声纹 did nothing on device, build 7910dc7).
        LabeledContent("声纹", value: status.text)
            .sheet(isPresented: $showEnroll, onDismiss: refresh) { SpeakerEnrollmentView() }
            .sheet(isPresented: $showCalibrate, onDismiss: refresh) { SpeakerCalibrationView() }
            .onAppear(perform: refresh)
            .onReceive(NotificationCenter.default.publisher(for: SpeakerModelLocator.changed)) { _ in refresh() }
        if let note { Text(note).font(.footnote).foregroundStyle(.red) }
        switch status {
        case .notEnrolled, .invalidModel:
            Button("录入声纹") { showEnroll = true }
        case .enrolledUncalibrated, .ready:
            Button("重新录入") { showEnroll = true }
            Button("校准") { showCalibrate = true }
        case .modelUnavailable:
            if SpeakerModelLocator.shared.availability.canRetry {
                Button("重试") { SpeakerModelLocator.shared.refresh() }
            }
        }
        if status != .notEnrolled && status != .modelUnavailable {
            Button("删除声纹", role: .destructive) { confirmDelete = true }
                .confirmationDialog("删除声纹？", isPresented: $confirmDelete, titleVisibility: .visible) {
                    Button("删除", role: .destructive) { SpeakerLockService.shared.deleteProfile(); refresh() }
                }
        }
    }

    /// §3 item 4: the switch stays off until a calibrated profile exists; on opens the next step instead.
    private func requested(_ on: Bool) {
        guard on else { lockOn = false; return }
        let service = SpeakerLockService.shared
        let profile = service.store.load()
        switch SpeakerLockPolicy.requestOn(profile: profile, model: service.modelInfo(profile: profile)) {
        case .on: lockOn = true; note = nil
        case .openEnrollment: showEnroll = true
        case .openCalibration: showCalibrate = true
        case .modelUnavailable: note = Self.unavailableNote
        }
    }

    private func refresh() {
        SpeakerLockService.shared.dropInvalidLock()
        status = SpeakerLockService.shared.status()
        // §12 item 4: a model that is still downloading or failed keeps the stored switch (fails closed live).
        if status != .ready && status != .modelUnavailable { lockOn = false }
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
            // A new profile has no threshold: the lock stays off until 校准.
            UserDefaults.standard.set(false, forKey: DriveSettings.speakerLock)
            message = "已录入。请再做一次「校准」，之后才能打开声纹锁定。"
        case .failure(let problem):
            message = problem.text
            takes = []
            index = 0
        }
    }
}

/// §5: 20 lines from the enrolled driver and 20 from another person (more people optional). Scores are kept, audio
/// is not; the owner confirms the suggested threshold.
struct SpeakerCalibrationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var calibration = SpeakerCalibration()
    @State private var forDriver = true
    @State private var index = 0
    @State private var recording = false
    @State private var preparing = false
    @State private var recorder = SpeakerTakeRecorder()
    @State private var message: String?

    private var lines: [String] { SpeakerCalibration.lines }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("谁在说", selection: $forDriver) {
                        Text("录入的人（\(calibration.driver.count)）").tag(true)
                        Text("其他人（\(calibration.others.count)）").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: forDriver) { index = 0 }
                    Text(lines[index % lines.count]).font(.title3)
                    Button(preparing ? "请稍等…" : recording ? "说完了" : "开始说") { Task { await toggle() } }
                        .disabled(preparing)
                }
                if calibration.enough, let t = calibration.suggested {
                    Section("结果") {
                        ForEach(calibration.rows.filter { abs($0.threshold - t) < 0.105 }, id: \.threshold) { row in
                            Text(String(format: "阈值 %.2f：误拒 %d / %d，误通过 %d / %d", row.threshold,
                                        row.falseRejects, calibration.driver.count, row.falseAccepts,
                                        calibration.others.count))
                                .font(.footnote.monospacedDigit())
                        }
                        Text(String(format: "建议阈值 %.2f（没有误通过的最低值）。", t))
                        Text(calibration.caveat).font(.footnote).foregroundStyle(.secondary)
                        Button("使用这个阈值") { confirm(t) }
                    }
                } else {
                    Section { Text("每人至少说 \(SpeakerCalibration.minimumLines) 句。").font(.footnote) }
                }
                if let message { Section { Text(message) } }
            }
            .navigationTitle("校准")
            .interactiveDismissDisabled()
            .toolbar { Button("关闭") { Task { if recording { _ = await recorder.finish() }; dismiss() } } }
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
                message = "对话进行中或麦克风不可用，结束对话后再校准。"
            }
            return
        }
        recording = false
        let take = await recorder.finish()
        guard take.speech >= SpeakerTuning().minScoreSpeech else { message = "没听到说话，请再说一次。"; return }
        let request = SpeakerScoreRequest(utterance: index, generation: 0, kind: .speech, frames: take.frames)
        let outcome: SpeakerScoreOutcome = await withCheckedContinuation { done in
            SpeakerLockService.shared.score(request) { done.resume(returning: $0) }
        }
        guard case .score(let s, _) = outcome else { message = "声纹模型不可用"; return }
        if forDriver { calibration.driver.append(s) } else { calibration.others.append(s) }
        index += 1
    }

    private func confirm(_ threshold: Double) {
        let service = SpeakerLockService.shared
        guard var profile = service.store.load() else { message = "请先录入声纹。"; return }
        profile.threshold = threshold
        profile.calibratedAt = Date()
        do {
            try service.store.save(profile)
            service.writeScores(calibration)
            message = "已保存。现在可以打开声纹锁定。"
        } catch {
            message = "保存失败"
        }
    }
}
