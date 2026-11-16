# F-03 Microphone capture, AEC and gain

**Android status:** IMPLEMENTED; AEC delay/echo device rows NOT_RUN (ECHO-001, AEC-DELAY-DEVICE-001).
**Depends on:** contracts/audio.md

## 1. Purpose
Deliver clean 16 kHz speech frames while the assistant may be speaking, so barge-in works and her own voice is not heard as the driver.

## 2. User-facing behaviour
Invisible to the user; failure shows as her interrupting herself or not hearing the driver.

## 3. Preconditions
Microphone permission granted.

## 4. Inputs and outputs
In: microphone. Out: 10 ms 16 kHz mono PCM16 frames (AEC-cleaned, gain-normalised).

## 5. State transitions
Capture running / stopped; AEC open per session.

## 6. Events and triggers
Session start opens capture + AEC; stop closes them with a bounded join.

## 7. Dependencies and external services
Platform AEC/NS + WebRTC AEC3 (native).

## 8. Error handling and recovery
Read error → `AUDIO_CAPTURE_FAILED`; AEC failure stops capture.

## 9. Concurrency, cancellation, timeouts
Dedicated capture thread; render reference fed right before the playback write.

## 10. Acceptance criteria (iOS)
- Given she plays a 24 kHz reply at normal volume, when the driver is silent, then the uplink gate does not open (no self barge-in) in ≥9/10 device trials.
- Given she is speaking, when the driver says a command, then SpeechStarted fires and playback stops.
- Frames are exactly 10 ms and 16 kHz (unit test on the resampler).

## 11. Existing Android tests
`T/voice/AecFrameContinuityTest`, `AecMetricsTest`, `WebRtcAecIntegrationTest`, `PcmAecFramingTest`, `EchoDelayEstimatorTest`, `MicInputGainTest`, `CaptureSuspensionTest`.

## 12. Source references (Android)
`A/voice/PcmAudioCapture.kt:71,100-110,135,278`; `A/voice/WebRtcAcousticEcho.kt`; `A/voice/MicInputGain.kt:23`; `A/voice/VoiceSessionController.kt:230`.

## 13. Implementation constraints
`AecMetrics.shouldFlushBargeIn` has no callers (DEAD). Device evidence required (I-12).

## iOS notes (PROPOSED unless labelled)
`AVAudioEngine` + `setVoiceProcessingEnabled(true)` (PROPOSED); measure on device before deciding to port WebRTC AEC3 (OQ-IOS-3).

## 14. Another app takes the microphone (iOS, owner request 2026-11-16)

**Why.** Device 2026-11-16: with NovaDrive running, Voice Memos recorded silence or odd sound; with NovaDrive closed it recorded normally. `LiveAudio` restarts its engine on every `AVAudioEngineConfigurationChange` (F-08 §17, for voice processing) and never handles `AVAudioSession.interruptionNotification`, so it takes the microphone back from the other app.

**Sources.** Apple: on an interruption the app stops and waits; at its end it resumes only when the options contain `shouldResume`, otherwise when the user returns ([Apple forums, interruption notifications](https://developer.apple.com/forums/thread/776118); [media services reset](https://developer.apple.com/tutorials/data/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification.md): no restart until the user starts it). Restarting the engine on a configuration change during an interruption breaks the interruption ([Apple forums 113557](https://developer.apple.com/forums/thread/113557)).

1. `LiveAudio` observes `AVAudioSession.interruptionNotification` while running. `.began`: interrupted; nothing restarts the engine.
2. While interrupted, the configuration-change restart does nothing. Otherwise it is unchanged.
3. `.ended` with `shouldResume`: reactivate the session and restart the engine at once. Without it: when the app next becomes active. If reactivation fails, wait for the next return.
4. Record lines: `audio interrupted`, `audio interruption-ended resume=<now|on-return>`, `audio resumed on-return`, `audio resume-failed`. Codes only (I-8).
5. The decision is a pure `MicInterruption` in `NovaVoice`. Nothing else changes: with no other app on the microphone, behaviour is as today.

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Interrupted, then ended with `shouldResume` | No restart while interrupted; resume at the end | unit |
| 2 | Ended without `shouldResume` | No resume until the app is active again, then resume once | unit |
| 3 | No interruption; app becomes active, or a stray end | Nothing changes | unit |
| 4 | Device: NovaDrive conversation running, Voice Memos records 10 s | The memo has normal voice; record shows `audio interrupted` | D |
| 5 | Device: then back to NovaDrive and speak | She hears and answers | D |

| Task | Scope | Verify |
|---|---|---|
| T-021q | Items 1-5; rows 1-5 | unit, build, D |
