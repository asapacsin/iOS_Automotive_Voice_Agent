import NovaAgent
import NovaAsrSherpa
import NovaAudio
import NovaKit
import NovaPorts
import NovaServices
import NovaVoice
import UIKit

/// T-061 bridge: while the app is idle in the foreground it captures the mic for the wake engine only;
/// 你好小诺 releases the mic and starts a session (one capture only, ADR-006). The session's own capture
/// takes over; when it stops, the listener is re-applied. `WakeListenPolicy` decides.
/// F-01 §14 (T-060a): the engine is the bundled sherpa keyword spotter (`WakeEngineKind.selected`), no keys; the
/// 「唤醒词」 setting is read here; the screen stays on while listening; the idle screen's hint follows `onArmed`.
@MainActor
final class WakeListener {
    private var policy = WakeListenPolicy()
    private var audio: LiveAudio?
    private var detector: RetryingWakeDetector?
    private var events: Task<Void, Never>?
    /// §14 item 7: `isIdleTimerDisabled` while listening, the value from before afterwards.
    private var screen = IdleTimerHold()
    private let clock: any NovaClock
    private let onArmed: @MainActor (Bool) -> Void
    private let onWake: @MainActor (NovaInstant) async -> Void
    private let kind = WakeEngineKind.selected
    /// F-04b §6 item 7 (T-013e): the last 2 s of frames, scored on a detection when 声纹锁定 is on.
    private let recent = RecentBox()
    private var wakeCheck = SpeakerPhraseCheck(kind: .wake)
    /// One engine for the app run, so the sherpa spotter is loaded once and kept between listens.
    private lazy var engine: any WakeEngine = makeEngine()

    private func makeEngine() -> any WakeEngine {
        switch kind {
        case .sherpa: return SherpaWakeEngine(directory: LocalSpeechModels.kwsDirectory)
        case .iflytek: return AIKitWakeEngine(credentials: KeychainCredentialStore())
        }
    }

    /// `clock` stamps the wake for `wake-to-listening`; `onArmed` is true while the detector is ready.
    init(clock: any NovaClock, onArmed: @escaping @MainActor (Bool) -> Void,
         onWake: @escaping @MainActor (NovaInstant) async -> Void) {
        self.clock = clock
        self.onArmed = onArmed
        self.onWake = onWake
    }

    func update(scene: AppScenePhase? = nil, sessionRunning: Bool? = nil) async {
        if let scene { policy.foreground = scene == .foreground }
        if let sessionRunning {
            // A finished session is a new chance after a give-up (keys or permission may have changed).
            if policy.sessionRunning && !sessionRunning { policy.gaveUp = false }
            policy.sessionRunning = sessionRunning
        }
        policy.engine = kind
        switch kind {
        case .sherpa:
            policy.engineAvailable = SherpaWakeEngine.modelPresent(in: LocalSpeechModels.kwsDirectory)
            policy.keysSaved = false
        case .iflytek:
            policy.engineAvailable = AIKitWakeEngine.sdkLinked
            policy.keysSaved = SettingsReadiness(credentials: KeychainCredentialStore(), settings: DefaultsSettingsStore()).wakeAppID
        }
        policy.enabled = DriveSettings.wakeWordOn()
        policy.micGranted = MicrophonePermission.current == true
        if policy.shouldListen { await listen() } else { await release() }
    }

    private func listen() async {
        guard detector == nil else { return }
        let detector = RetryingWakeDetector(engine: engine, clock: SystemClock())
        self.detector = detector
        let clock = clock
        events = Task { [weak self] in
            for await event in detector.events {
                guard let self, self.detector === detector else { return }
                switch event {
                case .wake:
                    let at = clock.now
                    // F-04b §6 item 7: not accepted = she stays asleep and the listener stays armed.
                    guard await self.speakerAccepts() else {
                        RuntimeLog.agent.notice("wake-rejected")
                        continue
                    }
                    // §14 item 12: no words, no audio (I-8).
                    RuntimeLog.agent.notice("\(DiagnosticEvent.wakeDetected.logLine, privacy: .public)")
                    await self.release()
                    // Not in this (now cancelled) task: the session start must not inherit its cancellation.
                    Task { @MainActor [self] in await self.onWake(at) }
                    return
                case .unavailable:
                    self.policy.gaveUp = true
                    await self.release()
                case .ready:
                    self.onArmed(true)
                case .failed:
                    self.onArmed(false)
                }
            }
        }
        let audio = LiveAudio()
        do {
            let recent = recent
            try audio.start { frame in
                detector.feed(frame)
                recent.append(frame)
            }
        } catch {
            RuntimeLog.agent.error("wake capture failed")
            await release()
            return
        }
        self.audio = audio
        UIApplication.shared.isIdleTimerDisabled = screen.hold(current: UIApplication.shared.isIdleTimerDisabled)
        await detector.arm()
    }

    /// Lock off: true at once. Lock on: scores the phrase's recent audio (the record of a woken session does not
    /// exist yet, so the line goes to the log only).
    private func speakerAccepts() async -> Bool {
        wakeCheck.setLock(threshold: SpeakerLockService.shared.liveThreshold())
        guard case .verify(let request) = wakeCheck.hit(recent: recent.frames()) else {
            return !wakeCheck.locked
        }
        let started = Date()
        let outcome: SpeakerScoreOutcome = await withCheckedContinuation { done in
            SpeakerLockService.shared.score(request) { done.resume(returning: $0) }
        }
        let waitMs = Int(Date().timeIntervalSince(started) * 1000)
        guard let verdict = wakeCheck.result(outcome, check: request.utterance, generation: request.generation,
                                             waitMs: waitMs) else { return false }
        RuntimeLog.agent.notice("\(verdict.line.logLine, privacy: .public)")
        return verdict.act
    }

    private func release() async {
        onArmed(false)
        if let restore = screen.release() { UIApplication.shared.isIdleTimerDisabled = restore }
        events?.cancel()
        events = nil
        await detector?.disarm()
        detector = nil
        audio?.stop()
        audio = nil
        recent.clear()
    }
}

/// The capture thread appends; the main actor reads on a detection.
private final class RecentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ring = RecentFrames()
    func append(_ f: PCMFrame16k) { lock.withLock { ring.append(f) } }
    func frames() -> [PCMFrame16k] { lock.withLock { ring.frames } }
    func clear() { lock.withLock { ring.clear() } }
}
