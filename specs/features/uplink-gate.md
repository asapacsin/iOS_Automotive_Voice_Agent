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

## 14. Listening while she talks (iOS, APPROVED 2026-10-30, replaces the T-040f mute)

**Why.** Device run 7565bcf (2026-10-30, 52 turns): 8 turns were never sent to Gemini while the app still waited for
her answer (`emptyResponseReask` 6 s later, then a reply to 「请回应我刚才说的话」 instead of to the driver); a 第二个 /
第一个 said right as she finished was lost (`lateToolResultDropped`). Cause: T-040f (0beedf3) decides twice —
`GateBox.toModel` on the capture thread decides whether an utterance goes to Gemini, `AgentState.utteranceCounts`
separately decides whether it is a driver turn — and it decides once per whole utterance, at its first frame.
Owner 2026-10-30 after the community review (Pipecat user-input muting, LiveKit uninterruptible mode, a Gemini Live
production team's send flag): "good just write this to spec".

**Rule in plain words.** While she talks, what the microphone hears is ignored. Once she stops, the driver is heard
again. One place decides, everything follows it, and the driver can see when it is their turn.

1. **One decision.** The capture side (`GateBox`) alone decides, per utterance, whether it goes to Gemini. The
   decision travels with the gate event (`speechStarted(sentToModel:)`); `AgentState` reads it and never re-checks
   "is she audible". An utterance not sent to Gemini drops **everything together**: audio, activityStart/End, the
   driver turn, `answerOwed`, the reply clock (`emptyResponseReask`), and its transcript for the tool path. Its
   transcript may still show on screen (F-05a §6: display only) and still feeds the local 别说了 check.
2. **Ignore only while she talks.** Muted = her reply or guidance is playing, plus the echo tail (500 ms after it
   ends; keep it as short as the device allows). When the mute ends while the gate is open, the gate **cuts the
   utterance there**: the muted part ends without being sent, and a fresh utterance starts at that frame (with its
   pre-roll) and is sent normally. Speech that goes on after she stops is never lost because it began a moment early.
3. **Mute state is read where it is used.** The capture side reads the mute state directly at each frame (the state
   is written under the same lock when playback starts and stops), not from an effect delivered later; there is no
   window in which one side thinks she is talking and the other does not.
4. **Your turn.** The screen shows the state at all times: 「她在说话」 while muted, 「请说」 when listening (the
   existing session indicator may carry it). A short soft tone when the mute ends after her reply is optional, owner
   choice at device test (default off; a tone after every reply may be too much in a car).
5. **别说了 always works.** While muted, the local stop phrase (F-08) still stops her at once; it is never sent to
   Gemini as an utterance.
6. **Never muted before she has spoken.** At session start, and whenever nothing of hers is playing or in the echo
   tail, every utterance is sent. Device run 7565bcf dropped utterances at 22:38:34, before her first reply; T-004i
   must find and remove that cause, and row 4 proves it.
7. **Log each utterance** (`RuntimeLog.agent`, one line at its end, no audio or words):
   `utterance id start end endReason(silence|cutAtUnmute|stopPhrase|streamEnd) sentToModel muteReason(reply|guidance|echoTail|none) peakDb noiseFloorDb classifierMax`.
   A driver turn that got no model response logs `turnUnanswered id` before the re-ask.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | An utterance starts while she talks and ends before she stops | Not sent; no driver turn, no `answerOwed`, no re-ask; logged `sentToModel=false muteReason=reply` | unit |
| 2 | An utterance starts 300 ms before she stops and goes on 2 s after | Cut at unmute: first part dropped, a new utterance from the unmute frame is sent and answered | unit |
| 3 | An utterance after she stopped (past the echo tail) | Sent; driver turn; answered | unit |
| 4 | First utterance of a session, nothing of hers played | Sent | unit, D |
| 5 | Capture side and `AgentState` for the same utterance | Never disagree: a not-sent utterance never opens a turn, a sent one always does | unit |
| 6 | 别说了 while she talks | She stops at once; nothing sent to Gemini | unit, D |
| 7 | 「导航去珠海站」 → she reads the list → 「第一个」 said right after she finishes | The pick happens; no `emptyResponseReask`, no `lateToolResultDropped` | D |
| 8 | One device session of 20+ turns | `emptyResponseReask` only when Gemini really did not answer a sent turn; every utterance has a log line | D |
| 9 | Screen while she talks / after | 「她在说话」 / 「请说」 | S, D |

**Late end of speech (separate, decided from the logs).** In the same run 9 of 52 utterances stayed open 7–13 s
for short commands (gate hangover is 1 200 ms of quiet, by loudness). Likely causes: background noise above the
threshold, voice-processing AGC lifting quiet noise, or the F-04a classifier not confirming. T-004j reads the
per-utterance log lines of a device run and fixes the cause it shows, in this order of preference: AGC off or a
noise-floor-relative threshold; then a maximum utterance length; then a trained VAD model. Its acceptance: no short
command stays open more than 3 s in a normal room or parked car.

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-004i | §14 items 1–7: one send decision carried on the gate event; drop everything together; cut at unmute; mute read at the frame; never muted before her first audio (find the 7565bcf cause); your-turn indicator; per-utterance log line. Replaces the T-040f mute (`GateBox.toModel`, `AgentState.utteranceCounts` / `modelUplinkMuted`) | unit (rows 1–6), build, D (rows 4, 6–9) |
| T-004j | §14 late end of speech: from the T-004i log of a device run, fix what keeps the gate open | unit, D |
