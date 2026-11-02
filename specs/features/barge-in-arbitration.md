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

## 15. A stop phrase also ends the reply for Gemini (iOS, APPROVED 2026-10-31)

**Why.** Device run ac53787 (2026-10-31 15:23–15:28): 别说了 stopped her every time (`stopPhrase source=kws` ×5,
`source=transcript` ×1), but afterwards new questions got the same answer whatever was asked. Log pattern after each
stop: `turnUnanswered` + `emptyResponseReask` ×5 in 4 minutes (15:23:41, 15:25:34, 15:25:45, 15:27:16, 15:27:24,
15:27:33), and follow-up questions with `sentToModel=false muteReason=reply` (15:27:29, 15:27:38). Causes:
- **Gemini is never told.** §14 stops her locally only (flush, epoch; "nothing to Gemini"). The session runs with manual
  activity detection (`automaticActivityDetection.disabled`, App/NovaDrive/AgentRuntime.swift) and
  `activityHandling: NO_INTERRUPTION` (`interruptsReply = false`, GeminiCodec), so Gemini keeps its old reply going and
  a new question waits behind it or is not answered in time.
- **The re-ask points back.** After 6 s without an answer the pipeline sends 「请回应我刚才说的话」
  (`DriverTurnPipeline.reaskText`); with the old reply still current for Gemini, it answers the old topic again.
- **The mute outlives the stop.** The T-004i reply mute is still on after a stop, so a question right after it is not
  sent.
- **A transcript stop drops the next answer.** `abandonNextTurn` (AgentState `heard`) discards Gemini's next turn to
  swallow a reply to 别说了; if that next turn is the answer to a new question, the answer is lost.
Owner 2026-10-31: "write this on spec" (the point: tell Gemini the reply has ended).

**Rule in plain words.** 别说了 ends her answer for both the phone and Gemini. Her next answer is always to the
driver's newest question, never the old topic again.

1. **Tell Gemini (interrupt).** Switch the session to `activityHandling: START_OF_ACTIVITY_INTERRUPTS`
   (`interruptsReply = true`). Because activity detection is manual and the T-004i mute sends no `activityStart` while
   she talks, an interruption only happens when the app sends one on purpose. On a stop phrase (either source), after
   the local flush, the provider sends `activityStart` immediately followed by `activityEnd` with no audio between,
   so Gemini cancels the running generation and the stop phrase itself is not a question. The server's `interrupted`
   for that turn closes it as cancelled (existing `.interrupted` path). If the implementer finds on a recorded session
   (`GeminiRecorder`) that an empty activity makes Gemini open a reply turn, that one turn is abandoned (item 4) and
   the finding is recorded in the PR; if no `interrupted` arrives within 1 s, log `stopSyncNoInterrupt` and continue
   (items 2–4 still apply).
2. **Unmute at once.** On a stop the arbiter treats her reply as drained (`replyDrained`): the reply mute ends, so the
   next driver utterance is sent (`sentToModel=true muteReason=none`). The stop phrase's own utterance stays unsent
   as today.
3. **No re-ask pulling back.** The no-answer clock does not run for the stop phrase's own utterance. For the next
   driver utterance the re-ask, if it fires, names the newest question using the local transcript (F-05a §12):
   「请回答我最新的这句话：「<transcript>」」 (falls back to today's text when no transcript is available). A re-ask
   is never sent while the stopped reply's `interrupted` / turn close is still awaited (at most 1 s).
4. **Only the stop's own reply is dropped.** `abandonNextTurn` from a transcript stop is cleared as soon as a new
   driver utterance is sent; it then never discards the answer to that new question. With item 1 in place, an
   abandoned turn is one Gemini opens for the empty activity, or the late tail of the stopped reply.
5. **Logs.** `stopSync sent`, `stopSync interrupted ms=<from send>`, `stopSyncNoInterrupt`, `reaskSuppressed
   reason=stop`, `abandonCleared reason=newUtterance`; no audio, no text payloads beyond the existing transcript rules.
6. **Other interruptions unchanged.** No new barge-in trigger: only the §14 stop set stops her. Navigation guidance
   (F-14) is never interrupted by this path, as §14 row 7.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Session setup | `activityHandling` = `START_OF_ACTIVITY_INTERRUPTS`, `automaticActivityDetection.disabled` = true | unit (codec) |
| 2 | Scripted: long reply playing, stop phrase spotted | Local flush, then provider sends `activityStart`, `activityEnd` in that order with no audio between; `stopSync sent` | unit (AgentCore + fake provider) |
| 3 | Scripted: stop, then `interrupted` for the old turn, then a new utterance | Old turn closed as cancelled; mute off; new utterance sent; its reply is spoken | unit |
| 4 | Scripted: stop, then no answer to the next utterance for 6 s | Re-ask names the newest transcript; never 「请回应我刚才说的话」 when a transcript exists | unit (pipeline) |
| 5 | Scripted: transcript stop, then a new utterance, then Gemini's turn | That turn is spoken (not abandoned); `abandonCleared` logged | unit |
| 6 | Recorded Gemini session: long answer, empty activity mid-reply | `interrupted` arrives; outcome (whether a reply turn opens) recorded in the PR | S |
| 7 | Device: 「介绍一下珠海」, 别说了, then 「现在几点」/「打开空调」/「讲个笑话」 in turn | Each answer matches its own question; never the 珠海 answer again; log shows `stopSync interrupted`, next utterance `sentToModel=true` | D |
| 8 | Device: repeat row 7 five times in one session | 5/5 answer the new question; no `turnUnanswered` right after a stop | D (log) |
| 9 | Device: §14 rows (7 stop phrases, no self-stop from music/cough, guidance not interrupted) | Still pass | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-022b | §15 items 1–6: interrupting activity handling, empty activity on a stop, unmute on stop, re-ask suppression and newest-question text, scoped `abandonNextTurn`, logs; unit rows 1–5; recorded row 6; device rows 7–9 | unit, S, D (rows 7–9) |

## 16. After 别说了 nothing is sent until the driver really says something (iOS, APPROVED 2026-10-31)

**Why.** Device run e00fc27 (2026-10-31 18:30, 「珠海有什么好玩的」): §15 works: `stopPhrase source=kws` at 18:30:36.756,
`stopSync sent`, `stopSync interrupted ms=193`. But she started talking again 2.5 s later (speaking 18:30:39, and again
18:30:50 after the second 别说了). Log:
- The spotter fired 524 ms into the phrase (`msFromSpeechStart=524`), before 别说了 was finished.
- §15 item 2 ends the reply mute at the stop, so the open muted utterance was cut there (`utterance 2 start=15890
  end=16500 endReason=cutAtUnmute sentToModel=false`) and the rest of the same speech became a new **sent** utterance
  (`utterance 3 start=16500 end=17700 endReason=silence sentToModel=true`, peakDb 37, local ASR `firstPartialMs=-`: no
  words). Gemini got a turn with no question and continued the old topic.
Community review 2026-10-31: a stop command consumes the whole speech run up to the next pause and never reaches the
model as a question (Home Assistant stop-word discussions, box3-assistant "Stop" barge-in); LiveKit Agents counts an
interruption as real only with recognised words (`min_words`, `min_duration` 0.5 s) and treats an interruption with no
transcript within `false_interruption_timeout` (2 s) as false, generating no new reply; Pipecat gates turns on a
minimum word count and drops audio while muted (`STTMuteFilter`). Unlike LiveKit's default, she does not resume after a
stop: 别说了 is always intentional. Owner 2026-10-31: "write spec here".

**Rule in plain words.** 别说了 takes the whole stretch of speech it is part of, up to the next pause, and none of it
is sent. In the next few seconds, a sound is sent to Gemini only once the phone has recognised real words in it;
coughs, noise or the end of the stop word are dropped. A real question right after 别说了 is still answered.

1. **The stop utterance runs to the pause (uplink gate, NovaVoice).** When a stop phrase (either source) ends her
   reply while a muted utterance is open, that utterance is not cut at the unmute (§15 item 2 / F-04 §14 item 2 do not
   apply to it). It stays unsent until the normal closing silence; its record gets `endReason=stopPhrase`,
   `sentToModel=false`. A new utterance starts only after that close. Implemented as a flag on `SpeechUplinkGate`
   (e.g. `holdUntilPause`) set by AgentCore on the stop and cleared when the utterance closes; pure, unit-tested.
2. **Words first, for 3 s after a stop (post-stop window).** For an utterance that starts within
   `BargeInTuning.postStopWindow` (default 3 s) after the stop utterance closed:
   - Its audio (with pre-roll) is buffered locally; no `activityStart`, nothing uploaded yet.
   - As soon as the local Mandarin ASR (F-05a §12) gives a partial with at least one Han character (or two Latin
     letters) that is not a stop phrase, the app sends `activityStart`, then the buffered audio in order, then streams
     live as usual. Log `postStopReleased heldMs=<n>`.
   - If the utterance closes with no such partial, the final transcript decides: words → send the whole utterance at
     once (`activityStart`, audio, `activityEnd`); no words → dropped, never sent (`postStopDropped reason=noWords`).
   - If its transcript is a stop phrase → dropped (`postStopDropped reason=stopPhrase`); no second `stopSync`.
   - Buffer cap 8 s of audio; past that with no words the utterance is dropped (`reason=cap`).
   - Utterances starting after the window use today's path unchanged (no buffering, no added delay).
3. **No resume, no reply without a sent utterance.** After a stop she speaks again only for a turn that answers an
   utterance sent after the stop (§15 item 4 `abandonNextTurn` stays). No re-ask (§15 item 3) and no "continue" text is
   sent while no new utterance was sent.
4. **Latency.** The hold adds at most the time to the first partial (device logs: `firstPartialMs` 30–750 ms) and only
   inside the window; the audio itself is not lost, so Gemini hears the whole question.
5. **Logs.** `utterance … endReason=stopPhrase`, `postStopReleased heldMs=<n>`, `postStopDropped reason=noWords|
   stopPhrase|cap`; numbers and enums only, no audio or words (I-8).
6. **Unchanged.** The §14 stop set, the spotter, §15 interrupt/stopSync, navigation guidance never interrupted (§14
   row 7), and barge-in outside a stop.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | Gate: muted utterance open, stop at 524 ms, speech goes on 1.2 s, then silence | One utterance `endReason=stopPhrase sentToModel=false`; no `cutAtUnmute`; no `speechStarted(sentToModel: true)`, no audio out | unit (SpeechUplinkGate) |
| 2 | Within 3 s after the stop: speech, ASR partial 「现在」 at 300 ms | Nothing out before the partial; then `activityStart`, buffered audio from onset (with pre-roll) in order, then live audio; `postStopReleased` | unit |
| 3 | Within 3 s: 1.2 s of speech, no partial, final transcript empty | Nothing sent; `postStopDropped reason=noWords` | unit |
| 4 | Within 3 s: no partial during speech, final transcript 「几点了」 at close | Whole utterance sent at close: `activityStart`, audio, `activityEnd` | unit |
| 5 | Within 3 s: transcript 「别说了」 again | Dropped `reason=stopPhrase`; no second `stopSync` | unit (AgentCore + gate) |
| 6 | Speech 4 s after the stop | Today's path: streamed from onset, no hold | unit |
| 7 | Scripted provider: stop, then Gemini opens a turn with no sent utterance | Not spoken; no re-ask sent | unit (AgentCore) |
| 8 | Device: 「珠海有什么好玩的」, 别说了, then silence 10 s | She stays silent; log: stop utterance `endReason=stopPhrase`, no `sentToModel=true` utterance until the next real question | D |
| 9 | Device: row 8 five times in one session | 5/5 silent after 别说了 | D (log) |
| 10 | Device: 别说了 then at once 「现在几点」 / 「打开空调」 | Each answered (checklist 11-01); `postStopReleased heldMs` under 1 s | D |
| 11 | Device: 别说了 then a cough / door slam / music | Silent; `postStopDropped` | D |
| 12 | Device: §14 and §15 rows (checklist 8-01…8-04, 11-01) | Still pass | D |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-022c | §16 items 1–5: stop utterance held to the pause (gate flag), 3 s post-stop window with word-gated release / drop (local ASR partials and final), buffer cap, no reply without a sent utterance, logs; unit rows 1–7; device rows 8–12 | unit, build, D (rows 8–12) |

## 17. Talking over her: measure first, then interrupt on confirmed speech (iOS, APPROVED 2026-11-02)

**Why.** The owner cannot talk over her: since the rule of 2026-10-28 (§9) only a stop phrase stops her, because a trigger on any sound let her own echo cut her off. That trigger had no level, word or confirmation check, so it did not test whether interruption can work. Device run 0be787e (2026-11-02):
- Sounds with `muteReason=none` reached Gemini and were answered: utterance 3 at 10:00:43 (peakDb 69, 13 s after her reply, weather tool) and utterance 4 at 10:01:04 (peakDb 64, 7 s after). Louder utterances at 10:05:35 and 10:05:48 (peakDb 88, 82) were probably the driver. No words are logged, so what the quiet sounds were is not proven. Both had ASR partials (`firstPartialMs` 27, 1232) and lasted 1.5–2.2 s, so a words-and-length check alone would have passed them.
- `utterance 2` at 10:00:15 (peakDb 65, `muteReason=reply`) also produced an ASR partial (634 ms). If that was her echo, a word comparison alone can fail on it.
- No measurement of echo in the app's real audio setup exists: `EchoSpike` (T-001, 6/10 and 8/10) uses `.default` mode and enables voice processing before attaching the player, unlike `LiveAudio`.

Community review 2026-11-02: the common baseline is the platform canceller, speech detection, a minimum length and/or word count, then pause or lower the reply and confirm before ending it (LiveKit `min_words`, `min_duration`, false-interruption resume; VideoSDK; agentos). Lowering by about 10 dB then confirming, comparing with the assistant's own words, and an echo level gate are proposed in the hailing-station design (not built) and voiceloop (self-reported). Nobody publishes results for a phone speaker in a moving car, and vendors' own figures still show false stops. Learning the driver's level is new here and unproven. Hence measurement comes first. Owner 2026-11-02: "just write a spec and push that".

**Rule in plain words.** First the app only writes down when it would have stopped her, and she behaves as today. Owner 2026-11-02: build the live version now behind its setting, without waiting for those numbers; they decide whether it can ever be on by default. Nothing ends her reply until real new words are confirmed. 别说了 stays the instant stop.

### Part A: echo re-test (T-001a)
1. `EchoSpike` matches `LiveAudio`: `.playAndRecord`, `.voiceChat`, `.defaultToSpeaker`; player attached and connected **before** `setVoiceProcessingEnabled(true)`; same AGC, ducking and restart handling.
2. The spike runs a matrix: system volume 100%, 70%, 50% (read and shown, set by hand), AGC on and off, 10 trials each. The report shows gate-closed count and peak level in the same dB as `peakDb`. Results go in specs/open-questions.md and specs/STATUS.md. The earlier T-001 numbers are marked as not describing the app's setup.

### Part B: log-only check and small fixes (T-022d)
3. **Pure check (`BargeInCheck`, NovaVoice).** It judges each utterance that starts while her reply is playing (`muteReason=reply`; never guidance). Stages, first failure is the reason:
   - `settling`: within `settleWindow` (3 s) after the audio engine started or restarted.
   - `notSpeech`: classifier maximum below `minSpeechProbability` (0.7), or no classifier result. No classifier result fails closed.
   - `lowLevel`: peak below the driver bar (item 4).
   - `tooShort`: shorter than `minSpeech` (300 ms).
   - `stopPhrase`: the words are a stop phrase; §14/§15/§16 handle it, unchanged.
   - `noWords`: no local ASR partial with words (`PostStopHold.hasWords`) within `wordDeadline` (1 s) after `minSpeech` passed, nor in the final.
   - `echoWords`: the words look like her own (item 16, which replaced the first rule of T-022d). This also rejects 嗯嗯, 对对.
   - Otherwise `wouldStop`.
4. **Driver bar.** The median `peakDb` of the last 10 sent utterances of this session with words, minus `levelMargin` (10 dB), clamped to 70…80; 72 before there are 3 such utterances. The same bar is logged, not applied, for utterances starting while she is silent: `levelCheck id peakDb barDb below=<bool>`.
5. **Her recent words.** The output transcription received in the last `echoWindow` (10 s), kept as toneless pinyin syllables. Partials are converted the same way, so misheard echo with a similar sound still matches. Kept in memory only and cleared `echoWindow` after her turn ends.
6. **Log-only.** The gate, Gemini, playback and every §14–§16 path behave exactly as today. Each candidate logs one line at its close: `bargeInShadow id outcome=wouldStop|rejected reason=<stage> peakDb barDb durationMs firstWordMs newSyllables totalSyllables` (numbers and enums only, I-8). `wouldStopAt id` is logged when the decision is reached, so the time can be matched to what the owner did.
7. **Longer echo tail.** `echoTail` (`Tuning.swift`) defaults to 800 ms instead of 500 ms (one iOS field report: 300 ms leaked, 800 ms did not); §15 item 2 `endEchoTail` still ends it after a stop. F-04 §14 item 2 points here.
8. **When the mute ends.** `AgentRuntime` ends the reply mute on `.replyFinished` with `revoicer.pendingClauses == 0`, while its comment says the mute must end only when nothing of the reply is left. Log `muteEndedMidReply` when reply audio of the same turn starts after the mute ended. If a device run shows any, end the mute on `.replyIdle` instead and record it in the PR.

### Part C: live interruption (T-022e, owner go-ahead 2026-11-02)
9. **Go-ahead and default.** Owner 2026-11-02 chose to build this now, after three device tries that all reached `wouldStop` (0ed6299), knowing false stops are not measured yet. The setting stays off by default. Making it on by default needs owner approval after rows 9–11, 14, 16 and 17, with the numbers in specs/STATUS.md. Pass bars: row 9 no `wouldStop` in 50 long replies; row 10 at least 18/20 `wouldStop`, median decision within 1 s of the words starting; row 16 at least 18/20 `wouldStop`. Row 11 is reported as counts, and the owner decides whether they are acceptable. Tuning or a background-voice filter is a new spec.
10. **Setting.** 设置 → 「可以打断她（实验）」, default off. Off is exactly today's behaviour and the §9 rule. On replaces that rule while she talks. Guidance is never interruptible (§14 row 7).
11. **Flow when on.** During a reply candidate the audio is buffered with its pre-roll and nothing is sent, as `PostStopHold` does.
    - Stages up to `tooShort` pass: lower the reply player node by `dipDb` (10 dB); the reply keeps playing and Gemini is not told.
    - `wouldStop`: flush playback, `sendActivityStart` (cancels the reply, §15 item 1), the buffered audio in order, live audio, `activityEnd` at the close. Later audio of the old turn is dropped by the epoch. Log `bargeInStop heldMs`.
    - Any other outcome: restore the volume, drop the buffer, log `bargeInDipCancelled reason`. Her reply was never ended, so nothing needs resuming and no text is sent to Gemini.
    - Buffer cap 8 s. If the reply ends first, normal unmute rules apply, and the buffered audio is sent only if the check still passes.
12. **Unchanged.** Stop phrases and their speed, `abandonNextTurn`, tool calls already running, §16 post-stop handling, and all behaviour with the setting off.
13. **Out of scope.** Applying the driver bar to utterances while she is silent (item 4 only logs it; a new spec uses that data), a background-voice filter, recognising the driver's voice, WebRTC AEC3, car audio over Bluetooth.

### Part D: questions on the same topic (owner 2026-11-02)
14. **Why the first rule changes.** The `echoWords` rule of T-022d compares sets of syllables and ignores their order, so a real question that reuses her words looks like echo. With her text 「珠海有很多好玩的地方」: 「珠海有多大」 has 1 new syllable of 5 and is rejected; 「珠海有什么好吃的」 has 3 of 8 and is rejected. Under item 11 a rejected question is dropped while she keeps talking, which fails the owner's need: ask another question while she talks and get an answer.
15. **Decided as words grow.** The check runs on each newer partial and the final, as it does today, so 「珠海有」 is not yet enough and 「珠海有多大」 passes when its last syllable arrives. `echoWords` is final only at the close.
16. **New `echoWords` rule (T-022e).** Her recent words are kept as an ordered list of syllables, in arrival order. A *run* is `minEchoRun` (3) or more consecutive syllables of the words that appear in the same order, consecutively, in her list. The words are echo if any of these holds: fewer than `minNewSyllables` (2) distinct syllables; no syllable absent from her words; or syllables inside runs are at least `echoCoverage` (70%) of all syllables. Results on her text above: the same text, and 「朱海有很多好完的地方」, are echo; 「好玩」 and 「对对」 are echo; 「珠海有多大」 (run of 3 of 5), 「珠海有什么好吃的」 (3 of 8), 「珠海离澳门多远」 and 「不是明天」 pass. This is unproven and lets some badly misheard echo through, for example a fragment such as 「珠海有看多」; rows 9 and 14 measure that. `bargeInShadow` also logs `runSyllables`. The shadow log uses this rule whether the setting is on or off.

**Acceptance (iOS).**

| # | Given / when | Then | Test |
|---|---|---|---|
| 1 | `BargeInCheck` with each stage's failing input | The matching reason; classifier missing → `notSpeech` | unit |
| 2 | Bar: fewer than 3 utterances / median 85 / median 95 / median 60 | 72 / 75 / 80 / 70 | unit |
| 3 | Her text 「珠海有很多好玩的地方」: partial is the same / a similar-sounding misheard form / 「不是明天」 / 「嗯嗯」 | `echoWords` / `echoWords` / `wouldStop` / `echoWords` | unit |
| 4 | Log-only: candidate reaches `wouldStop` | No audio or activity sent, playback untouched, one `bargeInShadow` line with no words | unit + log capture |
| 5 | Echo tail default, and after a stop | 800 ms; `endEchoTail` still clears it | unit |
| 6 | Reply audio arrives after the mute ended in the same turn | `muteEndedMidReply` logged | unit |
| 7 | Setting on: full pass | Order: dip, flush, activityStart, buffer from onset, live, activityEnd; `bargeInStop` | unit |
| 8 | Setting on: passes to the dip, then no words / setting off / guidance playing | Volume restored and nothing sent / today's path / no candidate | unit |
| 9 | Device, log-only: long replies at normal volume, nobody speaks; parked and driving; at least 50 replies | Count of `wouldStop` recorded (pass bar: 0) | D (log) |
| 10 | Device, log-only: talk over her 20 times with different sentences | Count of `wouldStop` and median decision time recorded | D (log) |
| 11 | Device, log-only: music, radio, passenger talking, a quiet voice nearby, coughs | Counts per sound recorded | D (log) |
| 12 | Device: `EchoSpike` matrix (items 1–2) | Numbers recorded | D |
| 13 | Device, setting on: 「介绍一下珠海」, then 「不是，我问的是明天」 mid-reply, 10 times | She stops and answers the new question; beginning of the sentence not lost | D |
| 14 | Device, setting on: rows 9 and 11 again | False stops counted; a brief dip is not a stop | D |
| 15 | Device: stop-phrase rows of §14–§16 | Still pass, setting on and off | D |
| 16 | Device, setting off, T-022e build: 「介绍一下珠海」, then a question reusing her words mid-reply (「珠海有多大」「珠海有什么好吃的」「珠海离澳门多远」, and others on what she just said), 20 times | Count of `wouldStop`, with `newSyllables`, `runSyllables` and `totalSyllables` of the rejected ones, recorded (pass bar: at least 18/20) | D (log) |
| 17 | Device, setting on: the questions of row 16, 10 times | She stops and answers the new question; beginning of the sentence not lost | D |
| 18 | The results listed in item 16, and a question growing from 「珠海有」 to 「珠海有多大」 | Echo or pass as listed; echo first, `wouldStop` once the last syllable arrives | unit |

**Tasks.**

| Task | Scope | Verify |
|---|---|---|
| T-001a | Items 1–2: `EchoSpike` matches the app's audio setup, volume and AGC matrix, results recorded; row 12 | build, D |
| T-022d | Items 3–8: `BargeInCheck`, driver bar, recent words, log-only lines, 800 ms echo tail, mute-end log; unit rows 1–6; device rows 9–11 | unit, build, D |
| T-022e | Items 9–12 and 14–16, owner go-ahead 2026-11-02: setting, dip, buffered audio and stop flow, new `echoWords` rule; unit rows 7–8, 18 and row 3 still passing; device rows 13–17 | unit, build, D |
