# F-01 Wake word

**Android status:** IMPLEMENTED (iFlytek MSC, offline). Device-fired 2026-09-19 (SPEC-001); WAKE-ENGINE/WAKE-SYNTH rows NOT_RUN.
**Depends on:** contracts/audio.md, contracts/voice-agent.md §2, F-02

## 1. Purpose
Start or resume a conversation hands-free with the wake phrase (你好小诺; baked into the `.jet` model, not a string in code — UNVERIFIED wording).

## 2. User-facing behaviour
- Idle (SLEEP or DEEP_IDLE): saying the wake phrase starts listening; the chip shows 聆听中.
- A tap on the assistant button does the same.
- A late or duplicate wake callback never starts a second session.

## 3. Preconditions
Microphone permission; iFlytek app id configured; session not already ACTIVE.

## 4. Inputs and outputs
In: 16 kHz PCM frames from the shared capture. Out: one `wake` event.

## 5. State transitions
Detector: IDLE → AUTHORISING → READY → LISTENING; ERROR on failure. Wake counts only while armed (`WakeArming`).

## 6. Events and triggers
Wake fires → listening lifecycle SLEEP→ACTIVE (same connection) or DEEP_IDLE→ACTIVE (new session).

## 7. Dependencies and external services
iFlytek MSC SDK, offline model `ivw/wakeword.jet`, threshold `0:1450`.

## 8. Error handling and recovery
Capture/engine failures retry with bounded backoff: base 1.5 s, max 30 s, 6 attempts (`BoundedRetry`).

## 9. Concurrency, cancellation, timeouts
Controller reconciles every 1.5 s on the main thread. While idle the wake detector owns the mic; when a session starts it hands the stream over (one capture only, ADR-006).

## 10. Acceptance criteria (iOS)
- Given SLEEP, when the wake phrase is played, then state becomes ACTIVE within the detector latency and exactly one session start occurs.
- Given ACTIVE, when a duplicate wake arrives, then nothing restarts.
- Given engine init fails 6 times, then the app shows wake unavailable and the UI button still works.

## 11. Existing Android tests
`T/wake/WakeArmingTest`, `WakeWordControllerTest`, `WakeWordDetectorTest`, `WakeWordSettingsTest`, `WakeWordCredentialsTest`.

## 12. Source references (Android)
`A/wake/IflytekWakeWordDetector.kt:20,279-286`; `A/wake/WakeWordController.kt:262`; `A/wake/WakeArming.kt:13-19`.

## 13. Implementation constraints
Never two concurrent captures. Wake must work only in the foreground on iOS unless background audio is justified (see ios-feasibility).

## iOS notes (PROPOSED unless labelled)
iFlytek has an iOS wake SDK (`IFlyVoiceWakeuper`, `.jet` resource, threshold `0:1450`), bound to the app id and in-app only (VERIFIED, OQ-IOS-1); the same `.jet` needs the iOS SDK for the same app id (OWNER). Fallback: Picovoice Porcupine custom keyword (PROPOSED). `SFSpeechRecognizer` is not meant for always-on keyword spotting (PROPOSED). Background always-listening on iPhone is restricted; plan for a foreground-only wake word plus a push-to-talk button, CarPlay voice button as optional.
