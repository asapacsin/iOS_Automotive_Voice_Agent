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
