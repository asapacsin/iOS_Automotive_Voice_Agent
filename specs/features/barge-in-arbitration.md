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
never stops or flushes her reply; it is logged as `bargeIn(qualified: false)`. How the stop phrase is
heard while she talks: §14 (keyword spotter, T-022a). The provider must not
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

## 14. Stop phrase while she talks: keyword spotter (iOS, APPROVED 2026-10-30)

**Why.** Device run 25a5cd9 (2026-10-30 14:19–14:21): 别说了 during her reply never stopped her (`bargeIn(qualified:
false)` at 14:19:17, 14:20:03, 14:20:40). Those utterances were not sent to Gemini (F-04 §14, `sentToModel=false
muteReason=reply`) and the phone had no Mandarin recognizer (F-05a §12), so there was no text to match. Even with text,
the match is an exact whole-utterance list: 「好了好了别说了」, 「别说了别说了」, 「别说啦」 and accent mishearings do
not match. Community review 2026-10-30: products that let the user stop the assistant mid-speech use a **small fixed
stop set detected on the device, active only while the assistant talks** (Google Assistant's bare "stop" without the
wake word, only while it is speaking; Pixel quick phrases; car 免唤醒 command words); LLM agent frameworks that stop on
any speech (LiveKit, Pipecat) contradict the owner rule 2026-10-28. Owner 2026-10-30: "Yes, spec it".

**Rule in plain words.** While she talks, a small on-phone keyword spotter listens for a few stop phrases and nothing
else. Hearing one stops her at once. Anything else said while she talks is still ignored (owner rule 2026-10-28).

1. **Stop set (fixed, 7 phrases):** 别说了, 不要说了, 别说啦, 停, 停一下, 闭嘴, 安静. Listed once in NovaCore
   (`StopPhrases`), used both for the spotter's keyword file and for the transcript check (item 5). Repetition and
   lead-ins are covered by the spotter itself (it fires on the phrase inside longer speech: 「好了好了别说了」,
   「别说了别说了」). Changing the set is a spec change.
2. **Spotter.** sherpa-onnx `KeywordSpotter` (same library as F-05a §12, package `Packages/NovaAsrSherpa`) with a
   Mandarin keyword-spotting model (Zipformer KWS trained on Mandarin, e.g. WenetSpeech; model files ≤ 10 MB, fetched and
   checksummed at build like F-05a §12 item 3). Keywords are given as pinyin tokens, so tolerance to accent and
   near pronunciations comes from the acoustic model, not from text matching. Per-keyword threshold and boost are
   constants in `Tuning`, tuned on the device (rows 4–6).
3. **Active only while she talks.** The spotter receives capture frames only while her reply audio is playing plus the
   500 ms echo tail (the same mute window as F-04 §14 item 2). Outside that window it is not fed, so it costs nothing and
   cannot fire. Guidance playback (Amap) is **not** in its window: 别说了 does not stop guidance (unchanged).
4. **On a hit.** The arbiter receives `.stopPhrase` (existing path: flush playback, raise epoch, `bargeIn(qualified:
   true)`), the session goes to listening, nothing is sent to Gemini, no tool call, no driver turn. The utterance that
   contained it stays unsent (F-04 §14 item 1). A second hit within 1 s is ignored.
5. **Transcript check stays as backup.** The existing `ListeningIntent` shut-up check on the local transcript (F-05a §5)
   still runs, using the same `StopPhrases` plus its current extra phrases; whichever fires first stops her, the other
   is ignored for that utterance.
6. **Show it.** While 「她在说话」 is shown (F-04 §14 item 4), a small hint under it: 「说「别说了」可打断」.
7. **Log each decision** (`RuntimeLog.agent`, numbers and phrase index only, never transcript text):
   `stopPhrase source=(kws|transcript) phrase=<index> msFromSpeechStart=<n> score=<n>`; and once per reply that ended
   with an utterance during playback but no hit: `stopPhraseMiss utterance=<id>`. A stop with no driver speech in the
   utterance log within 1 s is a false self-stop and is counted in that log line (`selfStop=true`).
8. **Fallback.** If the spotter model fails to load, item 5 alone applies and 音频测试 shows 「打断词：仅文字」; otherwise
   「打断词：本机」.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `StopPhrases` → spotter keyword file | Every phrase converts to pinyin tokens of the model's token set; build fails otherwise | unit |
| 2 | Spotter fed only inside the playback + 500 ms window | Not fed outside it; a stop-phrase fixture outside the window never stops anything | unit (fake spotter) |
| 3 | Hit while she talks | flush + epoch + `bargeIn(qualified: true)`; nothing sent to Gemini; no driver turn; second hit within 1 s ignored | unit |
| 4 | Device: each of the 7 phrases, said once while she gives a long reply | She stops within 500 ms of the end of the phrase, ≥ 6 of 7 at the first try | D |
| 5 | Device: 「好了好了别说了」, 「别说了别说了」, said quickly or with a southern accent | She stops | D |
| 6 | Device: a 5-minute session with long replies, music in the car, passenger talk, coughs, 「嗯嗯」 | No stop without a stop phrase (`selfStop` count 0) | D |
| 7 | Device: 别说了 while Amap guidance speaks | Guidance is not stopped | D |
| 8 | Log during rows 4–7 | `stopPhrase` lines with source and timing; no transcript text | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-022a | §14 items 1–8: `StopPhrases` (NovaCore), sherpa `KeywordSpotter` in NovaAsrSherpa with a fetched, checksummed Mandarin KWS model, playback-window feeding, `.stopPhrase` on hit, transcript check as backup, hint, log lines, 音频测试 line. Depends on T-016f (library and fetch script) | unit, build, D (rows 4–8) |
