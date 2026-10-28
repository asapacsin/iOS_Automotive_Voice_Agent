# F-08 Barge-in and speech arbitration

**Android status:** ACTIVE (JVM; EMU; device latency HUMAN).
**Depends on:** contracts/voice-agent.md §5, F-07, F-14

## 1. Purpose
Decide who speaks and who listens: driver, assistant, Amap guidance.

## 2. User-facing behaviour
Driver can interrupt her; guidance and her replies never overlap; she does not speak during a turn manoeuvre.

## 3. Preconditions
Session running.

## 4. Inputs and outputs
In: SpeechStarted, playback state, guidance speaking flag, focus changes, distance to manoeuvre. Out: PLAY/HOLD/DROP, uplink open/closed.

## 5. State transitions
Reply decision (highest rule first, contracts/voice-agent.md §5):
R4 permanent audio-focus loss → DROP; R6 navigating outside the 10 s permitted window → DROP;
R1 guidance speaking → HOLD; R5 transient focus loss → HOLD; R6a an unstarted reply within 150 m of a
manoeuvre → HOLD up to 8 s or until the distance jumps > 20 m; else PLAY.
Uplink: open → closed while guidance speaks (+ 500 ms tail, reopens after at most 20 s); R0 if the driver
is mid-utterance when guidance starts, it stays open up to 8 s.
Barge-in (owner rule 2026-10-28, replaces sound barge-in): she stops speaking **only** when the driver
says a stop phrase (ListeningIntent `shutUp`: 「别说了」「不要说了」「闭嘴」「安静」…) → playback epoch
invalidated, audio flushed. SpeechStarted during playback alone (any sound, voice, or her own echo)
never stops or flushes her reply; it is logged as `bargeIn(qualified: false)`. The provider must not
drop its reply on driver activity either (Gemini `activityHandling: NO_INTERRUPTION`).
Why: phone log 2026-10-28 17:31–17:33 — she was cut off 1–2 s into each answer (bargeIn at 17:31:14,
17:32:02, 17:32:20) with no driver speech, then the gate stayed open ~16 s on her echo.

## 6. Events and triggers
SpeechStarted during playback; guidance start/end; focus loss/gain.

## 7. Dependencies and external services
None.

## 8. Error handling and recovery
Sound during playback is never a barge-in (owner rule 2026-10-28); only a stop phrase stops her.

## 9. Concurrency, cancellation, timeouts
Epoch invalidation is synchronous with the decision.

## 10. Acceptance criteria (iOS)
- Given she is speaking, when the driver starts talking, then playback stops within 300 ms (device target; UNVERIFIED baseline).
- Given guidance is speaking, when a reply is ready, then it is held and plays after guidance + tail.
- Given within 150 m of a manoeuvre, an unstarted reply is held ≤8 s.

## 11. Existing Android tests
`T/voice/BargeInEvidenceTest`, `FullDuplexBargeInTest`, `PlayoutBargeInQualificationTest`, `SpeechArbiter*Test`, `WorkloadHoldWiringTest`, `GuidanceSparingCancelTest`.

## 12. Source references (Android)
`A/voice/SpeechArbiter.kt:291-300`; `A/voice/SpeechAuthority.kt`; `A/voice/PlayoutBargeInQualification.kt:7`; `I/VoiceSessionController.kt:385-475`.

## 13. Implementation constraints
Arbiter is the single owner (I-10).

## iOS notes (PROPOSED unless labelled)
Portable logic (A); audio interruption notifications on iOS (`AVAudioSession.interruptionNotification`) map to focus loss R4/R5 — PROPOSED.
