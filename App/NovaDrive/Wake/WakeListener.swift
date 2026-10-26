import NovaAgent
import NovaAudio
import NovaKit
import NovaPorts
import NovaServices
import NovaVoice

/// T-061 bridge: while the app is idle in the foreground it captures the mic for the wake engine only;
/// 你好小诺 releases the mic and starts a session (one capture only, ADR-006). The session's own capture
/// takes over; when it stops, the listener is re-applied. `WakeListenPolicy` decides.
@MainActor
final class WakeListener {
    private var policy = WakeListenPolicy()
    private var audio: LiveAudio?
    private var detector: RetryingWakeDetector?
    private var events: Task<Void, Never>?
    private let onWake: @MainActor () async -> Void

    init(onWake: @escaping @MainActor () async -> Void) { self.onWake = onWake }

    func update(scene: AppScenePhase? = nil, sessionRunning: Bool? = nil) async {
        if let scene { policy.foreground = scene == .foreground }
        if let sessionRunning {
            // A finished session is a new chance after a give-up (keys or permission may have changed).
            if policy.sessionRunning && !sessionRunning { policy.gaveUp = false }
            policy.sessionRunning = sessionRunning
        }
        let store = KeychainCredentialStore()
        policy.engineLinked = AIKitWakeEngine.sdkLinked
        policy.configured = SettingsReadiness(credentials: store, settings: DefaultsSettingsStore()).wakeAppID
        policy.micGranted = MicrophonePermission.current == true
        if policy.shouldListen { await listen(store) } else { await release() }
    }

    private func listen(_ store: KeychainCredentialStore) async {
        guard detector == nil else { return }
        let detector = RetryingWakeDetector(engine: AIKitWakeEngine(credentials: store), clock: SystemClock())
        self.detector = detector
        events = Task { [weak self] in
            for await event in detector.events {
                guard let self else { return }
                switch event {
                case .wake:
                    await self.release()
                    await self.onWake()
                case .unavailable:
                    self.policy.gaveUp = true
                    await self.release()
                case .ready, .failed:
                    break
                }
            }
        }
        let audio = LiveAudio()
        do {
            try audio.start { frame in detector.feed(frame) }
        } catch {
            RuntimeLog.agent.error("wake capture failed")
            await release()
            return
        }
        self.audio = audio
        await detector.arm()
    }

    private func release() async {
        events?.cancel()
        events = nil
        await detector?.disarm()
        detector = nil
        audio?.stop()
        audio = nil
    }
}
