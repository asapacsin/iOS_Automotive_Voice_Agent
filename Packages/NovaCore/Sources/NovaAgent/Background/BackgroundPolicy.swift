import NovaKit

/// The scene phase as the app reports it (SwiftUI `ScenePhase`, mapped in the App target).
public enum AppScenePhase: Sendable, Hashable { case foreground, inactive, background }

/// F-23 / ios-architecture §11.3 (T-062): what may stay alive for a scene, listening state and
/// navigation phase. Pure; the App's scene-phase bridge applies it.
///
/// The SLEEP-in-background row follows the OWNER answer to OQ-IOS-13 recorded in §11.3 (DEEP_IDLE at
/// once, socket closed); `inactive` (control centre, a call banner) keeps the foreground decision.
public struct BackgroundDecision: Sendable, Hashable {
    /// nil: as the listening lifecycle says (foreground only).
    public let keepMic: Bool?
    public let keepSocket: Bool?
    public let backgroundLocation: Bool
    /// Deactivate the audio session so the app may suspend.
    public let deactivateAudioSession: Bool
    /// Drive the lifecycle to DEEP_IDLE now.
    public let forceDeepIdle: Bool

    public static func decide(scene: AppScenePhase, listening: ListeningState, navigating: Bool) -> BackgroundDecision {
        guard scene == .background else {
            return BackgroundDecision(keepMic: nil, keepSocket: nil, backgroundLocation: false,
                                      deactivateAudioSession: false, forceDeepIdle: false)
        }
        if navigating {
            // Guidance goes on with the screen locked; the mic indicator stays visible.
            return BackgroundDecision(keepMic: true, keepSocket: true, backgroundLocation: true,
                                      deactivateAudioSession: false, forceDeepIdle: false)
        }
        switch listening {
        case .active, .silentWait:
            // Until the turn completes and the lifecycle sleeps.
            return BackgroundDecision(keepMic: true, keepSocket: true, backgroundLocation: false,
                                      deactivateAudioSession: false, forceDeepIdle: false)
        case .sleep:
            // No background listening just for the wake word (App Review 2.5.4).
            return BackgroundDecision(keepMic: false, keepSocket: false, backgroundLocation: false,
                                      deactivateAudioSession: true, forceDeepIdle: true)
        case .deepIdle:
            return BackgroundDecision(keepMic: false, keepSocket: false, backgroundLocation: false,
                                      deactivateAudioSession: true, forceDeepIdle: false)
        }
    }
}
