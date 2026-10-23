# iOS feasibility

Vendor documentation was read on 2026-10-23 (Apple, Amap, Google, iFlytek; sources in
open-questions.md). **VERIFIED** below means "confirmed in the vendor's documentation", not "run on
an iPhone": no iOS build or device run has happened yet. What only a device can show is labelled
DEVICE_SPIKE; product choices are labelled OWNER.

## Standalone iPhone app (required)

| Subsystem | Proposed iOS technology | Limitations / risks | Label |
|---|---|---|---|
| UI | Swift + SwiftUI; map view hosted via `UIViewRepresentable` | Amap view is UIKit | PROPOSED |
| Audio session | `AVAudioSession` `.playAndRecord`, mode `.voiceChat`, options `.defaultToSpeaker`, `.allowBluetooth`, `.duckOthers` | Mode choice affects AEC and Bluetooth routing; car Bluetooth HFP lowers quality | PROPOSED |
| Capture + AEC | `AVAudioEngine` input node with `setVoiceProcessingEnabled(true)`; `AVAudioConverter` to 16 kHz | API VERIFIED; its quality vs WebRTC AEC3 with loud speaker playback is not documented | DEVICE_SPIKE (OQ-IOS-3) |
| Playback | `AVAudioPlayerNode` on the same engine (so voice processing has the reference), 24 kHz buffers, epoch flush via `stop()`/reschedule | Must keep render reference in the same engine | PROPOSED |
| Interruptions | `AVAudioSession.interruptionNotification`, `routeChangeNotification` → arbiter R4/R5 | Phone calls and Siri interrupt the session | PROPOSED |
| Background | `UIBackgroundModes` `audio` + `location` while a voice session or guidance is active | Guideline 2.5.4: background services only for their intended purposes; background listening only while voice/guidance is active; mic indicator shown | VERIFIED, review risk (OQ-IOS-4) |
| Wake word | iFlytek iOS SDK (`IFlyVoiceWakeuper`, `.jet` resource, threshold `0:1450`) | SDK bound to app id; in-app wake only (no system-level wake); same `.jet` needs the iOS SDK for the same app id | VERIFIED, OWNER download (OQ-IOS-1) |
| ASR | None needed (Gemini transcription) | `SFSpeechRecognizer` only as an optional fallback | PROPOSED |
| Realtime (Gemini Live) | `URLSessionWebSocketTask` (or Firebase AI Logic Live API for Swift) | Connection ~10 min, audio session 15 min without compression: resumption + sliding window required; ephemeral tokens recommended over a raw key | VERIFIED (OQ-IOS-5) |
| TTS | Azure Speech REST (same as Android); not `AVSpeechSynthesizer` (voice parity) | — | PROPOSED |
| Navigation | Amap iOS Navi SDK (`AMapNaviKit`) + Amap Web REST | Multi-route (`naviRoutes`), guidance text (`playNaviSoundString`, built-in TTS off by default), cameras/limits (`updateCameraInfos`), simulated drive (`startEmulatorNavi`) all documented; route-select call name to confirm in M3 | VERIFIED (OQ-IOS-2) |
| Location | `CLLocationManager` (when-in-use; always only if background nav) + WGS-84→GCJ-02 | Amap SDK may provide conversion | PROPOSED |
| Vehicle controls | Simulated in-app (as Android) | — | PROPOSED |
| Music | Bundled `AVAudioPlayer`; Apple Music via MusicKit `ApplicationMusicPlayer` (subscription; plays in background with the audio mode) | No API for third-party players; named music only with Apple Music | VERIFIED, OWNER (OQ-IOS-7) |
| Phone | `CNContactStore` + `tel://` (system confirm sheet) | Extra system confirmation is added on top of the voice confirmation | PROPOSED |
| Vision | `AVCaptureSession` still frame → Qianfan HTTP | Camera permission string | PROPOSED |
| Secrets | Keychain; settings in UserDefaults | — | PROPOSED |
| Permissions | `NSMicrophoneUsageDescription`, `NSLocationWhenInUseUsageDescription` (+ Always if needed), `NSCameraUsageDescription`, `NSContactsUsageDescription` | Strings in Chinese and English | PROPOSED |

## Optional CarPlay integration

- Every CarPlay app needs a category entitlement that Apple grants on request, and **one app has one
  category** (only EV charging + fueling combine). So 小诺 on CarPlay is either a **navigation** app
  (map in the base view, turn-by-turn maneuvers through the templates, guidance stops when the car's
  own navigation starts, prompts mix with car audio) or a **voice-based conversational** app (iOS
  26.4+, voice first, `CPVoiceControlTemplate`, audio session only while voice is active). VERIFIED
  (CarPlay Developer Guide, 2026-10-13 edition); the choice is OQ-IOS-8 (OWNER).
- Amap provides a CarPlay adaptation demo for `AMapNaviDriveView`. VERIFIED (OQ-IOS-2).
- CarPlay gives **no** access to climate, seats or windows: its framework and guide offer templates
  only. VERIFIED (OQ-IOS-6). Vehicle controls stay simulated.
- Voice in CarPlay uses the car's microphone over the CarPlay link; how `.voiceChat` processing
  behaves there is DEVICE_SPIKE.
- Treat CarPlay as a later milestone (M7), not part of parity.

## Android-only capabilities that do NOT transfer

| Android capability | Used for | iOS position |
|---|---|---|
| Foreground service (microphone) | Keep session alive in background | No equivalent; background `audio`/`location` modes for their intended use only (OQ-IOS-4, guideline 2.5.4) |
| Media-session control of other apps | play_music handoff + now-playing verification | Not possible for third-party apps |
| `ACTION_PLAY_FROM_SEARCH` intents | Music handoff | Not available |
| iFlytek MSC Android jar | Wake word | iOS `iflyMSC.framework`, in-app wake only (OQ-IOS-1) |
| `AudioRecord` VOICE_COMMUNICATION + WebRTC AEC3 JNI | AEC | Voice processing unit or port AEC3 in C++ |
| Debug broadcast receiver | CI control | Replace with XCUITest launch arguments / a debug URL scheme |
