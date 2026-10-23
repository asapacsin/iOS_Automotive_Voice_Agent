# F-04 Uplink gate (local VAD)

**Android status:** ACTIVE (JVM + EMU).
**Depends on:** contracts/voice-agent.md §3, F-03

## 1. Purpose
Send only speech to the model and produce speech start/stop events (Gemini emits none).

## 2. User-facing behaviour
She reacts when the driver speaks and ignores steady noise.

## 3. Preconditions
Capture running; lifecycle ACTIVE or SILENT_WAIT.

## 4. Inputs and outputs
In: cleaned frames. Out: gated audio with 300 ms pre-roll; SpeechStarted/Stopped; 1500 ms silence + audioStreamEnd on close.

## 5. State transitions
closed → onset (200 ms) → open → hangover (1200 ms) → closed.

## 6. Events and triggers
Arbiter can force the uplink closed (guidance) — see F-08.

## 7. Dependencies and external services
None.

## 8. Error handling and recovery
Suspicious short segments are flagged (<800 ms & voiced <35%) or held (<1200 ms & voiced <60%).

## 9. Concurrency, cancellation, timeouts
Per-frame, on the capture path.

## 10. Acceptance criteria (iOS)
- Given 3 s of steady noise at the noise bed, the gate stays closed (deterministic unit test with recorded PCM).
- Given speech after silence, the first uploaded frame includes 300 ms pre-roll.
- Given speech ends, audioStreamEnd is sent after 1200 ms hangover + 1500 ms silence.

## 11. Existing Android tests
`T/voice/SpeechUplinkGateTest`, `SpeechUplinkGateDiagnosticsTest`, `SpeechUplinkGateNoiseBedTest`, `UplinkTransitionTest`, `LocalSpeechActivityTest`.

## 12. Source references (Android)
`A/voice/SpeechUplinkGate.kt:299-377`; `GeminiLiveProtocol.kt:99-110`.

## 13. Implementation constraints
Constants are tuned for the Android mic path; re-tune on iOS with the same test corpus (`tools/speech-harness`).

## iOS notes (PROPOSED unless labelled)
Pure DSP over PCM: portable (A). Keep thresholds configurable.
